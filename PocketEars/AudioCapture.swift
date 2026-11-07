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
    private let ringSize = 1 << 15
    private let ring: UnsafeMutablePointer<Float>
    // Single writer (the audio thread), read from the analysis thread. A torn read
    // costs one slightly-wrong visualizer frame, nothing more.
    private var written = 0
    private(set) var sampleRate: Double = 48_000
    private(set) var isRunning = false

    init() {
        ring = .allocate(capacity: ringSize)
        ring.initialize(repeating: 0, count: ringSize)
    }

    deinit { ring.deallocate() }

    var totalWritten: Int { written }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers: music playing on this phone keeps playing.
        // measurement mode turns off the voice processing / AGC that would flatten
        // the dynamics the visualizer is trying to show.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        sampleRate = format.sampleRate

        let ring = self.ring
        let mask = ringSize - 1
        let node = AVAudioSinkNode { [unowned self] _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = list.first, let data = first.mData else { return noErr }
            let src = data.assumingMemoryBound(to: Float.self)
            let stride = Int(max(first.mNumberChannels, 1))
            var w = self.written
            for i in 0..<Int(frames) {
                ring[w & mask] = src[i * stride]
                w &+= 1
            }
            self.written = w
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

    /// Copies the most recent `dst.count` samples into `dst`.
    func copyLatest(into dst: inout [Float]) {
        let count = dst.count
        let w = written
        let mask = ringSize - 1
        var r = w - count
        for i in 0..<count {
            dst[i] = r >= 0 ? ring[r & mask] : 0
            r += 1
        }
    }
}
