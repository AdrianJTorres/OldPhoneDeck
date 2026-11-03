import Foundation
import Network
import Testing
@testable import oldphonedeck

/// Loopback HTTP only: no application startup, no real token, no launcher configuration and
/// no NSWorkspace. The routes closure is the production dispatch order for the one migrated
/// route — `DeckRoute.match` → `DeckRoute.validateParameters` → `AppLaunchAdapter` — with the
/// rest of the route table standing in as `404`, so `POST /launch` is exercised end to end
/// while the registry is wired to test doubles.
@Suite(.serialized)
struct AppLaunchRouteTests {
    private let token = "action-boundary-test"

    private func startServer(recorder: LaunchRecorder,
                             catalog: FakeAppCatalog = FakeAppCatalog()) throws -> (HTTPServer, NWEndpoint.Port) {
        let server = try HTTPServer(port: 0, queue: DispatchQueue(label: "app-launch-route-test"),
                                    budget: HTTPConnectionBudget())
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        server.start(admission: { DeckRoute.admit($0, token: self.token) }) { req, conn in
            guard let route = DeckRoute.match(method: req.method, path: req.path), route == .launch else {
                return conn.respond(404, text: "not found")
            }
            if let failure = DeckRoute.validateParameters(req) {
                return conn.respond(failure.status, text: failure.message)
            }
            if let failure = AppLaunchAdapter.handle(req.params, registry: registry) {
                return conn.respond(failure.status, text: failure.message)
            }
            conn.respond(text: "ok")
        }
        try #require(resourceEventually { (server.port?.rawValue ?? 0) > 0 })
        return (server, try #require(server.port))
    }

    /// The frontend's own request shape: `xhr('POST', url('/launch'), 'path=' + encodeURIComponent(p))`.
    private func post(port: NWEndpoint.Port, target: String, body: String) throws -> String {
        let client = ResourceTestClient(port: port)
        defer { client.cancel() }
        client.send("POST \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    + body)
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    private func send(port: NWEndpoint.Port, _ request: String) throws -> String {
        let client = ResourceTestClient(port: port)
        defer { client.cancel() }
        client.send(request)
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    private func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    @Test func postLaunchRetainsItsApiResponseShape() throws {
        let recorder = LaunchRecorder()
        let (server, port) = try startServer(recorder: recorder)
        defer { server.stop() }
        let approved = FakeAppCatalog.approved[3] // contains a space, as real paths do
        let response = try post(port: port, target: "/launch?k=\(token)", body: "path=" + formEncode(approved))
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        #expect(response.contains("Content-Length: 2\r\n"))
        #expect(response.contains("Cache-Control: no-store\r\n"))
        #expect(response.contains("Connection: close\r\n"))
        #expect(response.hasSuffix("\r\n\r\nok"))
        // Acceptance means the authorized path reached the controlled executor exactly once.
        #expect(recorder.paths == [approved])
    }

    @Test func existingTokenAndMethodAdmissionStillApplies() throws {
        let recorder = LaunchRecorder()
        let (server, port) = try startServer(recorder: recorder)
        defer { server.stop() }
        let body = "path=" + formEncode(FakeAppCatalog.approved[0])
        let noToken = try post(port: port, target: "/launch", body: body)
        #expect(noToken.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        let wrongToken = try post(port: port, target: "/launch?k=not-the-token", body: body)
        #expect(wrongToken.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        let bodyToken = try post(port: port, target: "/launch", body: "k=\(token)&" + body)
        #expect(bodyToken.hasPrefix("HTTP/1.1 403 Forbidden\r\n")) // a body token cannot authenticate
        let duplicate = try post(port: port, target: "/launch?k=\(token)&k=\(token)", body: body)
        #expect(duplicate.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        let wrongMethod = try send(port: port, "GET /launch?k=\(token) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(wrongMethod.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
        #expect(recorder.count == 0)
    }

    @Test func unknownAppRetainsIts404() throws {
        let recorder = LaunchRecorder()
        let (server, port) = try startServer(recorder: recorder,
                                             catalog: FakeAppCatalog([FakeAppCatalog.approved[0]]))
        defer { server.stop() }
        for body in ["path=" + formEncode("/Applications/NotInstalled.app"), "path=" + formEncode("/tmp/evil.app"),
                     "path=", "", "path=" + formEncode("/Applications/Safari.app ")] {
            let response = try post(port: port, target: "/launch?k=\(token)", body: body)
            #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
            #expect(response.hasSuffix("\r\n\r\nunknown app"))
        }
        #expect(recorder.count == 0)
    }

    @Test func validAppIsAcceptedOncePerRequest() throws {
        let recorder = LaunchRecorder()
        let (server, port) = try startServer(recorder: recorder)
        defer { server.stop() }
        for path in [FakeAppCatalog.approved[0], FakeAppCatalog.approved[2]] {
            let response = try post(port: port, target: "/launch?k=\(token)", body: "path=" + formEncode(path))
            #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(response.hasSuffix("\r\n\r\nok"))
        }
        // One request per connection; each acceptance dispatched one launch, in order.
        #expect(recorder.paths == [FakeAppCatalog.approved[0], FakeAppCatalog.approved[2]])
    }

    @Test func overlongPathsRetainTheirRejection() throws {
        let recorder = LaunchRecorder()
        let (server, port) = try startServer(recorder: recorder)
        defer { server.stop() }
        // 4097 decoded bytes: the existing route check rejects before the boundary is asked.
        let decoded = try post(port: port, target: "/launch?k=\(token)",
                               body: "path=" + String(repeating: "a", count: 4097))
        #expect(decoded.hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
        #expect(decoded.hasSuffix("\r\n\r\napp path too long"))
        // A declared body above the 16 KiB route limit is still rejected during admission.
        let declared = try send(port: port, "POST /launch?k=\(token) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                                + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 16385\r\n\r\n")
        #expect(declared.hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
        #expect(declared.hasSuffix("\r\n\r\nbody too large"))
        // 4096 decoded bytes is admitted by the route, then rejected as unapproved.
        let atLimit = try post(port: port, target: "/launch?k=\(token)",
                               body: "path=" + String(repeating: "a", count: 4096))
        #expect(atLimit.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(atLimit.hasSuffix("\r\n\r\nunknown app"))
        #expect(recorder.count == 0)
    }

    @Test func extraParametersCannotSelectADifferentAction() throws {
        // The server names the action for this route, so extra parameters — an action
        // identifier, a command, arguments, a working directory — are inert data. A repeated
        // `path` decodes to its last value exactly as before M2.3, and is still authorized.
        let recorder = LaunchRecorder()
        let (server, port) = try startServer(recorder: recorder)
        defer { server.stop() }
        let smuggled = try post(port: port, target: "/launch?k=\(token)",
                                body: "path=" + formEncode(FakeAppCatalog.approved[0])
                                    + "&action=shell.exec&cmd=rm+-rf&argv=-rf&cwd=/&path=" + formEncode("/bin/sh"))
        #expect(smuggled.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(smuggled.hasSuffix("\r\n\r\nunknown app"))
        #expect(recorder.count == 0)
        // A client-named action parameter changes nothing: only an approved path executes.
        let clean = try post(port: port, target: "/launch?k=\(token)",
                             body: "action=app.launch&path=" + formEncode(FakeAppCatalog.approved[0]))
        #expect(clean.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(recorder.paths == [FakeAppCatalog.approved[0]])
    }
}
