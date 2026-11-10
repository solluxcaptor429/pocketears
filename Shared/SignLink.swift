import Darwin
import Foundation

/// UDP link to the LED sign, speaking the sign's own BuddyEars protocol
/// (buddyears/PROTOCOL.md): BEHI/BEHO discovery, LSV2 visualizer frames, BECM
/// commands and BETX messages. The sign needs no changes for this app.
///
/// Discovery differs from the 3DS in one way: iOS only lets apps with Apple's
/// restricted multicast entitlement send broadcasts, and a sideloaded app can't
/// have it. So besides trying the broadcast, the hello is unicast to every
/// address on the local subnet -- the sign answers whichever one reaches it.
final class SignLink {
    static let vizPort: UInt16 = 1236
    static let helloPort: UInt16 = 5004

    struct Snapshot {
        var connected = false
        var searching = false
        var ip = ""
        var name = ""
        var manual = false
        var lookupFailed = false
        var framesSent = 0
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var receiver: Thread?

    private var target: sockaddr_in?
    private var resolved = false
    private var signName = ""
    private var lastReply = Date.distantPast
    private var lastHello = Date.distantPast
    private let nonce = UInt32.random(in: 1...UInt32.max)
    private var seq: UInt16 = 0
    private var framesSent = 0
    private var nextID = UInt32.random(in: 1...0x7FFF_FFFF)

    private var manualHost = ""
    private var manualTarget: sockaddr_in?
    private var manualLookupFailed = false
    private var lookupGeneration = 0

    // MARK: lifecycle

    func open() {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        fd = s
        running = true
        lastHello = .distantPast
        let t = Thread { [weak self] in self?.receiveLoop(s) }
        t.name = "signlink-rx"
        t.qualityOfService = .userInitiated
        receiver = t
        t.start()
    }

    func close() {
        lock.lock()
        let s = fd
        fd = -1
        running = false
        resolved = false
        receiver = nil
        lock.unlock()
        if s >= 0 { Darwin.close(s) }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var snap = Snapshot()
        snap.manual = !manualHost.isEmpty
        snap.framesSent = framesSent
        snap.name = signName
        snap.lookupFailed = manualLookupFailed
        if let t = currentTarget() {
            snap.ip = Self.ipString(t)
        }
        snap.connected = resolved
        snap.searching = fd >= 0 && !resolved
        return snap
    }

    // MARK: manual address

    /// Empty = automatic discovery. Anything else is an IP or hostname (ledsign.local
    /// works: iOS resolves .local names over mDNS).
    func setManualHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard trimmed != manualHost else { lock.unlock(); return }
        manualHost = trimmed
        manualTarget = nil
        manualLookupFailed = false
        resolved = false
        lastHello = .distantPast
        lookupGeneration += 1
        let gen = lookupGeneration
        lock.unlock()
        guard !trimmed.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let addr = Self.lookup(trimmed)
            guard let self else { return }
            self.lock.lock()
            if gen == self.lookupGeneration {
                self.manualTarget = addr
                self.manualLookupFailed = (addr == nil)
                self.lastHello = .distantPast
            }
            self.lock.unlock()
        }
    }

    // MARK: periodic work

    /// Call often (every analysis frame); does discovery on its own schedule.
    func tick() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        let now = Date()
        if resolved && now.timeIntervalSince(lastReply) > 45 {
            resolved = false   // sign went quiet: go back to searching
        }
        let interval: TimeInterval = resolved ? 15 : 2
        guard now.timeIntervalSince(lastHello) >= interval else { return }
        lastHello = now
        sendHellos()
    }

    // Caller holds the lock.
    private func currentTarget() -> sockaddr_in? {
        manualHost.isEmpty ? target : manualTarget
    }

    // Caller holds the lock.
    private func sendHellos() {
        var buf = [UInt8](repeating: 0, count: 16)
        buf[0] = 0x42; buf[1] = 0x45; buf[2] = 0x48; buf[3] = 0x49   // "BEHI"
        Self.putU32(&buf, 4, nonce)
        buf[8] = 0x01   // wants a visualizer sink. No 0x04: this is a handheld, not a PC.

        if !manualHost.isEmpty {
            if var t = manualTarget {
                t.sin_port = Self.vizPort.bigEndian
                sendLocked(buf, to: t)
            }
            return
        }
        if resolved, let t = target {
            sendLocked(buf, to: t)
            return
        }
        // Broadcasts (silently refused by iOS without the multicast entitlement,
        // but harmless to try) ...
        let limited = Self.makeAddr(0xFFFF_FFFF, Self.vizPort)
        sendLocked(buf, to: limited)
        sendLocked(buf, to: Self.makeAddr(0xFFFF_FFFF, Self.helloPort))
        guard let net = Self.localSubnet() else { return }
        sendLocked(buf, to: Self.makeAddr(net.broadcast, Self.vizPort))
        // ... then the sweep that actually works: one unicast hello per host.
        for host in net.hosts where host != net.own {
            sendLocked(buf, to: Self.makeAddr(host, Self.vizPort))
        }
    }

    // MARK: sending

    func sendFrame(_ out: SpectrumAnalyzer.Output) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, resolved || !manualHost.isEmpty, let t = currentTarget() else { return }
        var buf = [UInt8](repeating: 0, count: 8 + SpectrumAnalyzer.bandCount + SpectrumAnalyzer.waveCount)
        buf[0] = 0x4C; buf[1] = 0x53; buf[2] = 0x56; buf[3] = 0x32   // "LSV2"
        buf[4] = UInt8(SpectrumAnalyzer.bandCount)
        buf[5] = UInt8(SpectrumAnalyzer.waveCount)
        buf[6] = UInt8(seq >> 8)       // network order, struct "!4sBBH" on the Pi
        buf[7] = UInt8(seq & 0xFF)
        for i in 0..<SpectrumAnalyzer.bandCount { buf[8 + i] = out.bands[i] }
        for i in 0..<SpectrumAnalyzer.waveCount { buf[8 + SpectrumAnalyzer.bandCount + i] = out.wave[i] }
        seq &+= 1
        if sendLocked(buf, to: t) { framesSent += 1 }
    }

    /// BECM: opcode 1 = visualizer style (arg = index), 2 = release the sign.
    func sendCommand(opcode: UInt8, arg: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, let t = currentTarget() else { return }
        var buf = [UInt8](repeating: 0, count: 16)
        buf[0] = 0x42; buf[1] = 0x45; buf[2] = 0x43; buf[3] = 0x4D   // "BECM"
        Self.putU32(&buf, 4, takeID())
        buf[8] = opcode
        buf[9] = arg
        for _ in 0..<3 { sendLocked(buf, to: t) }
    }

    /// BETX: a text message, shown with one of the sign's message animations.
    func sendText(_ text: String, effect: UInt8, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, let t = currentTarget() else { return }
        var payload = Array(text.utf8)
        if payload.count > 120 {
            // Trim to 120 bytes without splitting a UTF-8 sequence.
            var cut = 120
            while cut > 0 && (payload[cut] & 0xC0) == 0x80 { cut -= 1 }
            payload = Array(payload[0..<cut])
        }
        var buf = [UInt8](repeating: 0, count: 16)
        buf[0] = 0x42; buf[1] = 0x45; buf[2] = 0x54; buf[3] = 0x58   // "BETX"
        Self.putU32(&buf, 4, takeID())
        let ds = UInt16(min(max(seconds * 10, 0), 6000))
        buf[8] = UInt8(ds & 0xFF); buf[9] = UInt8(ds >> 8)
        buf[10] = UInt8(payload.count & 0xFF); buf[11] = UInt8(payload.count >> 8)
        buf[12] = effect
        buf += payload
        for _ in 0..<3 { sendLocked(buf, to: t) }
    }

    private func takeID() -> UInt32 {
        nextID &+= 1
        return nextID
    }

    @discardableResult
    private func sendLocked(_ buf: [UInt8], to addr: sockaddr_in) -> Bool {
        guard fd >= 0 else { return false }
        var a = addr
        let r = buf.withUnsafeBytes { bytes in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return r == buf.count
    }

    // MARK: receiving

    private func receiveLoop(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            lock.lock()
            let alive = running && fd == s
            lock.unlock()
            if !alive { break }

            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let r = buf.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(s, bytes.baseAddress, bytes.count, 0, $0, &len)
                    }
                }
            }
            guard r >= 16 else { continue }
            // "BEHO" with our nonce. Our own broadcast echoes back as BEHI and fails this.
            guard buf[0] == 0x42, buf[1] == 0x45, buf[2] == 0x48, buf[3] == 0x4F,
                  Self.getU32(buf, 4) == nonce, buf[8] & 0x01 != 0 else { continue }
            var port = UInt16(buf[10]) | (UInt16(buf[11]) << 8)
            if port == 0 { port = Self.vizPort }
            var name = ""
            if buf[8] & 0x02 != 0, r >= 19 {
                let n = Int(buf[18])
                if 19 + n <= r { name = String(decoding: buf[19..<(19 + n)], as: UTF8.self) }
            }

            lock.lock()
            if manualHost.isEmpty {
                // Address from the UDP source, never from the payload (same rule as the 3DS).
                var t = from
                t.sin_port = port.bigEndian
                target = t
            } else if var t = manualTarget {
                t.sin_port = port.bigEndian
                manualTarget = t
            }
            resolved = true
            lastReply = Date()
            if !name.isEmpty { signName = name }
            lock.unlock()
        }
    }

    // MARK: helpers

    private static func putU32(_ buf: inout [UInt8], _ at: Int, _ v: UInt32) {
        buf[at] = UInt8(v & 0xFF)
        buf[at + 1] = UInt8((v >> 8) & 0xFF)
        buf[at + 2] = UInt8((v >> 16) & 0xFF)
        buf[at + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func getU32(_ buf: [UInt8], _ at: Int) -> UInt32 {
        UInt32(buf[at]) | (UInt32(buf[at + 1]) << 8) | (UInt32(buf[at + 2]) << 16) | (UInt32(buf[at + 3]) << 24)
    }

    /// `hostOrderIP` in host byte order, e.g. 0xC0A80105 for 192.168.1.5.
    private static func makeAddr(_ hostOrderIP: UInt32, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = hostOrderIP.bigEndian
        return a
    }

    static func ipString(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &out, socklen_t(INET_ADDRSTRLEN))
        return String(cString: out)
    }

    private static func lookup(_ host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = first.pointee.ai_addr else { return nil }
        var out = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        out.sin_port = vizPort.bigEndian
        return out
    }

    struct Subnet {
        var own: UInt32
        var broadcast: UInt32
        var hosts: [UInt32]
    }

    /// The Wi-Fi interface's IPv4 subnet (host byte order). Large subnets are
    /// clamped to the /24 around this phone so a sweep stays a few hundred packets.
    static func localSubnet() -> Subnet? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var best: Subnet?
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let nm = cur.pointee.ifa_netmask else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet, not cellular or VPN
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip & 0xFFFF_0000 == 0xA9FE_0000 { continue }   // 169.254 link-local
            let realBroadcast = (ip & mask) | ~mask
            if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
            let network = ip & mask
            let last = network | ~mask
            guard last > network + 1 else { continue }
            let hosts = Array((network + 1)..<last)
            let subnet = Subnet(own: ip, broadcast: realBroadcast, hosts: hosts)
            if name == "en0" { return subnet }
            if best == nil { best = subnet }
        }
        return best
    }
}
