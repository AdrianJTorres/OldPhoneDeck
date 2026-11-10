import Foundation
import Network
import Security
import Testing
@testable import oldphonedeck

/// Exercises only the changed operational health helper against native synthetic listeners.
@Suite(.serialized)
struct OperationalHealthTests {
    private func identity(in directory: URL) throws -> sec_identity_t {
        let tls = directory.appendingPathComponent("tls")
        try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true)
        func openssl(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = args
            process.currentDirectoryURL = tls
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try "basicConstraints=critical,CA:TRUE\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n"
            .write(to: tls.appendingPathComponent("ext"), atomically: true, encoding: .utf8)
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "req.pem", "-subj", "/CN=localhost"])
        try openssl(["x509", "-req", "-in", "req.pem", "-signkey", "key.pem", "-days", "1", "-extfile", "ext", "-out", "server.pem"])
        try FileManager.default.copyItem(at: tls.appendingPathComponent("server.pem"), to: tls.appendingPathComponent("ca.pem"))
        try openssl(["x509", "-in", "ca.pem", "-outform", "der", "-out", "ca.der"])
        try openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "server.pem", "-out", "identity.p12", "-passout", "pass:fixture-only"])
        let data = try Data(contentsOf: tls.appendingPathComponent("identity.p12"))
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: "fixture-only"]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        else { throw NSError(domain: "requires-memory-only-import", code: 1) }
        try #require(SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess)
        let entry = try #require((items as? [[String: Any]])?.first)
        let ref = try #require(entry[kSecImportItemIdentity as String]) as! SecIdentity
        return try #require(sec_identity_create(ref))
    }

    private func lanHosts() throws -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        try #require(getifaddrs(&addresses) == 0)
        defer { freeifaddrs(addresses) }
        var hosts: [String] = []
        var cursor = addresses
        while let entry = cursor {
            let interface = entry.pointee
            if String(cString: interface.ifa_name) == "en0", let sa = interface.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if sa.pointee.sa_family == UInt8(AF_INET) || IPv6Address(value)?.isLinkLocal == false {
                        hosts.append(value)
                    }
                }
            }
            cursor = interface.ifa_next
        }
        try #require(!hosts.isEmpty, "This isolated LAN denial check requires a native LAN address")
        return hosts
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15),
          arguments: ["m5.2", "m5.1"])
    func helperRecognizesSecureHealthAndExplicitRollback(release: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("health-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try identity(in: directory)
        let token = "operational-health-fixture"
        try token.write(to: directory.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let controls: [[String: Any]] = (1...7).map { index in
            ["id": index == 7 ? "key-1" : "app-\(index)", "action": "app.launch",
             "parameters": ["path": "/fixture/App\(index).app"]]
        }
        let document: [String: Any] = ["version": 2, "controls": controls,
                                      "widgets": ["internet": true, "batteries": true]]
        let original = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try original.write(to: directory.appendingPathComponent("config.json"))
        let web = "synthetic HTTPS deck"
        let revision = "synthetic-key-1-revision"
        let queue = DispatchQueue(label: "operational-health-fixture")
        let http = try HTTPServer(port: 0, queue: queue)
        let https = try HTTPServer(port: 0, parameters: LocalTLS.parameters(identity), queue: queue)
        let media = PhoneMediaServer(token: token, audio: nil)
        let viewers = MJPEGViewers()
        let ca = try Data(contentsOf: directory.appendingPathComponent("tls/ca.der"))
        let profile = try PropertyListSerialization.data(fromPropertyList:
            ["PayloadContent": [["PayloadContent": ca]]], format: .xml, options: 0)
        let admission: HTTPTransportAdmission = { head, transport in
            release == "m5.1" ? DeckRoute.admit(head, token: token)
                : DeckRoute.admit(head, token: token, transport: transport)
        }
        let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
            switch req.path {
            case "/", "/index.html": conn.respond(text: web)
            case "/oldphonedeck.mobileconfig": conn.respond(200, "application/x-apple-aspen-config", profile)
            case "/info": conn.respondJSON(["camera": false])
            case "/launcher": conn.respondJSON(["configuration": "unrepresentable", "controlsWritable": true,
                "writable": false, "controls": controls, "widgets": document["widgets"]!, "revision": revision, "shortcuts": []])
            case "/camera.mjpg": viewers.add(conn)
            default: conn.respond(404, text: "fixture not found")
            }
        }
        http.start(connectionAdmission: admission) { req, conn in
            if release == "m5.2" && (req.path == "/" || req.path == "/index.html") {
                conn.respond(200, "text/html", HTTPOnboarding.page(address: "127.0.0.1", httpsPort: 8047))
            } else { routes(req, conn) }
        }
        https.start(connectionAdmission: admission, routes)
        try media.startWebSocket(port: 0, identity: identity)
        defer { http.stop(); https.stop(); media.stop() }
        try #require(resourceEventually { (http.port?.rawValue ?? 0) > 0 && (https.port?.rawValue ?? 0) > 0
            && (media.listeningPort?.rawValue ?? 0) > 0 })
        let probe: [String: Any] = ["document": document, "revision": revision, "release": release,
            "web_body": web, "lan_hosts": try lanHosts(), "ports": ["http": http.port!.rawValue,
                "https": https.port!.rawValue, "wss": media.listeningPort!.rawValue]]
        try JSONSerialization.data(withJSONObject: probe).write(to: directory.appendingPathComponent("probe.json"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", root.appendingPathComponent("Tests/OperationalHealth/test_operational_health.py").path,
                             "--fixture", directory.path]
        if let stage = ProcessInfo.processInfo.environment["PHONEDECK_STAGED_HEALTH"] {
            process.arguments! += ["--staged", stage]
        }
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Health helper: \(String(decoding: bytes, as: UTF8.self))")
        let receipt = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(receipt["result"] as? String == "PASS")
        #expect(receipt["release_policy"] as? String == release)
        #expect(receipt["revision"] as? String == revision)
        #expect(try Data(contentsOf: directory.appendingPathComponent("config.json")) == original)
    }
}
