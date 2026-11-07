import Foundation
import Network

/// Lifetime: each pending receive/send closure holds the connection strongly; streaming viewers are held by `viewers`.
final class HTTPConnection {
    private let conn: NWConnection
    private let lease: HTTPConnectionBudget.Lease?
    private var parser = HTTPRequestParser()
    private var closed = false
    private var requestFinished = false
    private var deadline: DispatchWorkItem?
    private let headerTimeout: TimeInterval
    private let bodyTimeout: TimeInterval
    private var sending = false
    var onClose: (() -> Void)?

    init(_ conn: NWConnection, lease: HTTPConnectionBudget.Lease? = nil,
         headerTimeout: TimeInterval = 10, bodyTimeout: TimeInterval = 10) {
        self.conn = conn
        self.lease = lease
        self.headerTimeout = headerTimeout
        self.bodyTimeout = bodyTimeout
    }

    func start(queue: DispatchQueue, admission: @escaping HTTPAdmission,
               handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default: break
            }
        }
        // Absolute from acceptance, including connection/TLS setup; never reset by a trickle.
        armDeadline(after: headerTimeout, queue: queue)
        conn.start(queue: queue)
        receive(queue: queue, admission: admission, handler: handler)
    }

    /// All transport callbacks and application uses run on the listener's serial queue.
    func close() {
        guard !closed else { return }
        closed = true
        requestFinished = true
        deadline?.cancel()
        deadline = nil
        parser = HTTPRequestParser()
        conn.cancel()
        lease?.release()
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func armDeadline(after seconds: TimeInterval, queue: DispatchQueue) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.requestFinished else { return }
            // Cancel directly: even a connection that never becomes ready must be bounded.
            self.close()
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func receive(queue: DispatchQueue, admission: @escaping HTTPAdmission,
                         handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: parser.maximumReceiveLength) { data, _, done, error in
            guard !self.requestFinished else { return }
            do {
                let wasHeaders = self.parser.phase == .headers
                if let request = try self.parser.receive(data ?? Data(), admission: admission) {
                    self.requestFinished = true
                    self.deadline?.cancel()
                    self.deadline = nil
                    handler(request, self)
                    return
                }
                if wasHeaders && self.parser.phase == .body {
                    self.armDeadline(after: self.bodyTimeout, queue: queue)
                }
                if error != nil { self.close(); return }
                if done { self.respond(400, text: "incomplete request"); return }
                self.receive(queue: queue, admission: admission, handler: handler)
            } catch let failure as HTTPFailure {
                self.respond(failure.status, text: failure.message)
            } catch {
                self.respond(400, text: "invalid request")
            }
        }
    }

    func respond(_ status: Int = 200, _ type: String = "text/plain; charset=utf-8", _ body: Data) {
        guard !closed else { return }
        requestFinished = true
        deadline?.cancel()
        deadline = nil
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 411: "Length Required",
                      413: "Content Too Large", 414: "URI Too Long", 417: "Expectation Failed",
                      431: "Request Header Fields Too Large",
                      500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in self.close() })
    }

    func respond(_ status: Int = 200, text: String) { respond(status, "text/plain; charset=utf-8", Data(text.utf8)) }

    func respondJSON(_ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("null".utf8)
        respond(200, "application/json", data)
    }

    // MARK: MJPEG streaming (multipart/x-mixed-replace, supported by Safari since forever)

    func beginMJPEG() {
        guard !closed else { return }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n--frame\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil { self.close() }
        })
        watchStreamClose()
    }

    // A stream must observe peer EOF even when no camera frames are being sent.
    // No further request data is valid on this one-request connection.
    private func watchStreamClose() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, done, error in
            guard !self.closed else { return }
            if done || error != nil || data?.isEmpty == false { self.close() }
            else { self.watchStreamClose() }
        }
    }

    /// Sends a frame unless the previous one is still in flight (drop frames instead of building latency).
    @discardableResult
    func pushFrame(_ jpeg: Data) -> Bool {
        guard !closed, !sending else { return false }
        sending = true
        // Each part ends with the next boundary: browsers only paint a part once they see that boundary,
        // and a still desktop may not produce another frame for a long time.
        let part = Data("Content-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8) + jpeg + Data("\r\n--frame\r\n".utf8)
        conn.send(content: part, completion: .contentProcessed { error in
            self.sending = false
            if error != nil { self.close() }
        })
        return true
    }
}

final class HTTPServer {
    private let listener: NWListener
    let queue: DispatchQueue
    let budget: HTTPConnectionBudget
    var port: NWEndpoint.Port? { listener.port }

    init(port: UInt16, parameters: NWParameters = .tcp, queue: DispatchQueue = DispatchQueue(label: "http"),
         budget: HTTPConnectionBudget = HTTPConnectionBudget()) throws {
        self.queue = queue
        self.budget = budget
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start(admission: @escaping HTTPAdmission, _ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        listener.newConnectionHandler = { [queue, budget] nw in
            // Excess connections are cancelled before starting TLS or allocating a parser.
            guard let lease = budget.acquire() else { nw.cancel(); return }
            HTTPConnection(nw, lease: lease).start(queue: queue, admission: admission, handler: handler)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { print("Server failed: \(e)"); exit(1) }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }
}

/// Owned by the shared HTTP queue. Entries leave synchronously on connection close.
final class MJPEGViewers {
    private var viewers: [ObjectIdentifier: HTTPConnection] = [:]
    var count: Int { viewers.count }

    @discardableResult
    func add(_ connection: HTTPConnection, latest: Data? = nil) -> Bool {
        let id = ObjectIdentifier(connection)
        guard viewers[id] == nil else { return false }
        guard viewers.count < 2 else {
            connection.respond(503, text: "too many camera viewers")
            return false
        }
        viewers[id] = connection
        connection.onClose = { [weak self] in self?.viewers[id] = nil }
        connection.beginMJPEG()
        if let latest { connection.pushFrame(latest) }
        return true
    }

    func pushFrame(_ jpeg: Data) {
        for viewer in viewers.values { viewer.pushFrame(jpeg) }
    }
}
