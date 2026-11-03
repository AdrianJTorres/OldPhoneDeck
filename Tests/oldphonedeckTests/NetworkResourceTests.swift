import Foundation
import Network
import Security
import Testing
@testable import oldphonedeck

/// Loopback client only; no application startup, real token, audio device or user configuration.
final class ResourceTestClient {
    private let queue = DispatchQueue(label: "resource-test-client")
    private let connection: NWConnection
    private let websocket: Bool
    private let lock = NSLock()
    private var received = Data()
    private var ended = false
    private var ready = false
    private var lastState = "setup"

    init(port: NWEndpoint.Port, parameters: NWParameters = .tcp) {
        websocket = parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolWebSocket.Options }
        if websocket {
            let scheme = parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options } ? "wss" : "ws"
            connection = NWConnection(to: .url(URL(string: "\(scheme)://127.0.0.1:\(port.rawValue)/")!), using: parameters)
        } else { connection = NWConnection(host: "127.0.0.1", port: port, using: parameters) }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock(); self.lastState = String(describing: state); self.lock.unlock()
            if case .ready = state {
                self.lock.lock(); self.ready = true; self.lock.unlock()
                self.receive()
            }
            if case .failed = state { self.markEnded() }
            if case .waiting = state { self.markEnded() } // Rejection before a WS handshake becomes ready.
        }
        connection.start(queue: queue)
    }

    deinit { connection.cancel() }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    var state: String { lock.lock(); defer { lock.unlock() }; return lastState }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    var data: Data { lock.lock(); defer { lock.unlock() }; return received }
    var text: String { String(decoding: data, as: UTF8.self) }
    func cancel() { connection.cancel() }

    func send(_ text: String) { send(Data(text.utf8)) }
    func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode? = nil) {
        let context: NWConnection.ContentContext
        if let opcode {
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            if opcode == .close { metadata.closeCode = .protocolCode(.normalClosure) }
            context = NWConnection.ContentContext(identifier: "test-message", metadata: [metadata])
        } else { context = .defaultMessage }
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func sendFragmented(_ first: Data, _ second: Data) {
        let context = NWConnection.ContentContext(identifier: "fragmented-test", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: first, contentContext: context, isComplete: false, completion: .contentProcessed { _ in })
        connection.send(content: second, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func markEnded() { lock.lock(); ended = true; lock.unlock() }
    private func receive() {
        let completion: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, complete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.received.append(data) }
            self.lock.unlock()
            if error != nil || (complete && data == nil) { self.markEnded() }
            else { self.receive() }
        }
        if websocket { connection.receiveMessage(completion: completion) }
        else { connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: completion) }
    }
}

func resourceEventually(_ check: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if check() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    } while Date() < deadline
    return check()
}

@Suite(.serialized)
struct HTTPResourceTests {
    @Test func twoListenersShareTheFull32ConnectionBudget() throws {
        let queue = DispatchQueue(label: "shared-http-test")
        let budget = HTTPConnectionBudget()
        let first = try HTTPServer(port: 0, queue: queue, budget: budget)
        let second = try HTTPServer(port: 0, queue: queue, budget: budget)
        first.start(admission: { _ in .success(0) }) { _, c in c.respond(text: "first") }
        second.start(admission: { _ in .success(0) }) { _, c in c.respond(text: "second") }
        defer { first.stop(); second.stop() }
        try #require(resourceEventually { (first.port?.rawValue ?? 0) > 0 && (second.port?.rawValue ?? 0) > 0 })
        let ports = [try #require(first.port), try #require(second.port)]
        var clients: [ResourceTestClient] = []
        defer { for client in clients { client.cancel() } }
        for i in 0..<32 {
            let client = ResourceTestClient(port: ports[i % 2])
            clients.append(client)
            try #require(resourceEventually { budget.count == i + 1 })
        }
        let excess = ResourceTestClient(port: ports[1])
        defer { excess.cancel() }
        #expect(resourceEventually { excess.isClosed })
        #expect(budget.count == 32)
        clients[0].cancel()
        try #require(resourceEventually { budget.count == 31 })
        let replacement = ResourceTestClient(port: ports[1])
        defer { replacement.cancel() }
        #expect(resourceEventually { budget.count == 32 })
        for client in clients { client.cancel() }
        replacement.cancel()
        #expect(resourceEventually { budget.count == 0 })
    }

    @Test(arguments: ["response", "parser", "header-timeout", "body-timeout", "disconnect", "cancel", "mjpeg"])
    func eachHTTPClosePathReturnsItsLeaseExactlyOnce(reason: String) throws {
        let queue = DispatchQueue(label: "http-close-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let budget = HTTPConnectionBudget(limit: 1)
        var connections: [HTTPConnection] = [] // queue-owned
        var closed = 0
        listener.newConnectionHandler = { nw in
            guard let lease = budget.acquire() else { nw.cancel(); return }
            let c = HTTPConnection(nw, lease: lease, headerTimeout: 0.15, bodyTimeout: 0.15)
            connections.append(c)
            c.onClose = { closed += 1 }
            c.start(queue: queue, admission: { DeckRoute.admit($0, token: "test") }) { _, c in
                if reason == "mjpeg" { c.beginMJPEG() } else { c.respond(text: "ok") }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        try #require(resourceEventually { (listener.port?.rawValue ?? 0) > 0 })
        let client = ResourceTestClient(port: try #require(listener.port))
        defer { client.cancel() }
        try #require(resourceEventually { budget.count == 1 })
        switch reason {
        case "response": client.send("GET / HTTP/1.1\r\n\r\n")
        case "parser": client.send("GET / HTTP/1.1\n\n")
        case "body-timeout": client.send("POST /media?k=test HTTP/1.1\r\nContent-Length: 10\r\n\r\na")
        case "disconnect": client.cancel()
        case "cancel": queue.sync { connections[0].close(); connections[0].close() }
        case "mjpeg":
            client.send("GET /camera.mjpg?k=test HTTP/1.1\r\n\r\n")
            try #require(resourceEventually { client.text.contains("multipart/x-mixed-replace") })
            #expect(budget.count == 1)
            client.cancel() // Must be observed even without a camera frame arriving.
        default: break // Header deadline.
        }
        try #require(resourceEventually { budget.count == 0 })
        queue.sync {
            connections[0].close(); connections[0].close()
            #expect(closed == 1)
        }
        let replacement = try #require(budget.acquire())
        #expect(budget.acquire() == nil)
        replacement.release()
        if reason == "response" { #expect(client.text.hasPrefix("HTTP/1.1 200 OK")) }
        if reason == "parser" { #expect(client.text.hasPrefix("HTTP/1.1 400 Bad Request")) }
    }

    @Test func viewerCapDisconnectRepeatedCloseAndFrameDropping() throws {
        let queue = DispatchQueue(label: "mjpeg-cap-test")
        let budget = HTTPConnectionBudget()
        let viewers = MJPEGViewers()
        let server = try HTTPServer(port: 0, queue: queue, budget: budget)
        var accepted: [HTTPConnection] = []
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        server.start(admission: { DeckRoute.admit($0, token: "test") }) { _, c in
            if viewers.add(c, latest: jpeg) { accepted.append(c) }
        }
        defer { server.stop() }
        try #require(resourceEventually { (server.port?.rawValue ?? 0) > 0 })
        let port = try #require(server.port)
        let unauthorized = ResourceTestClient(port: port)
        defer { unauthorized.cancel() }
        unauthorized.send("GET /camera.mjpg HTTP/1.1\r\n\r\n")
        try #require(resourceEventually { unauthorized.isClosed && unauthorized.text.hasPrefix("HTTP/1.1 403 Forbidden") })
        #expect(queue.sync { viewers.count } == 0)
        var clients: [ResourceTestClient] = []
        defer { for client in clients { client.cancel() } }
        for _ in 0..<2 {
            let client = ResourceTestClient(port: port)
            clients.append(client)
            client.send("GET /camera.mjpg?k=test HTTP/1.1\r\n\r\n")
            try #require(resourceEventually { client.data.range(of: jpeg) != nil })
        }
        #expect(queue.sync { viewers.count } == 2)
        #expect(budget.count == 2)
        let excess = ResourceTestClient(port: port)
        defer { excess.cancel() }
        excess.send("GET /camera.mjpg?k=test HTTP/1.1\r\n\r\n")
        #expect(resourceEventually { excess.text.hasPrefix("HTTP/1.1 503 Service Unavailable") && excess.isClosed })
        #expect(queue.sync { viewers.count } == 2)
        clients[0].cancel()
        try #require(resourceEventually { queue.sync { viewers.count } == 1 && budget.count == 1 })
        queue.sync { accepted[0].close(); accepted[0].close(); #expect(viewers.count == 1) }
        let replacement = ResourceTestClient(port: port)
        clients.append(replacement)
        replacement.send("GET /camera.mjpg?k=test HTTP/1.1\r\n\r\n")
        try #require(resourceEventually { replacement.data.range(of: jpeg) != nil })
        #expect(queue.sync { viewers.count } == 2)
        // Completion callbacks cannot run inside this serial-queue block. Only one frame may be enqueued.
        queue.sync {
            var sent = 0
            for _ in 0..<1000 { if accepted.last!.pushFrame(jpeg) { sent += 1 } }
            #expect(sent == 1)
        }
        for client in clients { client.cancel() }
        #expect(resourceEventually { queue.sync { viewers.count } == 0 && budget.count == 0 })
    }
}

@Suite(.serialized)
struct WebSocketResourceTests {
    private func start(timeout: TimeInterval = 2) throws -> (PhoneMediaServer, NWEndpoint.Port) {
        let server = PhoneMediaServer(token: "test-token", audio: nil, authenticationTimeout: timeout)
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(LocalTLS.webSocketOptions(), at: 0)
        try server.startWebSocket(parameters: parameters, on: .any)
        try #require(resourceEventually { (server.listeningPort?.rawValue ?? 0) > 0 })
        return (server, try #require(server.listeningPort))
    }

    private func client(_ port: NWEndpoint.Port) throws -> ResourceTestClient {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(LocalTLS.webSocketOptions(), at: 0)
        let client = ResourceTestClient(port: port, parameters: parameters)
        try #require(resourceEventually { client.isReady }, "WebSocket client state: \(client.state)")
        return client
    }

    @Test func pendingConnectionCapAndAuthenticationDeadlineReleaseSlots() throws {
        let (server, port) = try start(timeout: 0.3)
        defer { server.stop() }
        let first = try client(port), second = try client(port)
        defer { first.cancel(); second.cancel() }
        #expect(server.resourceCounts.connections == 2)
        #expect(server.resourceCounts.producers == 0)
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(LocalTLS.webSocketOptions(), at: 0)
        let excess = ResourceTestClient(port: port, parameters: parameters)
        defer { excess.cancel() }
        #expect(resourceEventually { excess.isClosed })
        #expect(!excess.isReady)
        #expect(resourceEventually { server.resourceCounts.connections == 0 })
        let replacement = try client(port)
        defer { replacement.cancel() }
        replacement.send("Htest-token".data(using: .utf8)!, opcode: .binary)
        #expect(resourceEventually { server.resourceCounts.producers == 1 })
    }

    @Test func incompleteHandshakesAreCountedAndDisconnectRestoresCapacity() throws {
        let (server, port) = try start(timeout: 0.1)
        defer { server.stop() }
        // Raw TCP peers never complete the WebSocket upgrade, so they never become usable.
        let first = ResourceTestClient(port: port), second = ResourceTestClient(port: port)
        defer { first.cancel(); second.cancel() }
        try #require(resourceEventually { server.resourceCounts.connections == 2 })
        let excess = ResourceTestClient(port: port)
        defer { excess.cancel() }
        #expect(resourceEventually { excess.isClosed })
        Thread.sleep(forTimeInterval: 0.15)
        #expect(server.resourceCounts.connections == 2)
        #expect(server.resourceCounts.producers == 0)
        first.cancel(); second.cancel()
        #expect(resourceEventually { server.resourceCounts.connections == 0 })
    }

    @Test func producerExclusionDisconnectAndDeadlineCancellation() throws {
        let (server, port) = try start(timeout: 0.15)
        defer { server.stop() }
        let pending = try client(port), producer = try client(port)
        defer { pending.cancel(); producer.cancel() }
        producer.send(Data("Htest-token".utf8), opcode: .binary)
        try #require(resourceEventually { server.resourceCounts.producers == 1 })
        pending.send(Data("Htest-token".utf8), opcode: .binary)
        try #require(resourceEventually { server.resourceCounts.connections == 1 })
        #expect(server.resourceCounts.producers == 1)
        Thread.sleep(forTimeInterval: 0.2)
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        producer.send(Data([UInt8(ascii: "V")]) + jpeg, opcode: .binary)
        #expect(resourceEventually { server.latestFrame == jpeg })
        producer.cancel()
        try #require(resourceEventually { server.resourceCounts.connections == 0 && server.resourceCounts.producers == 0 })
        let next = try client(port)
        defer { next.cancel() }
        next.send(Data("Htest-token".utf8), opcode: .binary)
        #expect(resourceEventually { server.resourceCounts.producers == 1 })
        server.stop(); server.stop()
        #expect(server.resourceCounts.connections == 0)
    }

    @Test(arguments: ["bad-token", "non-H", "oversize-H", "text-H", "unknown", "odd-audio", "oversize-audio", "empty", "malformed-video", "repeat-H", "text-video", "close"])
    func rejectedMessagesRestoreBothSlots(reason: String) throws {
        let (server, port) = try start()
        defer { server.stop() }
        let peer = try client(port)
        defer { peer.cancel() }
        if ["unknown", "odd-audio", "oversize-audio", "malformed-video", "repeat-H", "text-video", "close"].contains(reason) {
            peer.send(Data("Htest-token".utf8), opcode: .binary)
            try #require(resourceEventually { server.resourceCounts.producers == 1 })
        }
        switch reason {
        case "bad-token": peer.send(Data("Hwrong".utf8), opcode: .binary)
        case "non-H": peer.send(Data("Vtest-token".utf8), opcode: .binary)
        case "oversize-H": peer.send(Data("H".utf8) + Data(repeating: 97, count: 256), opcode: .binary)
        case "text-H": peer.send(Data("Htest-token".utf8), opcode: .text)
        case "unknown": peer.send(Data("X".utf8), opcode: .binary)
        case "odd-audio": peer.send(Data([65, 0]), opcode: .binary)
        case "oversize-audio": peer.send(Data([65]) + Data(repeating: 0, count: 8194), opcode: .binary)
        case "malformed-video": peer.send(Data("Vjunk".utf8), opcode: .binary)
        case "repeat-H": peer.send(Data("Htest-token".utf8), opcode: .binary)
        case "text-video": peer.send(Data("Vjunk".utf8), opcode: .text)
        case "close": peer.send(Data(), opcode: .close)
        default: peer.send(Data(), opcode: .binary)
        }
        #expect(resourceEventually { server.resourceCounts.connections == 0 && server.resourceCounts.producers == 0 })
    }

    @Test func fragmentedAuthenticationMaximumVideoAndValidAudioAreAccepted() throws {
        let (server, port) = try start()
        defer { server.stop() }
        let peer = try client(port)
        defer { peer.cancel() }
        peer.sendFragmented(Data("Htest-".utf8), Data("token".utf8))
        try #require(resourceEventually { server.resourceCounts.producers == 1 })
        let jpeg = Data([0xff, 0xd8]) + Data(repeating: 0, count: PhoneMediaMessage.maximumMessageSize - 5) + Data([0xff, 0xd9])
        peer.send(Data([86]) + jpeg, opcode: .binary)
        try #require(resourceEventually { server.latestFrame == jpeg })
        peer.send(Data([65]) + Data(repeating: 0, count: 8192), opcode: .binary)
        peer.send(Data([65]), opcode: .binary) // Empty audio is valid and creates no playback work.
        peer.send(Data([9]), opcode: .ping)
        #expect(resourceEventually { peer.data == Data([9]) })
        #expect(server.resourceCounts.producers == 1)
    }

    @Test func pingKeepsFrameworkHandlingAndDoesNotAuthenticate() throws {
        let (server, port) = try start(timeout: 0.2)
        defer { server.stop() }
        let peer = try client(port)
        defer { peer.cancel() }
        peer.send(Data([1]), opcode: .ping)
        #expect(resourceEventually { peer.data == Data([1]) }) // Automatic pong delivered by the framework.
        #expect(server.resourceCounts.producers == 0)
        #expect(resourceEventually { server.resourceCounts.connections == 0 })
    }

    @Test func frameworkRejectsMessagesAboveTwoMiB() throws {
        let (server, port) = try start()
        defer { server.stop() }
        let peer = try client(port)
        defer { peer.cancel() }
        peer.send(Data("Htest-token".utf8), opcode: .binary)
        try #require(resourceEventually { server.resourceCounts.producers == 1 })
        peer.send(Data([86]) + Data(repeating: 0, count: 2 * 1024 * 1024), opcode: .binary)
        #expect(resourceEventually { server.resourceCounts.connections == 0 })
        #expect(server.latestFrame == nil)
    }
}
