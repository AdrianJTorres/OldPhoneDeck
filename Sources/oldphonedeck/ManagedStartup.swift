import Foundation
import Darwin
import Network

/// Opt-in unattended startup. Owns a kernel lock until process exit; never unlinks it.
final class ManagedStartup {
    enum Failure: String, Error {
        case lock = "startup lock unavailable (another instance or unsafe lock file)"
        case state = "existing credentials, TLS or V2 configuration unavailable"
        case address = "LAN address differs from retained TLS identity"
        case port = "required port unavailable"
    }

    private let descriptor: Int32
    private let mutex = NSLock()
    private var ready = Set<String>()

    init(directory: URL, port: UInt16, address: String) throws {
        let fd = open(directory.appendingPathComponent("startup.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.lock }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw Failure.lock
        }
        do {
            try TLSPrivateMaterial.validate(in: directory.appendingPathComponent("tls"))
            for name in ["token", "config.json", "tls/ca.pem", "tls/server.pem", "tls/server.ip"] {
                let path = directory.appendingPathComponent(name)
                let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      !(try Data(contentsOf: path)).isEmpty else { throw Failure.state }
            }
            let token = try String(contentsOf: directory.appendingPathComponent("token"), encoding: .utf8)
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.state }
            let document = ConfigurationDecoder.decode(.data(try Data(contentsOf: directory.appendingPathComponent("config.json"))))
            guard case .v2 = document else { throw Failure.state }
            let stamp = try String(contentsOf: directory.appendingPathComponent("tls/server.ip"), encoding: .utf8)
            guard stamp == address else { throw Failure.address }
            guard port > 0, port <= 65532 else { throw Failure.port }
            // Check all ports before starting any listener. Actual listener failures remain fatal,
            // covering a non-cooperating process racing this check.
            var sockets: [Int32] = []
            defer { sockets.forEach { close($0) } }
            for number in [port, port + 2, port + 3] {
                // macOS can allow a dual-stack IPv6 bind beside an IPv4 listener.
                // Reserve both families explicitly rather than infer IPv4 ownership.
                for family in [AF_INET, AF_INET6] {
                    let sock = socket(family, SOCK_STREAM, 0)
                    guard sock >= 0 else { throw Failure.port }
                    sockets.append(sock)
                    // Tolerate TIME_WAIT, but never enable SO_REUSEPORT.
                    var reuse: Int32 = 1
                    guard setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse,
                                     socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.port }
                    let result: Int32
                    if family == AF_INET6 {
                        var v6Only: Int32 = 1
                        guard setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only,
                                         socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.port }
                        var endpoint = sockaddr_in6()
                        endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                        endpoint.sin6_family = sa_family_t(AF_INET6)
                        endpoint.sin6_port = number.bigEndian
                        result = withUnsafePointer(to: &endpoint) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                        }
                    } else {
                        var endpoint = sockaddr_in()
                        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        endpoint.sin_family = sa_family_t(AF_INET)
                        endpoint.sin_port = number.bigEndian
                        result = withUnsafePointer(to: &endpoint) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                        }
                    }
                    guard result == 0, listen(sock, 1) == 0 else { throw Failure.port }
                }
            }
        } catch {
            close(fd)
            throw (error as? Failure) ?? Failure.state
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    static func report(_ message: String) {
        FileHandle.standardError.write(Data(("PhoneDeck startup: " + message + "\n").utf8))
    }

    func observe(_ state: NWListener.State, service: String) {
        mutex.lock(); defer { mutex.unlock() }
        switch state {
        case .ready:
            ready.insert(service)
            if ready.count == 3 { Self.report("HTTP/HTTPS/WSS listeners ready; authenticated health check still required") }
        case .failed:
            Self.report("required listener failed; inspect port ownership and sandbox"); exit(1)
        default: break
        }
    }

    func armDeadline() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [self] in
            mutex.lock(); defer { mutex.unlock() }
            if ready.count != 3 { Self.report("listener readiness deadline exceeded"); exit(1) }
        }
    }
}
