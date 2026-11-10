import Foundation
import Network
import Testing
@testable import oldphonedeck

struct HTTPTransportPolicyTests {
    private let token = "synthetic-transport-token"

    private func transport(_ address: String, tls: Bool = false) -> HTTPTransport {
        HTTPTransport(isTLS: tls, peer: .hostPort(host: NWEndpoint.Host(address), port: 12345))
    }

    @Test(arguments: ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1", "::ffff:127.1.2.3"])
    func numericLoopbackAddressesAreRecognized(_ address: String) {
        #expect(transport(address).isLoopback)
    }

    @Test(arguments: ["192.168.0.10", "10.0.0.1", "126.255.255.255", "128.0.0.1", "2001:db8::1", "fe80::1", "::ffff:192.168.0.10", "::127.0.0.1", "0.0.0.0", "::", "localhost", "127.0.0.1.example"])
    func remoteAndUnresolvedPeersNeverGetLocalAccess(_ address: String) {
        #expect(!transport(address).isLoopback)
    }

    @Test func missingAndNonIPPeersFailClosed() {
        #expect(!HTTPTransport(isTLS: false, peer: nil).isLoopback)
        #expect(!HTTPTransport(isTLS: false, peer: .unix(path: "/tmp/fixture")).isLoopback)
    }

    @Test func everyRouteHasExplicitTransportAndAuthenticationPolicy() throws {
        for address in ["192.168.0.10", "2001:db8::1", "127.0.0.1", "::1", "::ffff:127.0.0.1"] {
            let clear = transport(address)
            for route in DeckRoute.allCases {
                let camera = route == .cameraStream || route == .cameraFrame
                for credential in [token, "invalid", ""] {
                    let head = HTTPRequestHead(method: route.method, path: route.path,
                        query: credential.isEmpty ? [:] : ["k": credential],
                        headers: ["forwarded": "for=127.0.0.1;proto=https", "x-forwarded-for": "::1", "x-forwarded-proto": "https", "host": "localhost"], contentLength: 0)
                    let result = DeckRoute.admit(head, token: token, transport: clear)
                    let allowed = route.isPublic || (clear.isLoopback && camera && credential == token)
                    if allowed { #expect(try result.get() == route.bodyLimit) }
                    else { #expect(result == .failure(HTTPFailure(status: 403, message: clear.isLoopback && camera ? "bad token" : "HTTPS required"))) }
                    let secure = DeckRoute.admit(head, token: token, transport: transport(address, tls: true))
                    if route.isPublic || credential == token { #expect(try secure.get() == route.bodyLimit) }
                    else { #expect(secure == .failure(HTTPFailure(status: 403, message: "bad token"))) }
                }
            }
        }
    }

    @Test func deniedBodyIsNeverRetainedOrDispatched() {
        for route in DeckRoute.allCases where !route.isPublic {
            var parser = HTTPRequestParser()
            let wire = "\(route.method) \(route.path)?k=\(token) HTTP/1.1\r\nContent-Length: 65536\r\n\r\n" + String(repeating: "x", count: 4096)
            var dispatched = false
            do {
                if try parser.receive(Data(wire.utf8), admission: { DeckRoute.admit($0, token: token, transport: transport("2001:db8::1")) }) != nil {
                    dispatched = true
                }
                Issue.record("Expected transport refusal")
            } catch { #expect((error as? HTTPFailure) == HTTPFailure(status: 403, message: "HTTPS required")) }
            #expect(parser.bufferedBodyBytes == 0)
            #expect(!dispatched)
        }
    }

    @Test func unlistedMethodsAndPathsCannotUseLoopbackException() {
        for (method, path) in [("POST", "/camera.mjpg"), ("POST", "/camera.jpg"), ("POST", "/"), ("GET", "/missing"), ("GET", "/camera.mjpg/"), ("GET", "/camera.jpg/../launch")] {
            let head = HTTPRequestHead(method: method, path: path, query: ["k": token], headers: [:], contentLength: 0)
            #expect(DeckRoute.admit(head, token: token, transport: transport("::1")) == .failure(HTTPFailure(status: 403, message: "HTTPS required")))
        }
    }

    @Test func onboardingHasNoCredentialFlowOrRedirect() {
        let page = String(decoding: HTTPOnboarding.page(address: "192.0.2.1", httpsPort: 8047), as: UTF8.self)
        #expect(page.contains("https://192.0.2.1:8047/"))
        #expect(page.contains("href=\"/oldphonedeck.mobileconfig\""))
        for forbidden in ["<script", "<input", "<form", "?k=", "#k=", "localStorage", "http-equiv", "location."] {
            #expect(!page.contains(forbidden))
        }
        #expect(String(decoding: HTTPOnboarding.page(address: "::1", httpsPort: 8047), as: UTF8.self).contains("https://[::1]:8047/"))
    }
}

/// Native listeners with the production admission and fake executor, no application startup.
@Suite(.serialized)
struct HTTPTransportBoundaryTests {
    private let token = "synthetic-transport-token"

    private func lanHost(family: Int32) throws -> NWEndpoint.Host {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        try #require(getifaddrs(&addresses) == 0)
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let item = cursor {
            let interface = item.pointee
            if String(cString: interface.ifa_name) == "en0", let sa = interface.ifa_addr,
               sa.pointee.sa_family == UInt8(family) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if family == AF_INET || IPv6Address(value)?.isLinkLocal == false { return NWEndpoint.Host(value) }
                }
            }
            cursor = interface.ifa_next
        }
        throw NSError(domain: "isolated-smoke-requires-LAN-address", code: Int(family))
    }

    private func start(parameters: NWParameters = .tcp, recorder: LaunchRecorder) throws -> HTTPServer {
        let server = try HTTPServer(port: 0, parameters: parameters)
        let registry = testRegistry(recorder: recorder)
        server.start(connectionAdmission: { DeckRoute.admit($0, token: token, transport: $1) }) { req, conn in
            if req.path == "/launch" { AppLaunchRoute.handle(req, registry: registry, on: conn) }
            else if req.path == "/camera.mjpg" { conn.beginMJPEG(); conn.pushFrame(Data([0xff, 0xd8, 0xff, 0xd9])) }
            else if req.path == "/" || req.path == "/index.html" {
                conn.respond(200, "text/html", HTTPOnboarding.page(address: "127.0.0.1", httpsPort: 8047))
            } else { conn.respond(text: "fixture:" + req.path) }
        }
        try #require(resourceEventually { (server.port?.rawValue ?? 0) > 0 })
        return server
    }

    private func exchange(_ wire: String, server: HTTPServer, host: NWEndpoint.Host = "127.0.0.1", parameters: NWParameters = .tcp) throws -> String {
        let client = ResourceTestClient(port: try #require(server.port), parameters: parameters, host: host)
        defer { client.cancel() }
        client.send(wire)
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    @Test(arguments: [AF_INET, AF_INET6])
    func actualLANPeerCannotUseAnyAuthenticatedHTTPRoute(family: Int32) throws {
        let host = try lanHost(family: family)
        let recorder = LaunchRecorder()
        let server = try start(recorder: recorder)
        defer { server.stop() }
        for route in DeckRoute.allCases where !route.isPublic {
            // Declared body withheld: the refusal must arrive before it could be dispatched.
            let response = try exchange("\(route.method) \(route.path)?k=\(token) HTTP/1.1\r\nHost: localhost\r\nForwarded: for=127.0.0.1;proto=https\r\nX-Forwarded-For: ::1\r\nX-Forwarded-Proto: https\r\nContent-Length: \(route.method == "POST" ? 16 : 0)\r\n\r\n", server: server, host: host)
            #expect(response.hasPrefix("HTTP/1.1 403 Forbidden"))
            #expect(response.hasSuffix("HTTPS required"))
            #expect(!response.contains(token) && !response.contains("Location:"))
        }
        for path in ["/", "/index.html", "/oldphonedeck.mobileconfig"] {
            let response = try exchange("GET \(path) HTTP/1.1\r\nHost: fixture\r\n\r\n", server: server, host: host)
            #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        }
        #expect(recorder.count == 0)
    }

    @Test(arguments: ["127.0.0.1", "::1", "::ffff:127.0.0.1"])
    func loopbackRetainsOnlyAuthenticatedCameraReads(address: String) throws {
        let recorder = LaunchRecorder()
        let server = try start(recorder: recorder)
        defer { server.stop() }
        let host = NWEndpoint.Host(address)
        for key in ["", "?k=wrong"] {
            let response = try exchange("GET /camera.jpg\(key) HTTP/1.1\r\n\r\n", server: server, host: host)
            #expect(response.hasPrefix("HTTP/1.1 403 Forbidden"))
        }
        let frame = try exchange("GET /camera.jpg?k=\(token) HTTP/1.1\r\n\r\n", server: server, host: host)
        #expect(frame.hasPrefix("HTTP/1.1 200 OK"))
        for route in DeckRoute.allCases where !route.isPublic && route != .cameraStream && route != .cameraFrame {
            let response = try exchange("\(route.method) \(route.path)?k=\(token) HTTP/1.1\r\nContent-Length: 0\r\n\r\n", server: server, host: host)
            #expect(response.hasPrefix("HTTP/1.1 403 Forbidden"))
        }
        let viewer = ResourceTestClient(port: try #require(server.port), host: host)
        defer { viewer.cancel() }
        viewer.send("GET /camera.mjpg?k=\(token) HTTP/1.1\r\n\r\n")
        try #require(resourceEventually { viewer.text.contains("multipart/x-mixed-replace") && viewer.data.range(of: Data([0xff, 0xd8, 0xff, 0xd9])) != nil })
        #expect(recorder.count == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
    func actualHTTPSRetainsAuthenticatedActionsAndRejectsInvalidTokens() throws {
        let identity = try resourceTestIdentity()
        let recorder = LaunchRecorder()
        let server = try start(parameters: LocalTLS.parameters(identity), recorder: recorder)
        defer { server.stop() }
        let body = "path=" + FakeAppCatalog.approved[0]
        for key in ["", "?k=wrong", "?k=\(token)"] {
            let response = try exchange("POST /launch\(key) HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", server: server, parameters: resourceTLSClient())
            #expect(response.hasPrefix(key == "?k=\(token)" ? "HTTP/1.1 200 OK" : "HTTP/1.1 403 Forbidden"))
        }
        #expect(recorder.paths == [FakeAppCatalog.approved[0]])
        for route in DeckRoute.allCases where route != .cameraStream && route != .launch {
            let response = try exchange("\(route.method) \(route.path)?k=\(token) HTTP/1.1\r\nContent-Length: 0\r\n\r\n", server: server, parameters: resourceTLSClient())
            #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        }
    }
}
