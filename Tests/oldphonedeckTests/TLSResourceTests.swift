import Foundation
import Network
import Security
import Testing
@testable import oldphonedeck

/// Creates an ephemeral identity; never reads ~/.oldphonedeck or imports into a keychain.
func resourceTestIdentity() throws -> sec_identity_t {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phonedeck-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    guard #available(macOS 15.0, *) else { throw NSError(domain: "test-requires-memory-only-import", code: 1) }
    return try #require(LocalTLS.identity(for: "127.0.0.1", in: directory))
}

func resourceTLSClient(websocket: Bool = false) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    // Only the local ephemeral test identity is trusted; production TLS policy is untouched.
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue(label: "test-tls-verify"))
    let parameters = NWParameters(tls: tls)
    if websocket { parameters.defaultProtocolStack.applicationProtocols.insert(LocalTLS.webSocketOptions(), at: 0) }
    return parameters
}

struct TLSResourceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15,
                   "Requires memory-only certificate import; never install test certificates"))
    func httpsAndWSSUseProductionParametersWithoutUserConfiguration() throws {
        let identity = try resourceTestIdentity()
        let queue = DispatchQueue(label: "http-https-shared-test")
        let budget = HTTPConnectionBudget(limit: 2)
        let http = try HTTPServer(port: 0, queue: queue, budget: budget)
        let https = try HTTPServer(port: 0, parameters: LocalTLS.parameters(identity), queue: queue, budget: budget)
        let viewers = MJPEGViewers()
        let admission: HTTPTransportAdmission = { DeckRoute.admit($0, token: "fixture-token", transport: $1) }
        let handler: (HTTPRequest, HTTPConnection) -> Void = { request, c in
            if request.path == "/camera.mjpg" { viewers.add(c) }
            else { c.respond(text: request.path) }
        }
        http.start(connectionAdmission: admission, handler)
        https.start(connectionAdmission: admission, handler)
        defer { http.stop(); https.stop() }
        try #require(resourceEventually { (http.port?.rawValue ?? 0) > 0 && (https.port?.rawValue ?? 0) > 0 })
        let first = ResourceTestClient(port: try #require(http.port))
        defer { first.cancel() }
        try #require(resourceEventually { first.isReady && budget.count == 1 })
        let secure = ResourceTestClient(port: try #require(https.port), parameters: resourceTLSClient())
        defer { secure.cancel() }
        try #require(resourceEventually { secure.isReady && budget.count == 2 })
        let excess = ResourceTestClient(port: try #require(http.port))
        defer { excess.cancel() }
        #expect(resourceEventually { excess.isClosed })
        #expect(budget.count == 2)
        first.cancel()
        try #require(resourceEventually { budget.count == 1 })
        secure.send("GET /stats?k=fixture-token HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(resourceEventually { secure.isClosed && secure.text.hasSuffix("/stats") })
        #expect(secure.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(resourceEventually { budget.count == 0 })

        let media = PhoneMediaServer(token: "fixture-token", audio: nil)
        let handoff = LatestFrameHandoff(queue: queue) { viewers.pushFrame($0) }
        media.onFrame = { handoff.submit($0) }
        try media.startWebSocket(port: 0, identity: identity)
        defer { media.stop() }
        try #require(resourceEventually { (media.listeningPort?.rawValue ?? 0) > 0 })
        let wrong = ResourceTestClient(port: try #require(media.listeningPort), parameters: resourceTLSClient(websocket: true))
        defer { wrong.cancel() }
        try #require(resourceEventually { wrong.isReady })
        wrong.send(Data("Hwrong".utf8), opcode: .binary)
        try #require(resourceEventually { wrong.isClosed && media.resourceCounts.connections == 0 })
        #expect(media.resourceCounts.producers == 0)
        let phone = ResourceTestClient(port: try #require(media.listeningPort), parameters: resourceTLSClient(websocket: true))
        defer { phone.cancel() }
        try #require(resourceEventually { phone.isReady })
        phone.send(Data("Hfixture-token".utf8), opcode: .binary)
        try #require(resourceEventually { media.resourceCounts.producers == 1 })
        let viewer = ResourceTestClient(port: try #require(http.port))
        defer { viewer.cancel() }
        viewer.send("GET /camera.mjpg?k=fixture-token HTTP/1.1\r\n\r\n")
        try #require(resourceEventually { viewer.text.contains("multipart/x-mixed-replace") })
        // Valid WSS authentication survives the original five-second auth deadline.
        Thread.sleep(forTimeInterval: 5.1)
        phone.send(Data("alive".utf8), opcode: .ping)
        try #require(resourceEventually { phone.data == Data("alive".utf8) })
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        phone.send(Data([86]) + jpeg, opcode: .binary)
        #expect(resourceEventually { media.latestFrame == jpeg })
        #expect(resourceEventually { viewer.data.range(of: jpeg) != nil })
        #expect(budget.count == 1)
        viewer.cancel()
        #expect(resourceEventually { budget.count == 0 && queue.sync { viewers.count } == 0 })
        phone.cancel()
        #expect(resourceEventually { media.resourceCounts.connections == 0 && media.resourceCounts.producers == 0 })
    }
}
