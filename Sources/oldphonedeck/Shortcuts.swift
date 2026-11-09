import Foundation
import Darwin

/// UUID syntax is narrower than Foundation's permissive parsers and can never express a CLI option.
struct ShortcutUUID: Hashable {
    let rawValue: String
    init?(_ text: String) {
        guard text.utf8.count == 36, let value = UUID(uuidString: text),
              value.uuidString.lowercased() == text.lowercased() else { return nil }
        rawValue = value.uuidString
    }
}

struct ShortcutApproval: Equatable {
    let uuid: ShortcutUUID
    let label: String
}

enum ShortcutApprovals {
    static let filename = "shortcut-approvals.json"

    /// Private operator file, never populated by discovery or HTTP. Invalid/missing = no approvals.
    static func load(directory: URL) -> [ShortcutApproval] {
        let fd = open(directory.appendingPathComponent(filename).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size <= 16 * 1024 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024 + 1)
        let count = read(fd, &buffer, buffer.count)
        guard count >= 0, count == info.st_size, count <= 16 * 1024 else { return [] }
        return decode(Data(buffer.prefix(count)))
    }

    static func decode(_ data: Data) -> [ShortcutApproval] {
        guard data.count <= 16 * 1024 else { return [] }
        var scanner = ConfigurationJSONScanner(data)
        guard case .success(.array(let entries)) = scanner.scanDocument(), entries.count <= 16 else { return [] }
        var result: [ShortcutApproval] = [], seen = Set<ShortcutUUID>()
        for entry in entries {
            guard let members = entry.objectMembers, members.count == 2,
                  members.allSatisfy({ $0.0 == "uuid" || $0.0 == "label" }),
                  case .string(let text)? = entry.member("uuid"), let uuid = ShortcutUUID(text),
                  case .string(let label)? = entry.member("label"), ControlPresentation.isValidTitle(label),
                  seen.insert(uuid).inserted else { return [] }
            result.append(ShortcutApproval(uuid: uuid, label: label))
        }
        return result
    }
}

/// The only command forms accepted by the process runner. Neither contains a user-selected option.
enum ShortcutCommand: Equatable {
    case list
    case run(ShortcutUUID)
    var arguments: [String] {
        switch self {
        case .list: return ["list", "--show-identifiers"]
        case .run(let uuid): return ["run", uuid.rawValue]
        }
    }
}

enum ShortcutProcessResult: Equatable {
    case completed(Data)
    case failed
    case timedOut
}

protocol ShortcutRunning {
    /// timeout is published at the deadline; completion follows only after process cleanup.
    func start(_ command: ShortcutCommand, deadline: TimeInterval,
               timeout: @escaping () -> Void, completion: @escaping (ShortcutProcessResult) -> Void)
}

/// A narrow process seam lets lifetime tests inject a child without ever invoking Apple Shortcuts.
protocol ShortcutChild: AnyObject {
    func launch() throws
    var isRunning: Bool { get }
    var succeeded: Bool { get }
    func drain(maximum: Int) -> Data
    func terminate()
    func forceKill()
    func cleanup()
}

final class FoundationShortcutChild: ShortcutChild {
    private let process = Process()
    private let output = Pipe(), errors = Pipe()
    private var launched = false
    init(_ command: ShortcutCommand) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        for pipe in [output, errors] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }
    func launch() throws {
        try process.run()
        launched = true
        // Only the child owns the writing ends now. Reads always use bounded, nonblocking chunks.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }
    var isRunning: Bool { launched && process.isRunning }
    var succeeded: Bool { launched && process.terminationReason == .exit && process.terminationStatus == 0 }
    func drain(maximum: Int) -> Data {
        var retained = Data()
        // Bound work per tick as well as retained output. Stderr is drained but never published.
        for (index, pipe) in [output, errors].enumerated() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { break }
                if index == 0 { retained.append(contentsOf: buffer.prefix(min(count, max(0, maximum - retained.count)))) }
            }
        }
        return retained
    }
    func terminate() { if isRunning { process.terminate() } }
    func forceKill() { if isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
    func cleanup() {
        for pipe in [output, errors] {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}

final class BoundedShortcutRunner: ShortcutRunning {
    static let maximumOutput = 64 * 1024
    private let queue = DispatchQueue(label: "phonedeck.shortcut-process")
    private let child: (ShortcutCommand) -> ShortcutChild
    init(child: @escaping (ShortcutCommand) -> ShortcutChild = { FoundationShortcutChild($0) }) {
        self.child = child
    }
    func start(_ command: ShortcutCommand, deadline: TimeInterval,
               timeout: @escaping () -> Void, completion: @escaping (ShortcutProcessResult) -> Void) {
        queue.async {
            let child = self.child(command)
            do { try child.launch() } catch {
                child.cleanup(); completion(.failed); return
            }
            let started = DispatchTime.now().uptimeNanoseconds
            var timedOut = false, killed = false, output = Data()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler {
                let chunk = child.drain(maximum: max(0, Self.maximumOutput - output.count))
                output.append(chunk.prefix(max(0, Self.maximumOutput - output.count)))
                if !child.isRunning {
                    timer.cancel()
                    timer.setEventHandler {}
                    let success = child.succeeded
                    child.cleanup()
                    completion(timedOut ? .timedOut : (success ? .completed(output) : .failed))
                    return
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                if !timedOut && elapsed >= deadline {
                    timedOut = true
                    timeout() // side effects are unknown, even if later cleanup produces exit 0
                    child.terminate()
                }
                if timedOut && !killed && elapsed >= deadline + 0.5 {
                    killed = true
                    child.forceKill()
                }
            }
            timer.resume()
        }
    }
}

/// One shared slot covers fresh availability lookup and execution. No queue and no retries.
/// State is bounded to the latest run. A timeout does not release the slot until the CLI exits.
final class ShortcutService {
    private let lock = NSLock()
    private let approvals: [ShortcutApproval]
    private let runner: ShortcutRunning
    private var active = false
    private var latest: (id: String, status: String)?
    private var available: Set<ShortcutUUID>?
    init(approvals: [ShortcutApproval], runner: ShortcutRunning) {
        self.approvals = approvals
        self.runner = runner
    }
    func catalog() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return approvals.map { approval in
            ["uuid": approval.uuid.rawValue, "label": approval.label,
             "availability": available.map { $0.contains(approval.uuid) ? "available" : "unavailable" } ?? "unchecked"]
        }
    }
    func status(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return latest?.id == id ? latest?.status : nil
    }
    func start(_ uuid: ShortcutUUID, runID: String) -> ActionOutcome {
        lock.lock()
        guard approvals.contains(where: { $0.uuid == uuid }) else { lock.unlock(); return .notAuthorized }
        guard !active else { lock.unlock(); return .busy }
        active = true
        latest = (runID, "running")
        lock.unlock()
        // Read-only discovery happens off the HTTP queue and is not itself an approval.
        runner.start(.list, deadline: 5, timeout: { self.mark(runID, "unavailable") }) { result in
            guard case .completed(let data) = result, let ids = Self.identifiers(data) else {
                self.finish(runID, "unavailable"); return
            }
            self.lock.lock(); self.available = ids; self.lock.unlock()
            guard ids.contains(uuid) else { self.finish(runID, "unavailable"); return }
            self.runner.start(.run(uuid), deadline: 30, timeout: { self.mark(runID, "timed-out") }) { result in
                switch result {
                case .completed: self.finish(runID, "completed")
                case .failed: self.finish(runID, "failed")
                case .timedOut: self.finish(runID, "timed-out")
                }
            }
        }
        return .dispatched
    }
    private func mark(_ id: String, _ status: String) {
        lock.lock(); defer { lock.unlock() }
        if latest?.id == id { latest?.status = status }
    }
    private func finish(_ id: String, _ status: String) {
        lock.lock(); defer { lock.unlock() }
        if latest?.id == id {
            if latest?.status != "timed-out" { latest?.status = status }
            active = false
        }
    }
    /// Apple's list output is NAME (UUID), one per line. Names are discarded and never executed.
    static func identifiers(_ data: Data) -> Set<ShortcutUUID>? {
        guard data.count < BoundedShortcutRunner.maximumOutput,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var result = Set<ShortcutUUID>()
        for line in text.split(separator: "\n") {
            guard line.hasSuffix(")"), line.count >= 39 else { return nil }
            let uuidStart = line.index(line.endIndex, offsetBy: -37)
            guard line[line.index(before: uuidStart)] == "(",
                  let uuid = ShortcutUUID(String(line[uuidStart..<line.index(before: line.endIndex)])) else { return nil }
            result.insert(uuid)
        }
        return result
    }
}

enum ShortcutRoute {
    static func handle(_ request: HTTPRequest, registry: ActionRegistry, service: ShortcutService,
                       on connection: HTTPConnection) {
        if request.method == "GET" {
            guard let id = request.params["id"], UUID(uuidString: id) != nil, let status = service.status(id) else {
                return connection.respond(404, text: "unknown-run")
            }
            connection.respondJSON(["id": id, "status": status]); return
        }
        guard request.method == "POST", let uuid = ShortcutUUID(request.params["uuid"] ?? "") else {
            return connection.respond(400, text: "invalid-uuid")
        }
        let id = UUID().uuidString
        switch registry.dispatch(.shortcutRun, parameters: .shortcutUUID(uuid), runID: id) {
        case .dispatched: connection.respondJSON(["id": id, "status": "running"])
        case .busy: connection.respond(409, text: "busy")
        default: connection.respond(403, text: "not-authorized")
        }
    }
}
