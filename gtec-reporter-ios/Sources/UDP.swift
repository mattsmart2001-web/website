import Foundation
import Darwin

/// The small amount of socket work the reporter needs.
///
/// Plain BSD sockets rather than Network.framework, for one reason: the
/// console replies to whichever address and port asked it, so the heartbeat
/// has to go out from the same socket that is bound to the telemetry port,
/// and the search has to send to 254 different addresses from that one
/// socket. Network.framework ties a connection to a single remote endpoint,
/// which fits neither.
///
/// Reporter.swift raises the local network permission prompt separately,
/// because a socket on its own does not always do it.
enum UDP {

    /// A socket bound to `port`, with a receive timeout set per call.
    static func bound(to port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        // SO_REUSEADDR, so the port can be taken again straight after this
        // app closes rather than sitting in TIME_WAIT.
        //
        // Not SO_REUSEPORT, deliberately. It would let a second app bind
        // 33740 as well, but a unicast datagram is still delivered to one
        // socket, not copied to both, so two telemetry apps would each get
        // a share of the packets and both would be wrong. A clear "port
        // busy" is better than two apps quietly half-working. Sharing is
        // done by forwarding instead: see Reporter.swift.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    @discardableResult
    static func send(_ fd: Int32, byte: UInt8, to ip: String, port: UInt16) -> Bool {
        send(fd, bytes: [byte], to: ip, port: port)
    }

    /// Used for the heartbeat, one byte, and for forwarding a whole datagram
    /// on to another app on this phone.
    @discardableResult
    static func send(_ fd: Int32, bytes: [UInt8], to ip: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        var payload = bytes
        let sent = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, &payload, payload.count, 0, sa,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent == payload.count
    }

    private static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds),
                         tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// One datagram, or nil on timeout.
    static func receive(_ fd: Int32, timeout: TimeInterval) -> [UInt8]? {
        receiveFrom(fd, timeout: timeout)?.0
    }

    /// One datagram and the address it came from, which is how the search
    /// learns where the console is.
    static func receiveFrom(_ fd: Int32, timeout: TimeInterval) -> ([UInt8], String)? {
        setTimeout(fd, timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutablePointer(to: &from) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buf, buf.count, 0, sa, &len)
            }
        }
        guard n > 0 else { return nil }

        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        return (Array(buf[0..<n]), String(cString: ip))
    }

    /// This device's own address on the WiFi, so the search knows which
    /// network to walk. Wired and cellular interfaces are skipped: the
    /// console is on the WiFi or it is not reachable at all.
    static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var found: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                break
            }
        }
        return found
    }
}
