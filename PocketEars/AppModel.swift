import AVFoundation
import Observation
import UIKit

/// Ties the mic, the analyzer and the sign link together, and holds the settings.
@Observable
final class AppModel {
    // Sign styles in BECM order -- led-sign's BUDDYEARS_VIZ_STYLES, which is
    // ("auto",) + _AUTO_STYLE_ORDER. Never reorder: the index is the wire value.
    static let styles = ["Auto", "Bars", "Waterfall", "Wave", "Plasma", "Liquid Classic",
                         "Starfield", "VU", "Matrix", "Ripple", "Bounce", "Fireworks", "Fire"]
    // Message animations in BETX order (BUDDYEARS_MSG_EFFECTS).
    static let effects = ["Scroll", "Static", "Bounce", "Blink", "Slide", "Type", "Rainbow",
                          "Pulse", "Wipe", "Chase", "Flip", "Sparkle", "Wave"]

    // Live state for the UI
    private(set) var running = false
    private(set) var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var gainShown: Float = 0
    private(set) var link = SignLink.Snapshot()
    var errorText: String?

    // Settings (persisted)
    var autoGain: Bool { didSet { save(); pushSettings() } }
    var sensitivityDB: Double { didSet { save(); pushSettings() } }
    var floorDB: Double { didSet { save(); pushSettings() } }
    var tiltDB: Double { didSet { save(); pushSettings() } }
    var signAddress: String { didSet { save(); signLink.setManualHost(signAddress) } }
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

    init() {
        let d = UserDefaults.standard
        autoGain = d.object(forKey: "autoGain") as? Bool ?? true
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
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(autoGain, forKey: "autoGain")
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
        s.gainDB = Float(sensitivityDB)
        s.floorDB = Float(floorDB)
        s.tiltDBPerOctave = Float(tiltDB)
        settingsLock.lock()
        dspSettings = s
        settingsLock.unlock()
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && running
    }

    // MARK: start / stop

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard !running else { return }
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

    // MARK: sign controls

    func setStyle(_ index: Int) {
        guard index >= 0, index < Self.styles.count else { return }
        signLink.sendCommand(opcode: 1, arg: UInt8(index))
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        signLink.sendText(trimmed, effect: UInt8(messageEffect), seconds: messageSeconds)
    }

    var canTalkToSign: Bool { running && (link.connected || (link.manual && !link.ip.isEmpty)) }

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
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: dspQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 64.0, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }
}
