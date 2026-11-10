import AVFoundation
import Darwin
import Observation
import UIKit

/// Ties the audio source, the analyzer and the sign link together, and holds the
/// settings. Two sources:
/// - Microphone: captured and analysed here in the app (as before).
/// - Phone audio: a ReplayKit broadcast extension (PocketEarsBroadcast) captures
///   what other apps play and feeds the sign itself. The app only mirrors its
///   status and forwards settings, styles and messages over loopback (Bridge).
@Observable
final class AppModel {
    // Sign styles in BECM order -- led-sign's BUDDYEARS_VIZ_STYLES, which is
    // ("auto",) + _AUTO_STYLE_ORDER. Never reorder: the index is the wire value.
    static let styles = ["Auto", "Bars", "Waterfall", "Wave", "Plasma", "Liquid Classic",
                         "Starfield", "VU", "Matrix", "Ripple", "Bounce", "Fireworks", "Fire"]
    // Message animations in BETX order (BUDDYEARS_MSG_EFFECTS).
    static let effects = ["Scroll", "Static", "Bounce", "Blink", "Slide", "Type", "Rainbow",
                          "Pulse", "Wipe", "Chase", "Flip", "Sparkle", "Wave"]

    enum Source: String, CaseIterable, Identifiable {
        case microphone, phoneAudio
        var id: String { rawValue }
        var title: String { self == .microphone ? "Listen" : "Phone audio" }
    }

    /// Bundle ID of the embedded broadcast extension, read from the app bundle at
    /// run time because SideStore rewrites bundle IDs when it signs.
    static let broadcastExtensionID: String? = {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for url in items where url.pathExtension == "appex" {
            guard let b = Bundle(url: url),
                  let ext = b.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
            else { continue }
            return b.bundleIdentifier
        }
        return nil
    }()

    // Live state for the UI
    private(set) var running = false            // microphone mode running
    private(set) var broadcastLive = false      // phone-audio extension is reporting in
    private(set) var broadcastAudioFlowing = false
    private(set) var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var gainShown: Float = 0
    private(set) var link = SignLink.Snapshot()
    var errorText: String?

    var isActive: Bool { running || broadcastLive }

    // Settings (persisted)
    var source: Source { didSet { save(); if source == .phoneAudio { primeLocalNetwork() } } }
    var autoGain: Bool { didSet { save(); pushSettings() } }
    var balanceBands: Bool { didSet { save(); pushSettings() } }
    var sensitivityDB: Double { didSet { save(); pushSettings() } }
    var floorDB: Double { didSet { save(); pushSettings() } }
    var tiltDB: Double { didSet { save(); pushSettings() } }
    var signAddress: String { didSet { save(); signLink.setManualHost(signAddress); pushSettings() } }
    var keepAwake: Bool { didSet { save(); applyIdleTimer() } }
    var messageEffect: Int { didSet { save() } }
    var messageSeconds: Double { didSet { save() } }

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let signLink = SignLink()
    @ObservationIgnored private var analyzer: SpectrumAnalyzer?
    @ObservationIgnored private let dspQueue = DispatchQueue(label: "pocketears.dsp", qos: .userInteractive)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private let settingsLock = NSLock()
    @ObservationIgnored private var dspSettings = SpectrumAnalyzer.Settings()
    @ObservationIgnored private var frame = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    @ObservationIgnored private var lastWritten = 0
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // Phone-audio bridge
    @ObservationIgnored private let bridge = LoopbackSocket(port: Bridge.appPort)
    @ObservationIgnored private var lastStatusAt = Date.distantPast
    @ObservationIgnored private var knownSession: String?
    @ObservationIgnored private var settingsVersion = Int.random(in: 1...1_000_000)
    @ObservationIgnored private var livenessTimer: Timer?

    init() {
        let d = UserDefaults.standard
        source = Source(rawValue: d.string(forKey: "source") ?? "") ?? .microphone
        autoGain = d.object(forKey: "autoGain") as? Bool ?? true
        balanceBands = d.object(forKey: "balanceBands") as? Bool ?? true
        sensitivityDB = d.object(forKey: "sensitivityDB") as? Double ?? 0
        floorDB = d.object(forKey: "floorDB") as? Double ?? -60
        tiltDB = d.object(forKey: "tiltDB") as? Double ?? 3
        signAddress = d.string(forKey: "signAddress") ?? ""
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? false
        messageEffect = d.object(forKey: "messageEffect") as? Int ?? 0
        messageSeconds = d.object(forKey: "messageSeconds") as? Double ?? 8
        pushSettings()
        signLink.setManualHost(signAddress)
        observeAudioSession()

        bridge.onMessage = { [weak self] data in
            guard let status = try? JSONDecoder().decode(Bridge.Status.self, from: data) else { return }
            DispatchQueue.main.async { self?.handleStatus(status) }
        }
        bridge.open()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkBroadcastLiveness()
        }
        if source == .phoneAudio { primeLocalNetwork() }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(source.rawValue, forKey: "source")
        d.set(autoGain, forKey: "autoGain")
        d.set(balanceBands, forKey: "balanceBands")
        d.set(sensitivityDB, forKey: "sensitivityDB")
        d.set(floorDB, forKey: "floorDB")
        d.set(tiltDB, forKey: "tiltDB")
        d.set(signAddress, forKey: "signAddress")
        d.set(keepAwake, forKey: "keepAwake")
        d.set(messageEffect, forKey: "messageEffect")
        d.set(messageSeconds, forKey: "messageSeconds")
    }

    private func pushSettings() {
        var s = SpectrumAnalyzer.Settings()
        s.autoGain = autoGain
        s.balanceBands = balanceBands
        s.gainDB = Float(sensitivityDB)
        s.floorDB = Float(floorDB)
        s.tiltDBPerOctave = Float(tiltDB)
        settingsLock.lock()
        dspSettings = s
        settingsLock.unlock()
        if broadcastLive { sendSettingsToBroadcast() }
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && running
    }

    /// The app came back to the foreground. A suspended app can lose its sockets,
    /// so rebind the loopback listener.
    func didBecomeActive() {
        bridge.close()
        bridge.open()
    }

    // MARK: microphone start / stop

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard !running else { return }
        guard !broadcastLive else {
            errorText = "Phone audio is already feeding the sign. Stop it first."
            return
        }
        errorText = nil
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    self.beginCapture()
                } else {
                    self.errorText = "Microphone access is off. Turn it on in Settings › Privacy › Microphone."
                }
            }
        }
    }

    private func beginCapture() {
        do {
            try capture.start()
        } catch {
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            capture.stop()
            return
        }
        analyzer = SpectrumAnalyzer(sampleRate: capture.sampleRate)
        lastWritten = capture.totalWritten
        signLink.open()
        running = true
        applyIdleTimer()
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: dspQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 64.0, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }

    func stop() {
        guard running else { return }
        timer?.cancel()
        timer = nil
        dspQueue.sync {}   // let an in-flight frame finish
        signLink.sendCommand(opcode: 2, arg: 0)   // BECM_RELEASE: hand the sign back
        signLink.close()
        capture.stop()
        analyzer = nil
        running = false
        levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        link = signLink.snapshot()
        applyIdleTimer()
    }

    /// One analysis frame, 64 times a second, on dspQueue.
    private func step() {
        signLink.tick()
        guard let analyzer else { return }
        let written = capture.totalWritten
        // Nothing new from the mic (interrupted, route change): send nothing, so the
        // sign sees the feed stop rather than a frozen picture.
        guard written != lastWritten else { return }
        lastWritten = written

        capture.copyLatest(into: &frame)
        settingsLock.lock()
        let s = dspSettings
        settingsLock.unlock()
        let out = analyzer.process(frame, settings: s)
        signLink.sendFrame(out)

        tickCount &+= 1
        if tickCount % 2 == 0 {
            let snap = signLink.snapshot()
            DispatchQueue.main.async {
                guard self.running else { return }
                self.levels = out.levels
                self.gainShown = out.appliedGainDB
                self.link = snap
            }
        }
    }

    // MARK: phone audio (broadcast extension)

    var broadcastAvailable: Bool { Self.broadcastExtensionID != nil }

    func stopBroadcast() {
        bridge.send(Bridge.Control(kind: .stop), toPort: Bridge.extensionPort)
    }

    private var bridgeSettings: Bridge.Settings {
        Bridge.Settings(autoGain: autoGain, balanceBands: balanceBands, sensitivityDB: sensitivityDB, floorDB: floorDB,
                        tiltDB: tiltDB, signAddress: signAddress)
    }

    private func sendSettingsToBroadcast() {
        settingsVersion += 1
        bridge.send(Bridge.Control(kind: .settings, settings: bridgeSettings, settingsVersion: settingsVersion),
                    toPort: Bridge.extensionPort)
    }

    private func handleStatus(_ s: Bridge.Status) {
        lastStatusAt = Date()
        if !broadcastLive {
            broadcastLive = true
            errorText = nil
            if running { stop() }   // started from Control Center while the mic was on
        }
        // A new broadcast, or one that missed our last settings: send them again.
        if s.session != knownSession || s.settingsVersion != settingsVersion {
            knownSession = s.session
            sendSettingsToBroadcast()
        }
        broadcastAudioFlowing = s.audioFlowing
        levels = s.levels.map { Float($0) / 255 }
        gainShown = s.gainDB
        var snap = SignLink.Snapshot()
        snap.connected = s.connected
        snap.searching = !s.connected
        snap.manual = s.manual
        snap.lookupFailed = s.lookupFailed
        snap.ip = s.ip
        snap.name = s.name
        snap.framesSent = s.framesSent
        link = snap
    }

    private func checkBroadcastLiveness() {
        guard broadcastLive, Date().timeIntervalSince(lastStatusAt) > 1.5 else { return }
        broadcastLive = false
        broadcastAudioFlowing = false
        knownSession = nil
        levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        link = SignLink.Snapshot()
    }

    /// The broadcast extension can't show the Local Network prompt itself, so the
    /// app sends one harmless datagram on the LAN (UDP discard port) to get iOS to
    /// ask while the app is on screen. Nothing listens there; it's never a BEHI.
    private func primeLocalNetwork() {
        guard UserDefaults.standard.bool(forKey: "localNetworkPrimed") == false,
              let net = SignLink.localSubnet(), let host = net.hosts.first(where: { $0 != net.own }) else { return }
        UserDefaults.standard.set(true, forKey: "localNetworkPrimed")
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return }
        defer { Darwin.close(s) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(9).bigEndian
        a.sin_addr.s_addr = host.bigEndian
        var byte: UInt8 = 0
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(s, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    // MARK: sign controls

    func setStyle(_ index: Int) {
        guard index >= 0, index < Self.styles.count else { return }
        if broadcastLive {
            bridge.send(Bridge.Control(kind: .style, style: index), toPort: Bridge.extensionPort)
        } else {
            signLink.sendCommand(opcode: 1, arg: UInt8(index))
        }
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if broadcastLive {
            bridge.send(Bridge.Control(kind: .text, text: trimmed, effect: messageEffect, seconds: messageSeconds),
                        toPort: Bridge.extensionPort)
        } else {
            signLink.sendText(trimmed, effect: UInt8(messageEffect), seconds: messageSeconds)
        }
    }

    var canTalkToSign: Bool { isActive && (link.connected || (link.manual && !link.ip.isEmpty)) }

    // MARK: audio session events

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self, self.running,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.restartCapture()
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.restartCapture()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.restartCapture()
        })
    }

    /// After an interruption or route change (headphones, a call) the input format
    /// can change, so rebuild the capture and the analyzer.
    private func restartCapture() {
        timer?.cancel()
        timer = nil
        dspQueue.sync {}
        capture.stop()
        do {
            try capture.start()
        } catch {
            errorText = "The microphone stopped: \(error.localizedDescription)"
            signLink.sendCommand(opcode: 2, arg: 0)
            signLink.close()
            running = false
            applyIdleTimer()
            return
        }
        analyzer = SpectrumAnalyzer(sampleRate: capture.sampleRate)
        lastWritten = capture.totalWritten
        startTimer()
    }
}
