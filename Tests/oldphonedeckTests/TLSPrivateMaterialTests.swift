import Foundation
import Darwin
import CryptoKit
import Testing
@testable import oldphonedeck

struct TLSPrivateMaterialTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tls-private-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func mode(_ path: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber).intValue
    }

    /// Includes bytes, permissions, owner, links and inode; never prints secret bytes.
    private func snapshot(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let path = directory.appendingPathComponent(name)
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            let digest = info.st_mode & S_IFMT == S_IFREG
                ? SHA256.hash(data: try Data(contentsOf: path)).description : "non-regular"
            result[name] = "\(info.st_mode):\(info.st_uid):\(info.st_nlink):\(info.st_ino):\(digest)"
        }
        return result
    }

    @Test(arguments: TLSPrivateMaterial.names)
    func privateOutputIs0600BeforeTheProducerWrites(name: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(name)
        var called = false
        try TLSPrivateMaterial.withOutput(path) {
            called = true
            #expect(try mode(path) == 0o600)
            #expect(try Data(contentsOf: path).isEmpty)
            try Data("synthetic private bytes".utf8).write(to: path)
            #expect(try mode(path) == 0o600)
        }
        #expect(called)
        #expect(try mode(path) == 0o600)
    }

    @Test(arguments: ["readable", "symlink", "hardlink", "fifo", "directory", "special-bits"])
    func unsafeOutputNeverInvokesProducer(kind: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("server.key")
        let target = dir.appendingPathComponent("target")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target.path)
        case "hardlink": try #require(link(target.path, path.path) == 0)
        case "fifo": try #require(mkfifo(path.path, 0o600) == 0)
        case "directory": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        default:
            try Data("synthetic".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: kind == "readable" ? 0o644 : 0o4600], ofItemAtPath: path.path)
        }
        var called = false
        #expect(throws: TLSPrivateMaterial.Failure.unsafeFile) {
            try TLSPrivateMaterial.withOutput(path) { called = true }
        }
        #expect(!called)
        #expect(try String(contentsOf: target, encoding: .utf8) == "synthetic")
    }

    @Test func ownerCheckIsIndependentOfPermissionsAndFileType() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("private")
        try TLSPrivateMaterial.withOutput(path) { try Data([1]).write(to: path) }
        var info = stat()
        try #require(lstat(path.path, &info) == 0)
        #expect(TLSPrivateMaterial.secureMetadata(info))
        info.st_uid = getuid() == 0 ? 1 : 0
        #expect(!TLSPrivateMaterial.secureMetadata(info))
    }

    @Test func extendedACLIsNotHiddenBy0600Mode() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("server.key")
        try TLSPrivateMaterial.withOutput(path) { try Data([1]).write(to: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        #expect(try mode(path) == 0o600)
        #expect(throws: TLSPrivateMaterial.Failure.unsafeFile) { try TLSPrivateMaterial.read(path) }
    }

    @Test func unsafeTLSDirectoryIsRejected() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("tls")
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: dir.path)
        #expect(throws: TLSPrivateMaterial.Failure.unsafeFile) { try TLSPrivateMaterial.validateDirectory(path) }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: path.path)
        #expect(throws: TLSPrivateMaterial.Failure.unsafeFile) { try TLSPrivateMaterial.validateDirectory(path) }
    }

    @Test func existingOnlyNeverCreatesMissingTLSDirectory() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing-tls")
        #expect(LocalTLS.identity(for: "127.0.0.1", in: missing, existingOnly: true) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
    func secureIdentityLoadsWithoutChangingCertificateFingerprintsOrFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(LocalTLS.identity(for: "127.0.0.1", in: dir) != nil)
        for name in TLSPrivateMaterial.names { #expect(try mode(dir.appendingPathComponent(name)) == 0o600) }
        let before = try snapshot(dir)
        for existingOnly in [true, false] {
            #expect(LocalTLS.identity(for: "127.0.0.1", in: dir, existingOnly: existingOnly) != nil)
            #expect(try snapshot(dir) == before)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15), arguments: TLSPrivateMaterial.names)
    func readableRetainedSecretIsRejectedWithoutRepairOrRegeneration(name: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(LocalTLS.identity(for: "127.0.0.1", in: dir) != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(name).path)
        let before = try snapshot(dir)
        for existingOnly in [true, false] {
            // Even a different IP must not cause regeneration before unsafe files are rejected.
            #expect(LocalTLS.identity(for: "192.0.2.10", in: dir, existingOnly: existingOnly) == nil)
            #expect(try snapshot(dir) == before)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15), arguments: ["symlink", "hardlink", "missing", "empty"])
    func retainedIdentityCannotBypassFileChecks(kind: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(LocalTLS.identity(for: "127.0.0.1", in: dir) != nil)
        let path = dir.appendingPathComponent("server.p12")
        if kind == "hardlink" {
            try #require(link(path.path, dir.appendingPathComponent("alias").path) == 0)
        } else if kind == "empty" {
            try Data().write(to: path)
        } else {
            try FileManager.default.moveItem(at: path, to: dir.appendingPathComponent("retained"))
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: dir.appendingPathComponent("retained").path)
            }
        }
        let before = try snapshot(dir)
        for existingOnly in [true, false] {
            #expect(LocalTLS.identity(for: "127.0.0.1", in: dir, existingOnly: existingOnly) == nil)
            #expect(try snapshot(dir) == before)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
    func corruptRetainedIdentityDoesNotRegenerateOnChangedIP() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(LocalTLS.identity(for: "127.0.0.1", in: dir) != nil)
        try Data("invalid synthetic PKCS12".utf8).write(to: dir.appendingPathComponent("server.p12"))
        let before = try snapshot(dir)
        for existingOnly in [true, false] {
            #expect(LocalTLS.identity(for: "192.0.2.10", in: dir, existingOnly: existingOnly) == nil)
            #expect(try snapshot(dir) == before)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
    func permissionOnlyRemediationPreservesIdentityAndPublicFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(LocalTLS.identity(for: "127.0.0.1", in: dir) != nil)
        let secure = try snapshot(dir)
        for name in ["server.key", "server.p12"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        #expect(LocalTLS.identity(for: "127.0.0.1", in: dir, existingOnly: true) == nil)
        for name in ["server.key", "server.p12"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        #expect(LocalTLS.identity(for: "127.0.0.1", in: dir, existingOnly: true) != nil)
        #expect(try snapshot(dir) == secure)
    }
}
