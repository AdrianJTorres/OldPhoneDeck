import Foundation

struct HTTPFailure: Error, Equatable {
    let status: Int
    let message: String
}

/// Parsed, bounded headers only. Authentication never consults a request body.
struct HTTPRequestHead {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let contentLength: Int?
}

typealias HTTPAdmission = (HTTPRequestHead) -> Result<Int, HTTPFailure>

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Query string merged with an x-www-form-urlencoded body; never used for authentication.
    var params: [String: String] {
        var p = query
        if headers["content-type"]?.hasPrefix("application/x-www-form-urlencoded") == true,
           let s = String(data: body, encoding: .utf8) {
            for (k, v) in HTTPRequest.parseForm(s) { p[k] = v }
        }
        return p
    }

    static func parseForm(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let k = kv.first { out[k] = kv.count > 1 ? kv[1] : "" }
        }
        return out
    }
}

/// One request per connection. Only admitted body bytes are retained.
struct HTTPRequestParser {
    enum Phase { case headers, body, complete, failed }
    static let maxLine = 4 * 1024
    static let maxHeaders = 16 * 1024
    static let maxFields = 64

    private(set) var phase = Phase.headers
    private var header = Data()
    private var body = Data()
    private var head: HTTPRequestHead?
    private var lineLength = 0
    private var lineNumber = 0
    private var awaitingLF = false

    var bufferedBodyBytes: Int { body.count }
    var maximumReceiveLength: Int {
        switch phase {
        case .headers: return min(4 * 1024, Self.maxHeaders - header.count)
        case .body: return min(16 * 1024, (head?.contentLength ?? 0) - body.count)
        case .complete, .failed: return 0
        }
    }

    mutating func receive(_ data: Data, admission: HTTPAdmission) throws -> HTTPRequest? {
        guard phase == .headers || phase == .body else { return nil }
        do {
            var offset = data.startIndex
            if phase == .headers {
                while offset < data.endIndex {
                    let byte = data[offset]
                    offset += 1
                    guard header.count < Self.maxHeaders else { throw failure(431, "headers too large") }
                    header.append(byte)
                    if awaitingLF {
                        guard byte == 10 else { throw failure(400, "invalid line ending") }
                        awaitingLF = false
                        if lineNumber > 0 && lineLength == 0 {
                            let parsed = try parseHead()
                            let limit = try admission(parsed).get()
                            guard limit >= 0 else { throw failure(500, "invalid admission limit") }
                            if limit > 0 && parsed.contentLength == nil {
                                throw failure(411, "content length required")
                            }
                            guard (parsed.contentLength ?? 0) <= limit else { throw failure(413, "body too large") }
                            head = parsed
                            header = Data()
                            phase = .body
                            break
                        }
                        lineNumber += 1
                        guard lineNumber <= Self.maxFields + 1 else { throw failure(431, "too many headers") }
                        lineLength = 0
                    } else if byte == 13 {
                        awaitingLF = true
                    } else {
                        guard byte != 10 else { throw failure(400, "invalid line ending") }
                        lineLength += 1
                        guard lineLength <= Self.maxLine else {
                            throw failure(lineNumber == 0 ? 414 : 431, "line too long")
                        }
                    }
                }
                if phase == .headers {
                    guard header.count < Self.maxHeaders else { throw failure(431, "headers too large") }
                    return nil
                }
            }
            guard let head else { throw failure(500, "missing request headers") }
            let length = head.contentLength ?? 0
            guard data.endIndex - offset <= length - body.count else { throw failure(400, "unexpected request bytes") }
            body.append(contentsOf: data[offset...])
            guard body.count == length else { return nil }
            phase = .complete
            let request = HTTPRequest(method: head.method, path: head.path, query: head.query,
                                      headers: head.headers, body: body)
            body = Data()
            return request
        } catch {
            phase = .failed
            header = Data()
            body = Data()
            head = nil
            throw error
        }
    }

    private func failure(_ status: Int, _ message: String) -> HTTPFailure {
        HTTPFailure(status: status, message: message)
    }

    private func parseHead() throws -> HTTPRequestHead {
        guard let text = String(data: header, encoding: .utf8) else { throw failure(400, "invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].utf8.allSatisfy(Self.isToken),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw failure(400, "invalid request line")
        }
        let target = String(parts[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !target.contains("#"),
              Self.validPercentEncoding(target),
              let comps = URLComponents(string: "http://h" + target),
              let path = comps.percentEncodedPath.removingPercentEncoding else {
            throw failure(400, "invalid request target")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].utf8.allSatisfy(Self.isToken) else { throw failure(400, "invalid header field") }
            let name = line[..<colon].lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                throw failure(400, "invalid header value")
            }
            if headers[name] != nil && ["content-length", "content-type", "host"].contains(name) {
                throw failure(400, "duplicate header field")
            }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        guard headers["transfer-encoding"] == nil else { throw failure(400, "transfer encoding unsupported") }
        guard headers["expect"] == nil else { throw failure(417, "expectation unsupported") }
        var length: Int?
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(value) else {
                throw failure(400, "invalid content length")
            }
            length = n
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if item.name == "k" && query["k"] != nil { throw failure(400, "duplicate token parameter") }
            query[item.name] = item.value ?? ""
        }
        return HTTPRequestHead(method: String(parts[0]), path: path, query: query,
                               headers: headers, contentLength: length)
    }

    private static func isToken(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
            || "!#$%&'*+-.^_`|~".utf8.contains(b)
    }

    private static func validPercentEncoding(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b) }
        while i < bytes.count {
            if bytes[i] == 37 {
                guard i + 2 < bytes.count, hex(bytes[i + 1]), hex(bytes[i + 2]) else { return false }
                i += 3
            } else { i += 1 }
        }
        return true
    }
}

/// Application route metadata shared by header admission and the route switch.
enum DeckRoute: CaseIterable {
    case page, index, profile, info, stats, speedtest, media, artwork
    case launcherRead, launcherSave, icon, launch, claude, cameraStream, cameraFrame

    var path: String {
        switch self {
        case .page: return "/"
        case .index: return "/index.html"
        case .profile: return "/oldphonedeck.mobileconfig"
        case .info: return "/info"
        case .stats: return "/stats"
        case .speedtest: return "/speedtest"
        case .media: return "/media"
        case .artwork: return "/artwork"
        case .launcherRead, .launcherSave: return "/launcher"
        case .icon: return "/icon"
        case .launch: return "/launch"
        case .claude: return "/claude"
        case .cameraStream: return "/camera.mjpg"
        case .cameraFrame: return "/camera.jpg"
        }
    }

    var method: String {
        switch self {
        case .speedtest, .media, .launcherSave, .launch, .claude: return "POST"
        default: return "GET"
        }
    }

    var bodyLimit: Int {
        switch self {
        case .media: return 1024
        case .launch: return 16 * 1024
        case .claude, .launcherSave: return 64 * 1024
        default: return 0
        }
    }

    var isPublic: Bool { self == .page || self == .index || self == .profile }

    static func match(method: String, path: String) -> DeckRoute? {
        allCases.first { $0.method == method && $0.path == path }
    }

    static func admit(_ head: HTTPRequestHead, token: String) -> Result<Int, HTTPFailure> {
        let candidates = allCases.filter { $0.path == head.path }
        guard !candidates.isEmpty else { return .failure(HTTPFailure(status: 404, message: "not found")) }
        if !candidates[0].isPublic && head.query["k"] != token {
            return .failure(HTTPFailure(status: 403, message: "bad token"))
        }
        guard let route = candidates.first(where: { $0.method == head.method }) else {
            return .failure(HTTPFailure(status: 405, message: "method not allowed"))
        }
        return .success(route.bodyLimit)
    }

    static func validateParameters(_ request: HTTPRequest) -> HTTPFailure? {
        let p = request.params
        if request.method == "POST", request.path == "/launcher" {
            // Revision and state checks stay under the store's lock, in refusal order.
            if case .failure(let failure) = LauncherRoute.parseWidgets(p) { return failure }
            return LauncherRoute.parseSelection(p).failure
        }
        if request.path == "/launch", (p["path"] ?? "").utf8.count > 4096 {
            return HTTPFailure(status: 413, message: "app path too long")
        }
        if request.path == "/claude" {
            if (p["text"] ?? "").utf8.count > 16 * 1024 {
                return HTTPFailure(status: 413, message: "text too long")
            }
            if let send = p["send"], send != "0" && send != "1" {
                return HTTPFailure(status: 400, message: "invalid send value")
            }
        }
        return nil
    }
}
