import Foundation
import Network
import Testing
@testable import oldphonedeck

private let approvedUUID = ShortcutUUID("11111111-1111-4111-8111-111111111111")!
private let deniedUUID = ShortcutUUID("22222222-2222-4222-8222-222222222222")!
private let listing = Data("PhoneDeck M3.3 UUID Test (11111111-1111-4111-8111-111111111111)\n".utf8)

final class FakeShortcutRunner: ShortcutRunning {
    struct Call {
        let command: ShortcutCommand
        let deadline: TimeInterval
        let timeout: () -> Void
        let completion: (ShortcutProcessResult) -> Void
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    func start(_ command: ShortcutCommand, deadline: TimeInterval, timeout: @escaping () -> Void,
               completion: @escaping (ShortcutProcessResult) -> Void) {
        lock.lock(); recorded.append(Call(command: command, deadline: deadline, timeout: timeout, completion: completion)); lock.unlock()
    }
}

private func service(_ runner: FakeShortcutRunner) -> ShortcutService {
    ShortcutService(approvals: [ShortcutApproval(uuid: approvedUUID, label: "PhoneDeck M3.3 UUID Test")], runner: runner)
}
private func registry(_ service: ShortcutService) -> ActionRegistry {
    ActionRegistry(approvedAppPath: { _ in false }, launchApp: { _ in Issue.record("unexpected app launch") }, shortcuts: service)
}

@Suite struct ShortcutAuthorizationTests {
    @Test func typedUUIDAndFixedArguments() {
        for text in ["", "--help", "PhoneDeck M3.3 UUID Test", "/bin/sh", approvedUUID.rawValue + " --help", "{" + approvedUUID.rawValue + "}"] {
            #expect(ShortcutUUID(text) == nil)
        }
        #expect(ShortcutCommand.run(approvedUUID).arguments == ["run", approvedUUID.rawValue])
        #expect(ShortcutCommand.list.arguments == ["list", "--show-identifiers"])
        #expect(ShortcutUUID(approvedUUID.rawValue.lowercased()) == approvedUUID)
    }
    @Test func privateApprovalsFailClosed() throws {
        #expect(ShortcutApprovals.decode(Data()) == [])
        for text in [#"[{"uuid":"--help","label":"test"}]"#, #"[{"uuid":"11111111-1111-4111-8111-111111111111","label":"a","label":"b"}]"#,
                     #"[{"uuid":"11111111-1111-4111-8111-111111111111","label":"test","command":"sh"}]"#] {
            #expect(ShortcutApprovals.decode(Data(text.utf8)) == [])
        }
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        #expect(ShortcutApprovals.load(directory: directory).isEmpty)
        let path = directory.appendingPathComponent(ShortcutApprovals.filename).path
        let json = #"[{"uuid":"11111111-1111-4111-8111-111111111111","label":"PhoneDeck M3.3 UUID Test"}]"#
        try writeText(json, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(ShortcutApprovals.load(directory: directory).count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(ShortcutApprovals.load(directory: directory).isEmpty)
        try FileManager.default.removeItem(atPath: path)
        let source = directory.appendingPathComponent("source").path
        try writeText(json, to: source)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: source)
        #expect(ShortcutApprovals.load(directory: directory).isEmpty)
        #expect(ShortcutApprovals.decode(Data(("[" + json.dropFirst().dropLast() + "," + json.dropFirst().dropLast() + "]").utf8)).isEmpty)
    }
    @Test func authorizationAvailabilityAndOneRunNoRetry() {
        let runner = FakeShortcutRunner(), s = service(FakeShortcutRunner())
        #expect(registry(s).dispatch(.shortcutRun, parameters: .appPath("/tmp/a"), runID: "x") == .invalidParameters)
        let live = service(runner), r = registry(live)
        #expect(r.dispatch(.shortcutRun, parameters: .shortcutUUID(deniedUUID), runID: "denied") == .notAuthorized)
        #expect(runner.calls.isEmpty)
        #expect(r.dispatch(.shortcutRun, parameters: .shortcutUUID(approvedUUID), runID: "first") == .dispatched)
        #expect(runner.calls.map(\.command) == [.list])
        #expect(runner.calls[0].deadline == 5)
        #expect(live.status("first") == "running")
        #expect(r.dispatch(.shortcutRun, parameters: .shortcutUUID(approvedUUID), runID: "second") == .busy)
        runner.calls[0].completion(.completed(listing))
        #expect(runner.calls.map(\.command) == [.list, .run(approvedUUID)])
        #expect(runner.calls[1].deadline == 30)
        #expect(live.catalog()[0]["availability"] as? String == "available")
        runner.calls[1].completion(.completed(Data("test output".utf8)))
        #expect(live.status("first") == "completed")
        #expect(live.status("second") == nil)
        #expect(runner.calls.count == 2)
        #expect(r.dispatch(.shortcutRun, parameters: .shortcutUUID(approvedUUID), runID: "third") == .dispatched)
        #expect(runner.calls.last?.command == .list) // current membership rechecked every run
        runner.calls[2].completion(.completed(Data()))
        #expect(live.status("third") == "unavailable")
        #expect(runner.calls.count == 3)
    }
    @Test(arguments: [ShortcutProcessResult.failed, .timedOut, .completed(Data("invalid".utf8))])
    func unavailableCatalogNeverExecutes(_ result: ShortcutProcessResult) {
        let runner = FakeShortcutRunner()
        let live = service(runner)
        #expect(live.start(approvedUUID, runID: "run") == .dispatched)
        runner.calls[0].completion(result)
        #expect(live.status("run") == "unavailable")
        #expect(runner.calls.count == 1)
    }
    @Test(arguments: [ShortcutProcessResult.failed, .timedOut])
    func failureAndTimeoutNeverRetryAndTimeoutHoldsSlotUntilCleanup(_ result: ShortcutProcessResult) {
        let runner = FakeShortcutRunner()
        let s = service(runner)
        #expect(s.start(approvedUUID, runID: "run") == .dispatched)
        runner.calls[0].completion(.completed(listing))
        if result == .timedOut { runner.calls[1].timeout() }
        #expect(s.status("run") == (result == .timedOut ? "timed-out" : "running"))
        #expect(s.start(approvedUUID, runID: "busy") == .busy)
        #expect(runner.calls.count == 2)
        runner.calls[1].completion(result)
        #expect(s.status("run") == (result == .timedOut ? "timed-out" : "failed"))
        #expect(runner.calls.count == 2)
        #expect(s.start(approvedUUID, runID: "next") == .dispatched)
    }
    @Test func concurrentStartsHaveOneWinner() {
        let runner = FakeShortcutRunner(), s = service(runner), group = DispatchGroup(), lock = NSLock()
        var outcomes: [ActionOutcome] = []
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                let outcome = s.start(approvedUUID, runID: "run-\(i)")
                lock.lock(); outcomes.append(outcome); lock.unlock(); group.leave()
            }
        }
        group.wait()
        #expect(outcomes.filter { $0 == .dispatched }.count == 1)
        #expect(outcomes.filter { $0 == .busy }.count == 19)
        #expect(runner.calls.count == 1)
    }
}

private final class FakeChild: ShortcutChild {
    let lock = NSLock()
    var running = true, cleaned = false, terminations = 0, kills = 0
    var failLaunch = false
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var succeeded: Bool { true }
    func launch() throws { if failLaunch { throw NSError(domain: "test", code: 1) } }
    func drain(maximum: Int) -> Data { Data(repeating: 1, count: maximum) }
    func terminate() { lock.lock(); terminations += 1; lock.unlock() }
    func forceKill() { lock.lock(); kills += 1; running = false; lock.unlock() }
    func cleanup() { lock.lock(); cleaned = true; lock.unlock() }
    func snapshot() -> (Bool, Int, Int) { lock.lock(); defer { lock.unlock() }; return (cleaned, terminations, kills) }
}

@Suite struct ShortcutLifetimeTests {
    @Test func timeoutEscalatesAndCleansBeforeCompletion() throws {
        let child = FakeChild(), lock = NSLock()
        var events: [String] = []
        let runner = BoundedShortcutRunner(child: { _ in child })
        runner.start(.run(approvedUUID), deadline: 0.02, timeout: {
            lock.lock(); events.append("timeout"); lock.unlock()
        }, completion: { result in
            #expect(result == .timedOut)
            #expect(child.snapshot().0)
            lock.lock(); events.append("completion"); lock.unlock()
        })
        #expect(resourceEventually { child.snapshot().1 == 1 })
        #expect(!child.snapshot().0)
        #expect(resourceEventually { lock.lock(); defer { lock.unlock() }; return events.count == 2 })
        #expect(child.snapshot().2 == 1)
        #expect(events == ["timeout", "completion"])
    }
    @Test func boundedOutputAndLaunchFailureCleanup() {
        let child = FakeChild(), lock = NSLock()
        child.running = false
        var result: ShortcutProcessResult?
        BoundedShortcutRunner(child: { _ in child }).start(.list, deadline: 1, timeout: { Issue.record("unexpected timeout") }) { value in
            lock.lock(); result = value; lock.unlock()
        }
        #expect(resourceEventually { lock.lock(); defer { lock.unlock() }; return result != nil })
        #expect(result == .completed(Data(repeating: 1, count: BoundedShortcutRunner.maximumOutput)))
        #expect(child.snapshot().0)
        let failure = FakeChild(); failure.failLaunch = true
        var failed = false
        BoundedShortcutRunner(child: { _ in failure }).start(.list, deadline: 1, timeout: {}) { value in
            #expect(value == .failed)
            lock.lock(); failed = true; lock.unlock()
        }
        #expect(resourceEventually { lock.lock(); defer { lock.unlock() }; return failed })
        #expect(failure.snapshot().0)
    }
}

@Suite(.serialized) struct ShortcutHTTPTests {
    @Test func authenticatedBoundedAsyncRunAndStatus() throws {
        let runner = FakeShortcutRunner(), s = service(runner), r = registry(s)
        let server = try HTTPServer(port: 0, queue: DispatchQueue(label: "shortcut-route-test"), budget: HTTPConnectionBudget())
        server.start(admission: { DeckRoute.admit($0, token: "test-token") }) { req, conn in
            ShortcutRoute.handle(req, registry: r, service: s, on: conn)
        }
        defer { server.stop() }
        try #require(resourceEventually { (server.port?.rawValue ?? 0) > 0 })
        let port = try #require(server.port)
        func send(_ method: String, _ target: String, _ body: String = "", length: Int? = nil) throws -> String {
            let client = ResourceTestClient(port: port)
            defer { client.cancel() }
            client.send("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(length ?? body.utf8.count)\r\n\r\n" + body)
            try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
            return client.text
        }
        for target in ["/shortcut", "/shortcut?k=wrong"] {
            #expect(try send("POST", target, "uuid=\(approvedUUID.rawValue)").contains("403 Forbidden"))
            #expect(try send("GET", target + (target.contains("?") ? "&" : "?") + "id=x").contains("403 Forbidden"))
        }
        #expect(try send("POST", "/shortcut?k=test-token", length: 1025).contains("413 Content Too Large"))
        #expect(try send("PUT", "/shortcut?k=test-token").contains("405 Method Not Allowed"))
        #expect(try send("POST", "/shortcut?k=test-token", "uuid=--help").contains("400 Bad Request"))
        #expect(try send("POST", "/shortcut?k=test-token", "uuid=\(deniedUUID.rawValue)").contains("403 Forbidden"))
        #expect(runner.calls.isEmpty)
        let response = try send("POST", "/shortcut?k=test-token", "uuid=\(approvedUUID.rawValue)&command=rm&args=--help")
        #expect(response.contains("200 OK"))
        let body = try #require(response.components(separatedBy: "\r\n\r\n").last)
        let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        let id = try #require(json["id"])
        #expect(json["status"] == "running")
        #expect(try send("POST", "/shortcut?k=test-token", "uuid=\(approvedUUID.rawValue)").contains("409 Conflict"))
        // Status remains responsive while the fake process has not completed.
        #expect(try send("GET", "/shortcut?k=test-token&id=\(id)").contains("running"))
        runner.calls[0].completion(.completed(listing))
        runner.calls[1].completion(.completed(Data()))
        #expect(try send("GET", "/shortcut?k=test-token&id=\(id)").contains("completed"))
        #expect(runner.calls.map(\.command) == [.list, .run(approvedUUID)])
    }
}
