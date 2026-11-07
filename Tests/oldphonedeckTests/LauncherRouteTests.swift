import Foundation
import Testing
@testable import oldphonedeck

// MARK: - parseSelection

@Suite struct LauncherRouteParseSelectionTests {
    @Test func legacyBranchSplitsOnNewlineOmittingEmpty() throws {
        // No `n` parameter: pre-M2.5 client behavior, unchanged from main.swift:147.
        let result = LauncherRoute.parseSelection(["paths": "a\n\nb"])
        #expect(result == .success(["a", "b"]))
    }

    @Test func legacyBranchWithEmptyPathsYieldsEmptyArray() throws {
        let result = LauncherRoute.parseSelection(["paths": ""])
        #expect(result == .success([]))
    }

    @Test func legacyBranchWithAbsentPathsYieldsEmptyArray() throws {
        let result = LauncherRoute.parseSelection([:])
        #expect(result == .success([]))
    }

    @Test func zeroControlsWithEmptyPathsYieldsEmptyArray() throws {
        let result = LauncherRoute.parseSelection(["n": "0", "paths": ""])
        #expect(result == .success([]))
    }

    @Test func zeroControlsWithAbsentPathsYieldsEmptyArray() throws {
        let result = LauncherRoute.parseSelection(["n": "0"])
        #expect(result == .success([]))
    }

    @Test func zeroControlsWithNonEmptyPathsIsCountMismatch() throws {
        let result = LauncherRoute.parseSelection(["n": "0", "paths": "/A.app"])
        #expect(result == .countMismatch)
    }

    @Test func oneControlWithEmptyPathsYieldsOneEmptyPath() throws {
        // n=1 with empty paths is the one-empty-path case, not zero paths.
        let result = LauncherRoute.parseSelection(["n": "1", "paths": ""])
        #expect(result == .success([""]))
    }

    @Test func twoControlsWithNewlineYieldsTwoEmptyPaths() throws {
        let result = LauncherRoute.parseSelection(["n": "2", "paths": "\n"])
        #expect(result == .success(["", ""]))
    }

    @Test func trailingEmptyPreserved() throws {
        let result = LauncherRoute.parseSelection(["n": "2", "paths": "/A.app\n"])
        #expect(result == .success(["/A.app", ""]))
    }

    @Test func leadingEmptyPreserved() throws {
        let result = LauncherRoute.parseSelection(["n": "2", "paths": "\n/A.app"])
        #expect(result == .success(["", "/A.app"]))
    }

    @Test func duplicatesPreserved() throws {
        let result = LauncherRoute.parseSelection(["n": "2", "paths": "/A.app\n/A.app"])
        #expect(result == .success(["/A.app", "/A.app"]))
    }

    @Test func countMismatchWhenPathsExceedsN() throws {
        let result = LauncherRoute.parseSelection(["n": "1", "paths": "/A.app\n/B.app"])
        #expect(result == .countMismatch)
    }

    @Test func countMismatchWhenNExceedsPaths() throws {
        let result = LauncherRoute.parseSelection(["n": "2", "paths": "/A.app"])
        #expect(result == .countMismatch)
    }

    @Test func invalidCountRejectsNegative() throws {
        let result = LauncherRoute.parseSelection(["n": "-1", "paths": ""])
        #expect(result == .invalidCount)
    }

    @Test func invalidCountRejectsTooLarge() throws {
        let result = LauncherRoute.parseSelection(["n": "8", "paths": ""])
        #expect(result == .invalidCount)
    }

    @Test func invalidCountRejectsLeadingZero() throws {
        let result = LauncherRoute.parseSelection(["n": "01", "paths": ""])
        #expect(result == .invalidCount)
    }

    @Test func invalidCountRejectsEmpty() throws {
        let result = LauncherRoute.parseSelection(["n": "", "paths": ""])
        #expect(result == .invalidCount)
    }

    @Test func invalidCountRejectsNonNumeric() throws {
        let result = LauncherRoute.parseSelection(["n": "abc", "paths": ""])
        #expect(result == .invalidCount)
    }

    @Test func entryTooLongRejectsOverLimit() throws {
        let longPath = String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes + 1)
        let result = LauncherRoute.parseSelection(["n": "1", "paths": longPath])
        #expect(result == .entryTooLong)
    }

    @Test func entryAtLimitAccepted() throws {
        let limitPath = String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes)
        let result = LauncherRoute.parseSelection(["n": "1", "paths": limitPath])
        #expect(result == .success([limitPath]))
    }

    @Test func sevenControlsAccepted() throws {
        let paths = (1...7).map { "/Applications/App\($0).app" }
        let result = LauncherRoute.parseSelection(["n": "7", "paths": paths.joined(separator: "\n")])
        #expect(result == .success(paths))
    }
}

// MARK: - Handler integration

import Network

@Suite(.serialized)
struct LauncherRouteHandlerTests {
    private let token = "launcher-test-token"

    private func startServer(selected: [String]?,
                             saver: @escaping ([String]) throws -> Int,
                             catalog: @escaping () -> [[String: String]] = { [] }) throws -> (HTTPServer, NWEndpoint.Port) {
        let server = try HTTPServer(port: 0, queue: DispatchQueue(label: "launcher-route-test"),
                                    budget: HTTPConnectionBudget())
        server.start(admission: { DeckRoute.admit($0, token: self.token) }) { req, conn in
            guard let route = DeckRoute.match(method: req.method, path: req.path), route == .launcherRead else {
                return conn.respond(404, text: "not found")
            }
            LauncherRoute.handle(req, loader: { selected }, saver: saver, on: conn, catalog: catalog)
        }
        try #require(resourceEventually { (server.port?.rawValue ?? 0) > 0 })
        return (server, try #require(server.port))
    }

    private func get(port: NWEndpoint.Port) throws -> String {
        let client = ResourceTestClient(port: port)
        defer { client.cancel() }
        client.send("GET /launcher?k=\(token) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    private func post(port: NWEndpoint.Port, body: String) throws -> String {
        let client = ResourceTestClient(port: port)
        defer { client.cancel() }
        client.send("POST /launcher?k=\(token) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    + body)
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    @Test func getReturnsSelectedAndAll() throws {
        let catalog = { [["name": "Safari", "path": "/Applications/Safari.app"]] }
        let (server, port) = try startServer(selected: ["/Applications/Safari.app"], saver: { _ in 0 }, catalog: catalog)
        defer { server.stop() }

        let response = try get(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("\"selected\":[\"\/Applications\/Safari.app\"]"))
        #expect(response.contains("\"all\":[{\"name\":\"Safari\",\"path\":\"\/Applications\/Safari.app\"}]"))
    }

    @Test func getWithNilSelectedReturnsNull() throws {
        let catalog = { [["name": "Safari", "path": "/Applications/Safari.app"]] }
        let (server, port) = try startServer(selected: nil, saver: { _ in 0 }, catalog: catalog)
        defer { server.stop() }

        let response = try get(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("\"selected\":null"))
    }

    @Test func postWithValidPathsReturnsSavedCount() throws {
        var savedPaths: [String]?
        let saver: ([String]) throws -> Int = { paths in savedPaths = paths; return paths.count }
        let (server, port) = try startServer(selected: [], saver: saver)
        defer { server.stop() }

        let body = "n=2&paths=/Applications/Safari.app\n/Applications/Xcode.app"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("\"saved\":2"))
        #expect(savedPaths == ["/Applications/Safari.app", "/Applications/Xcode.app"])
    }

    @Test func postWithInvalidCountReturns400() throws {
        let (server, port) = try startServer(selected: [], saver: { _ in 0 })
        defer { server.stop() }

        let body = "n=8&paths=/Applications/Safari.app"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(response.hasSuffix("\r\n\r\ninvalid-count"))
    }

    @Test func postWithCountMismatchReturns400() throws {
        let (server, port) = try startServer(selected: [], saver: { _ in 0 })
        defer { server.stop() }

        let body = "n=2&paths=/Applications/Safari.app"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(response.hasSuffix("\r\n\r\ncount-mismatch"))
    }

    @Test func postWithEntryTooLongReturns400() throws {
        let (server, port) = try startServer(selected: [], saver: { _ in 0 })
        defer { server.stop() }

        let longPath = String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes + 1)
        let body = "n=1&paths=\(longPath)"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(response.hasSuffix("\r\n\r\nentry-too-long"))
    }

    @Test func postWithSaveErrorReturns500() throws {
        let (server, port) = try startServer(selected: [], saver: { _ in throw NSError(domain: "test", code: 1) })
        defer { server.stop() }

        let body = "n=1&paths=/Applications/Safari.app"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 500 Internal Server Error\r\n"))
        #expect(response.hasSuffix("\r\n\r\nwrite-failed"))
    }

    @Test func postWithLegacyBranchPreservesEmptyPaths() throws {
        // No `n` parameter: legacy branch, empty subsequences omitted.
        var savedPaths: [String]?
        let saver: ([String]) throws -> Int = { paths in savedPaths = paths; return paths.count }
        let (server, port) = try startServer(selected: [], saver: saver)
        defer { server.stop() }

        let body = "paths=/Applications/Safari.app\n\n/Applications/Xcode.app"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        // Legacy branch omits empty subsequences, so the middle empty is dropped.
        #expect(savedPaths == ["/Applications/Safari.app", "/Applications/Xcode.app"])
    }
}
