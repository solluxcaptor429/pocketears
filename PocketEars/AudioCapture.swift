import AVFoundation

/// Microphone -> a ring buffer. The render callback only copies samples; analysis
/// runs on its own steady 64 Hz timer (see AppModel), so packet timing doesn't
/// depend on how big the hardware's IO buffers happen to be.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }

    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    let ring = SampleRing()
    private(set) var isRunning = false

    var sampleRate: Double { ring.sampleRate }
    var totalWritten: Int { ring.written }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers: music playing on this phone (Apple Music
        // included) keeps playing. measurement mode turns off the voice processing /
        // AGC / echo cancelling that would flatten the dynamics or cancel out the
        // phone's own speaker. allowBluetoothA2DP + allowAirPlay keep that music on
        // a Bluetooth or AirPlay speaker; without them, recording would pull the
        // route back to the phone. (Not allowBluetooth: that is the low-quality
        // hands-free profile.)
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .defaultToSpeaker,
                                          .allowBluetoothA2DP, .allowAirPlay])
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        ring.sampleRate = format.sampleRate

        let ring = self.ring
        let node = AVAudioSinkNode { _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = list.first, let data = first.mData else { return noErr }
            let src = data.assumingMemoryBound(to: Float.self)
            ring.append(src, count: Int(frames), stride: Int(max(first.mNumberChannels, 1)))
            return noErr
        }
        engine.attach(node)
        engine.connect(input, to: node, format: format)
        sink = node
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning || sink != nil else { return }
        engine.stop()
        if let node = sink {
            engine.disconnectNodeInput(node)
            engine.detach(node)
        }
        sink = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func copyLatest(into dst: inout [Float]) { ring.copyLatest(into: &dst) }
}
