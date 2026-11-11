import Foundation
import Network
import Security
import Darwin

/// File authority for TLS secrets. Never repairs a retained file or follows its final symlink.
enum TLSPrivateMaterial {
    static let names = ["ca.key", "server.key", "server.p12"]
    enum Failure: Error { case unsafeFile }

    static func secureMetadata(_ info: stat, allowEmpty: Bool = false) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
            && info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1
            && (allowEmpty || info.st_size > 0)
    }

    private static func noACL(_ descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // On macOS an existing descriptor with no extended ACL returns ENOENT.
            guard errno == ENOENT else { throw Failure.unsafeFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        // macOS returns -1/EINVAL for an empty, otherwise valid ACL.
        guard acl_valid(acl) == 0,
              acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
            throw Failure.unsafeFile
        }
    }

    static func validateDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw Failure.unsafeFile
        }
        try noACL(fd)
    }

    private static func validate(_ fd: Int32, allowEmpty: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, secureMetadata(info, allowEmpty: allowEmpty) else {
            throw Failure.unsafeFile
        }
        try noACL(fd)
    }

    private static func openValidated(_ path: URL) throws -> Int32 {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeFile }
        do { try validate(fd); return fd }
        catch { close(fd); throw error }
    }

    static func validate(in directory: URL) throws {
        try validateDirectory(directory)
        for name in names {
            let fd = try openValidated(directory.appendingPathComponent(name))
            close(fd)
        }
    }

    static func read(_ path: URL) throws -> Data {
        let fd = try openValidated(path)
        defer { close(fd) }
        // Import bytes from the descriptor whose metadata was checked, not a second path open.
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }

    /// Reserve an empty 0600 inode before the producer can write any private bytes. OpenSSL
    /// truncates this inode; no process-wide umask or post-write chmod window is involved.
    static func withOutput(_ path: URL, produce: () throws -> Void) throws {
        try validateDirectory(path.deletingLastPathComponent())
        let created = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let fd: Int32
        if created >= 0 {
            fd = created
            guard fchmod(fd, 0o600) == 0 else { close(fd); throw Failure.unsafeFile }
        } else {
            guard errno == EEXIST else { throw Failure.unsafeFile }
            fd = try openValidated(path)
        }
        defer { close(fd) }
        try validate(fd, allowEmpty: created >= 0)
        try produce()
        try validate(fd)
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(path.path, &named) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw Failure.unsafeFile
        }
    }
}

/// A private certificate authority + server certificate so modern iPhones can open phonedeck
/// over HTTPS (Safari only allows camera/mic/speech on secure pages).
/// The CA is created once; trust it on the iPhone and every later server cert is accepted.
/// The server cert is re-issued automatically when the Mac's LAN address changes.
enum LocalTLS {
    /// `tls/` inside the configuration directory. `use(configDir:)` redirects it for `--config-dir`;
    /// the default is the production `~/.oldphonedeck/tls`, unchanged.
    private(set) static var dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck/tls")
    static var caDER: URL { dir.appendingPathComponent("oldphonedeck-ca.cer") }
    private static let p12Password = "oldphonedeck"

    /// Points the certificate directory at `tls/` inside the given configuration directory.
    static func use(configDir: URL) { dir = configDir.appendingPathComponent("tls") }

    /// Returns a TLS identity for `ip`, creating the CA and/or server cert as needed.
    static func identity(for ip: String, existingOnly: Bool = false) -> sec_identity_t? {
        identity(for: ip, in: dir, existingOnly: existingOnly)
    }

    /// Explicit directory keeps isolated TLS tests independent of process-global configuration.
    static func identity(for ip: String, in directory: URL, existingOnly: Bool = false) -> sec_identity_t? {
        do {
            if !existingOnly { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            try TLSPrivateMaterial.validateDirectory(directory)
            // An incomplete or unsafe retained identity is an operator recovery case, never
            // permission repair or a reason to replace its CA/certificates.
            // Only an empty directory is fresh. A retained public CA or auxiliary file
            // also forbids silently generating a replacement trust chain.
            let retained = !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty
            if retained || existingOnly { try TLSPrivateMaterial.validate(in: directory) }
            if existingOnly {
                guard try String(contentsOf: directory.appendingPathComponent("server.ip"), encoding: .utf8) == ip else { return nil }
                return try loadIdentity(in: directory)
            }
            if retained {
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ca.pem").path),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent("server.pem").path) else {
                    throw TLSPrivateMaterial.Failure.unsafeFile
                }
                let stamp = try String(contentsOf: directory.appendingPathComponent("server.ip"), encoding: .utf8)
                let identity = try loadIdentity(in: directory)
                if stamp == ip { return identity }
                try makeServerCert(ip: ip, in: directory)
            } else {
                try makeCA(in: directory)
                try makeServerCert(ip: ip, in: directory)
            }
            try TLSPrivateMaterial.validate(in: directory)
            return try loadIdentity(in: directory)
        } catch {
            print("⚠️  HTTPS disabled: TLS identity unavailable or unsafe; operator recovery required")
            return nil
        }
    }

    private static func openssl(_ args: [String], in directory: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = directory
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "oldphonedeck.tls", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl \(args.first ?? ""): \(msg)"])
        }
    }

    private static func makeCA(in dir: URL) throws {
        // Self-signed via an explicit extfile: LibreSSL's "-extensions v3_ca" depends on the system openssl.cnf.
        try "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
            .write(to: dir.appendingPathComponent("ca.ext"), atomically: true, encoding: .utf8)
        try TLSPrivateMaterial.withOutput(dir.appendingPathComponent("ca.key")) {
            try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.csr",
                         "-subj", "/CN=OldPhoneDeck CA"], in: dir)
        }
        try openssl(["x509", "-req", "-in", "ca.csr", "-signkey", "ca.key", "-sha256", "-days", "3650",
                     "-extfile", "ca.ext", "-out", "ca.pem"], in: dir)
        try openssl(["x509", "-in", "ca.pem", "-outform", "der", "-out", "oldphonedeck-ca.cer"], in: dir)
    }

    private static func makeServerCert(ip: String, in dir: URL) throws {
        // iOS requires: SAN entries, serverAuth EKU, and at most 825 days of validity.
        let ext = """
        basicConstraints=CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=IP:\(ip),IP:127.0.0.1,DNS:localhost
        """
        try ext.write(to: dir.appendingPathComponent("server.ext"), atomically: true, encoding: .utf8)
        try TLSPrivateMaterial.withOutput(dir.appendingPathComponent("server.key")) {
            try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr",
                         "-subj", "/CN=\(ip)"], in: dir)
        }
        try openssl(["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                     "-days", "800", "-sha256", "-extfile", "server.ext", "-out", "server.pem"], in: dir)
        try TLSPrivateMaterial.withOutput(dir.appendingPathComponent("server.p12")) {
            try openssl(["pkcs12", "-export", "-inkey", "server.key", "-in", "server.pem", "-certfile", "ca.pem",
                         "-out", "server.p12", "-passout", "pass:\(p12Password)"], in: dir)
        }
        try ip.write(to: dir.appendingPathComponent("server.ip"), atomically: true, encoding: .utf8)
    }

    private static func loadIdentity(in dir: URL) throws -> sec_identity_t {
        let data = try TLSPrivateMaterial.read(dir.appendingPathComponent("server.p12"))
        var items: CFArray?
        var opts: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        if #available(macOS 15.0, *) { opts[kSecImportToMemoryOnly as String] = true }   // don't touch the login keychain
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "oldphonedeck.tls", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not load server identity (\(status))"])
        }
        let identity = ref as! SecIdentity
        guard let sec = sec_identity_create(identity) else {
            throw NSError(domain: "oldphonedeck.tls", code: -1, userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
        }
        return sec
    }

    static func parameters(_ identity: sec_identity_t, websocket: Bool = false) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls)
        if websocket {
            params.defaultProtocolStack.applicationProtocols.insert(webSocketOptions(), at: 0)
        }
        return params
    }

    static func webSocketOptions() -> NWProtocolWebSocket.Options {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = PhoneMediaMessage.maximumMessageSize
        return ws
    }
}
