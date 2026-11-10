import Foundation

/// Mono float samples, newest last. One writer (an audio thread) and one reader
/// (the 64 Hz analysis timer). A torn read costs one slightly-wrong visualizer
/// frame, nothing more, so there is no lock on the hot path.
final class SampleRing {
    static let size = 1 << 15
    private let buf: UnsafeMutablePointer<Float>
    private(set) var written = 0
    /// Rate of the samples most recently appended; 0 until the first append.
    var sampleRate: Double = 0

    init() {
        buf = .allocate(capacity: Self.size)
        buf.initialize(repeating: 0, count: Self.size)
    }

    deinit { buf.deallocate() }

    /// Appends `count` samples read `stride` apart (stride > 1 picks one channel
    /// out of interleaved audio).
    func append(_ src: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        let mask = Self.size - 1
        var w = written
        for i in 0..<count {
            buf[w & mask] = src[i * stride]
            w &+= 1
        }
        written = w
    }

    /// Copies the most recent `dst.count` samples into `dst`.
    func copyLatest(into dst: inout [Float]) {
        let count = dst.count
        let w = written
        let mask = Self.size - 1
        var r = w - count
        for i in 0..<count {
            dst[i] = r >= 0 ? buf[r & mask] : 0
            r += 1
        }
    }
}
