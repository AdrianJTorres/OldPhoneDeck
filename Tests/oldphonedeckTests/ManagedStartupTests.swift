import Foundation
import Testing
import Darwin
@testable import oldphonedeck

struct ManagedStartupTests {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tls"), withIntermediateDirectories: true)
        for name in ["token", "tls/ca.key", "tls/ca.pem", "tls/server.pem", "tls/server.p12"] {
            try Data("fixture".utf8).write(to: dir.appendingPathComponent(name))
        }
        try Data("127.0.0.1".utf8).write(to: dir.appendingPathComponent("tls/server.ip"))
        try Data(#"{"version":2,"controls":[],"widgets":{"internet":true,"batteries":false}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    @Test func missingStateAndChangedAddressFailWithoutRewritingState() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ManagedStartup.Failure.address) {
            try ManagedStartup(directory: dir, port: 0, address: "192.0.2.1")
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("token"))
        #expect(throws: ManagedStartup.Failure.state) {
            try ManagedStartup(directory: dir, port: 0, address: "127.0.0.1")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("token").path))
    }

    @Test func occupiedPortRefusesPartialStartup() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketFD = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var endpoint = sockaddr_in6()
        endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        endpoint.sin6_family = sa_family_t(AF_INET6)
        let bound = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        #expect(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let obtained = withUnsafeMutablePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        #expect(obtained == 0)
        let port = UInt16(bigEndian: endpoint.sin6_port)
        #expect(throws: ManagedStartup.Failure.port) {
            try ManagedStartup(directory: dir, port: port, address: "127.0.0.1")
        }
    }

    @Test func occupiedIPv4PortRefusesPartialStartup() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(socketFD, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let obtained = withUnsafeMutablePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        #expect(obtained == 0)
        #expect(throws: ManagedStartup.Failure.port) {
            try ManagedStartup(directory: dir, port: UInt16(bigEndian: endpoint.sin_port), address: "127.0.0.1")
        }
    }

    @Test func unsafeLockAndMalformedV2Refused() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("startup.lock")
        try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: dir.appendingPathComponent("token").path)
        #expect(throws: ManagedStartup.Failure.lock) {
            try ManagedStartup(directory: dir, port: 0, address: "127.0.0.1")
        }
        try FileManager.default.removeItem(at: lock)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(throws: ManagedStartup.Failure.state) {
            try ManagedStartup(directory: dir, port: 0, address: "127.0.0.1")
        }
    }
}
