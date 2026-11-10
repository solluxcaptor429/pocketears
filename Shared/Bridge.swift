import Darwin
import Foundation

/// App <-> broadcast extension messages. The extension runs in its own process,
/// so the two talk over UDP on 127.0.0.1 with small JSON packets. Loopback needs
/// no App Group (SideStore rewrites group IDs, so we don't rely on one) and no
/// Local Network permission.
enum Bridge {
    /// The extension listens here for `Control` packets.
    static let extensionPort: UInt16 = 47236
    /// The app listens here for `Status` packets.
    static let appPort: UInt16 = 47237

    struct Settings: Codable, Equatable {
        var autoGain = true
        var sensitivityDB = 0.0
        var floorDB = -60.0
        var tiltDB = 3.0
        var signAddress = ""
    }

    /// Extension -> app, about 32 times a second while a broadcast runs.
    struct Status: Codable {
        var session: String
        var settingsVersion: Int
        var levels: [UInt8]
        var gainDB: Float
        var audioFlowing: Bool
        var sampleRate: Double
        var connected: Bool
        var manual: Bool
        var lookupFailed: Bool
        var ip: String
        var name: String
        var framesSent: Int
    }

    /// App -> extension.
    struct Control: Codable {
        enum Kind: String, Codable { case settings, style, text, stop }
        var kind: Kind
        var settings: Settings?
        var settingsVersion: Int?
        var style: Int?
        var text: String?
        var effect: Int?
        var seconds: Double?
    }
}

/// A UDP socket bound to 127.0.0.1:`port`. Received datagrams go to `onMessage`
/// on a background thread.
final class LoopbackSocket {
    let port: UInt16
    var onMessage: ((Data) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1

    init(port: UInt16) { self.port = port }

    deinit { close() }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0
    }

    @discardableResult
    func open() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return true }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = Self.loopback(port)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(s); return false }
        fd = s
        let t = Thread { [weak self] in self?.receiveLoop(s) }
        t.name = "loopback-\(port)"
        t.qualityOfService = .userInitiated
        t.start()
        return true
    }

    func close() {
        lock.lock()
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 { Darwin.close(s) }
    }

    func send(_ data: Data, toPort port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        var addr = Self.loopback(port)
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func send<T: Encodable>(_ value: T, toPort port: UInt16) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(data, toPort: port)
    }

    private func receiveLoop(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock()
            let alive = fd == s
            lock.unlock()
            if !alive { break }
            let r = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            guard r > 0 else { continue }
            onMessage?(Data(buf[0..<r]))
        }
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return a
    }
}
