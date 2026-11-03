import Network
import Foundation
import Testing
@testable import oldphonedeck

/// Real Network.framework connections, harmless handlers, no application startup or user files.
@Suite(.serialized)
final class HTTPConnectionTests {
    private let queue = DispatchQueue(label: "http-test-server")
    private var listener: NWListener!
    private var calls = 0

    deinit { listener?.cancel() }

    private func start(timeout: TimeInterval = 0.25, responseDelay: TimeInterval = 0) throws -> NWEndpoint.Port {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            HTTPConnection(conn, headerTimeout: timeout, bodyTimeout: timeout).start(queue: self.queue,
                admission: { DeckRoute.admit($0, token: "socket-test-token") }) { _, connection in
                    self.calls += 1
                    self.queue.asyncAfter(deadline: .now() + responseDelay) { connection.respond(text: "handled") }
                }
        }
        listener.start(queue: queue)
        try #require(ready.wait(timeout: .now() + 3) == .success)
        return try #require(listener.port)
    }

    private func exchange(port: NWEndpoint.Port, chunks: [(TimeInterval, String)], halfClose: Bool = false) throws -> String {
        let clientQueue = DispatchQueue(label: "http-test-client")
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let closed = DispatchSemaphore(value: 0)
        var response = Data()
        var reading = false
        func receive() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { response.append(data) }
                if done || error != nil { closed.signal() } else { receive() }
            }
        }
        client.stateUpdateHandler = { state in
            if case .ready = state, !reading {
                reading = true
                receive()
                for (index, chunk) in chunks.enumerated() {
                    let (delay, text) = chunk
                    clientQueue.asyncAfter(deadline: .now() + delay) {
                        client.send(content: Data(text.utf8),
                                    contentContext: halfClose && index == chunks.count - 1 ? .finalMessage : .defaultMessage,
                                    completion: .idempotent)
                    }
                }
            }
        }
        client.start(queue: clientQueue)
        defer { client.cancel() }
        try #require(closed.wait(timeout: .now() + 3) == .success)
        return clientQueue.sync { String(decoding: response, as: UTF8.self) }
    }

    @Test func testSocketRejectsUnauthenticatedDeclarationWithoutWaitingForBody() throws {
        let port = try start(timeout: 2)
        let response = try exchange(port: port, chunks: [(0, "POST /claude HTTP/1.1\r\nContent-Length: 536870912\r\n\r\n")])
        #expect(response.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(response.contains("Connection: close\r\n"))
        #expect(queue.sync { calls } == 0)
    }

    @Test func testSocketRejectsAdmittedOversizeDeclarationWithoutWaitingForBody() throws {
        let port = try start(timeout: 2)
        let response = try exchange(port: port, chunks: [(0, "POST /media?k=socket-test-token HTTP/1.1\r\nContent-Length: 1025\r\n\r\n")])
        #expect(response.hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
        #expect(queue.sync { calls } == 0)
    }

    @Test func testHeaderAbsoluteDeadlineDespiteTrickle() throws {
        let port = try start(timeout: 0.4)
        let start = Date()
        let response = try exchange(port: port, chunks: [(0, "GET / HTTP/1.1\r\nX: "), (0.1, "a"), (0.2, "b"), (0.32, "c")])
        #expect(Date().timeIntervalSince(start) < 0.65)
        #expect(response.isEmpty)
        #expect(queue.sync { calls } == 0)
    }

    @Test func testBodyAbsoluteDeadlineDespiteTrickle() throws {
        let port = try start(timeout: 0.4)
        let start = Date()
        let response = try exchange(port: port, chunks: [(0, "POST /media?k=socket-test-token HTTP/1.1\r\nContent-Length: 10\r\n\r\na"),
                                                     (0.1, "b"), (0.2, "c"), (0.32, "d")])
        #expect(Date().timeIntervalSince(start) < 0.65)
        #expect(response.isEmpty)
        #expect(queue.sync { calls } == 0)
    }

    @Test func testCompleteBodyInvokesHandlerExactlyOnce() throws {
        let port = try start(timeout: 2)
        let response = try exchange(port: port, chunks: [(0, "POST /media?k=socket-test-token HTTP/1.1\r\nContent-Length: 3\r\n\r\na"), (0.05, "bc")])
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.hasSuffix("handled"))
        #expect(queue.sync { calls } == 1)
    }

    @Test func testRequestDeadlineEndsBeforeResponseHandling() throws {
        let port = try start(timeout: 0.1, responseDelay: 0.3)
        let response = try exchange(port: port, chunks: [(0, "GET / HTTP/1.1\r\n\r\n")])
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(queue.sync { calls } == 1)
    }

    @Test func testAdmittedBodyGetsFreshDeadline() throws {
        let port = try start(timeout: 0.4)
        let response = try exchange(port: port, chunks: [(0.25, "POST /media?k=socket-test-token HTTP/1.1\r\nContent-Length: 3\r\n\r\na"),
                                                     (0.5, "bc")])
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(queue.sync { calls } == 1)
    }

    @Test func testIncompleteBodyEOFDoesNotInvokeHandler() throws {
        let port = try start(timeout: 2)
        let response = try exchange(port: port, chunks: [(0, "POST /media?k=socket-test-token HTTP/1.1\r\nContent-Length: 3\r\n\r\na")], halfClose: true)
        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(queue.sync { calls } == 0)
    }
}
