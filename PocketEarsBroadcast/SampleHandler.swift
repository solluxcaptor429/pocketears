import AudioToolbox
import CoreMedia
import ReplayKit

/// ReplayKit broadcast upload extension: iOS hands it the audio every app on the
/// phone is playing (`.audioApp`), and it feeds the sign directly with the same
/// analyzer and protocol as microphone mode. It runs in its own process, so the
/// sign keeps getting frames with PocketEars closed and other apps on screen.
///
/// Settings arrive from the app over loopback (see Bridge) and are remembered in
/// this extension's own defaults, so a broadcast started from Control Center uses
/// whatever was set last.
///
/// DRM-protected audio (Apple Music, some video apps) reaches ReplayKit as silence.
@objc(SampleHandler)
final class SampleHandler: RPBroadcastSampleHandler {
    private let ring = SampleRing()
    private let signLink = SignLink()
    private let bridge = LoopbackSocket(port: Bridge.extensionPort)
    private let dspQueue = DispatchQueue(label: "pocketears.broadcast.dsp", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let session = UUID().uuidString

    private let settingsLock = NSLock()
    private var settings = Bridge.Settings()
    private var settingsVersion = 0

    // dspQueue only
    private var analyzer: SpectrumAnalyzer?
    private var analyzerRate: Double = 0
    private var frame = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var lastWritten = 0
    private var lastNewAudio = Date.distantPast
    private var lastOut = SpectrumAnalyzer.Output()
    private var tickCount = 0

    // sample-buffer thread only
    private var mono = [Float]()

    // MARK: broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        loadSettings()
        signLink.setManualHost(currentSettings().signAddress)
        signLink.open()
        bridge.onMessage = { [weak self] data in self?.handleControl(data) }
        bridge.open()

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: dspQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 64.0, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }

    override func broadcastFinished() {
        timer?.cancel()
        timer = nil
        dspQueue.sync {}
        signLink.sendCommand(opcode: 2, arg: 0)   // BECM_RELEASE: hand the sign back
        signLink.close()
        bridge.close()
    }

    // MARK: audio in

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .audioApp else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = Int(asbd.mBitsPerChannel) / 8
        guard (isFloat && bytes == 4) || (!isFloat && (bytes == 2 || bytes == 4)) else { return }

        var count = frames
        if mono.count < count { mono = [Float](repeating: 0, count: count) }
        for i in 0..<count { mono[i] = 0 }

        // Mix every channel down to mono, whatever layout ReplayKit picked
        // (app audio is often big-endian Int16, interleaved stereo).
        var mixed = 0
        for buffer in UnsafeMutableAudioBufferListPointer(abl) {
            guard let data = buffer.mData else { continue }
            let chans = nonInterleaved ? 1 : Int(max(buffer.mNumberChannels, 1))
            let frameBytes = bytes * chans
            count = min(count, Int(buffer.mDataByteSize) / frameBytes)
            for c in 0..<chans {
                for i in 0..<count {
                    mono[i] += Self.sample(data, i * frameBytes + c * bytes,
                                           bytes: bytes, isFloat: isFloat, bigEndian: bigEndian)
                }
            }
            mixed += chans
        }
        // The buffer list points into `block`; keep it alive until we're done reading.
        withExtendedLifetime(block) {}
        guard mixed > 0, count > 0 else { return }
        let scale = 1 / Float(mixed)
        for i in 0..<count { mono[i] *= scale }

        ring.sampleRate = asbd.mSampleRate
        mono.withUnsafeBufferPointer { ring.append($0.baseAddress!, count: count) }
    }

    private static func sample(_ p: UnsafeMutableRawPointer, _ off: Int, bytes: Int,
                               isFloat: Bool, bigEndian: Bool) -> Float {
        if bytes == 2 {
            let v = p.loadUnaligned(fromByteOffset: off, as: Int16.self)
            return Float(bigEndian ? Int16(bigEndian: v) : Int16(littleEndian: v)) / 32_768
        }
        let bits = p.loadUnaligned(fromByteOffset: off, as: UInt32.self)
        let native = bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
        if isFloat { return Float(bitPattern: native) }
        return Float(Int32(bitPattern: native)) / 2_147_483_648
    }

    // MARK: analysis, 64 times a second on dspQueue

    private func step() {
        signLink.tick()
        let now = Date()
        let written = ring.written
        if written != lastWritten {
            lastWritten = written
            lastNewAudio = now
        }
        let rate = ring.sampleRate
        // ReplayKit delivers ~20 ms chunks, slower than our 64 Hz tick, so keep
        // sending while audio arrived recently. When apps go quiet ReplayKit stops
        // delivering; then we stop sending and the sign falls back on its own.
        let flowing = rate > 0 && now.timeIntervalSince(lastNewAudio) < 0.25
        if flowing, let analyzer = analyzerFor(rate) {
            ring.copyLatest(into: &frame)
            let out = analyzer.process(frame, settings: dspSettings())
            signLink.sendFrame(out)
            lastOut = out
        } else {
            lastOut = SpectrumAnalyzer.Output()
        }

        tickCount &+= 1
        if tickCount % 2 == 0 {
            let snap = signLink.snapshot()
            settingsLock.lock()
            let version = settingsVersion
            settingsLock.unlock()
            let status = Bridge.Status(
                session: session, settingsVersion: version,
                levels: lastOut.bands, gainDB: lastOut.appliedGainDB,
                audioFlowing: flowing, sampleRate: rate,
                connected: snap.connected, manual: snap.manual, lookupFailed: snap.lookupFailed,
                ip: snap.ip, name: snap.name, framesSent: snap.framesSent)
            bridge.send(status, toPort: Bridge.appPort)
        }
    }

    private func analyzerFor(_ rate: Double) -> SpectrumAnalyzer? {
        if analyzer == nil || rate != analyzerRate {
            analyzer = SpectrumAnalyzer(sampleRate: rate)
            analyzerRate = rate
        }
        return analyzer
    }

    // MARK: settings and control from the app

    private func currentSettings() -> Bridge.Settings {
        settingsLock.lock(); defer { settingsLock.unlock() }
        return settings
    }

    private func dspSettings() -> SpectrumAnalyzer.Settings {
        let s = currentSettings()
        var d = SpectrumAnalyzer.Settings()
        d.autoGain = s.autoGain
        d.balanceBands = s.balanceBands
        d.gainDB = Float(s.sensitivityDB)
        d.floorDB = Float(s.floorDB)
        d.tiltDBPerOctave = Float(s.tiltDB)
        return d
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(Bridge.Settings.self, from: data) else { return }
        settingsLock.lock()
        settings = s
        settingsLock.unlock()
    }

    /// Runs on the loopback receive thread.
    private func handleControl(_ data: Data) {
        guard let c = try? JSONDecoder().decode(Bridge.Control.self, from: data) else { return }
        switch c.kind {
        case .settings:
            guard let s = c.settings else { return }
            settingsLock.lock()
            settings = s
            settingsVersion = c.settingsVersion ?? settingsVersion
            settingsLock.unlock()
            if let encoded = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(encoded, forKey: "settings")
            }
            signLink.setManualHost(s.signAddress)
        case .style:
            guard let i = c.style, i >= 0, i < 256 else { return }
            signLink.sendCommand(opcode: 1, arg: UInt8(i))
        case .text:
            guard let text = c.text, !text.isEmpty else { return }
            signLink.sendText(text, effect: UInt8(clamping: c.effect ?? 0), seconds: c.seconds ?? 8)
        case .stop:
            let err = NSError(domain: "PocketEars", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Stopped from PocketEars."])
            DispatchQueue.main.async { self.finishBroadcastWithError(err) }
        }
    }
}
