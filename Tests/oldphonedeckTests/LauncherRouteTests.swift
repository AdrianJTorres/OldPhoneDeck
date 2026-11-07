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

/// A minimal HTTPConnection recorder for testing the handler without a real network connection.
final class MockHTTPConnection {
    var status: Int?
    var body: String?
    var json: [String: Any]?

    func respond(_ status: Int, text: String) {
        self.status = status
        self.body = text
    }

    func respondJSON(_ obj: Any) {
        self.status = 200
        self.json = obj as? [String: Any]
    }
}

@Suite struct LauncherRouteHandlerTests {
    @Test func getReturnsSelectedAndAll() throws {
        let request = HTTPRequest(method: "GET", path: "/launcher", query: [:], headers: [:], body: Data())
        let mock = MockHTTPConnection()

        LauncherRoute.handle(
            request,
            loader: { ["/Applications/Safari.app"] },
            saver: { _ in throw NSError(domain: "test", code: 1) },
            on: mock
        )

        #expect(mock.status == 200)
        #expect(mock.json?["selected"] as? [String] == ["/Applications/Safari.app"])
        #expect(mock.json?["all"] != nil)
    }

    @Test func getWithNilSelectedReturnsNull() throws {
        let request = HTTPRequest(method: "GET", path: "/launcher", query: [:], headers: [:], body: Data())
        let mock = MockHTTPConnection()

        LauncherRoute.handle(
            request,
            loader: { nil },
            saver: { _ in throw NSError(domain: "test", code: 1) },
            on: mock
        )

        #expect(mock.status == 200)
        #expect(mock.json?["selected"] is NSNull)
    }

    @Test func postWithValidPathsReturnsSavedCount() throws {
        let body = "n=2&paths=/Applications/Safari.app\n/Applications/Xcode.app"
        let request = HTTPRequest(
            method: "POST",
            path: "/launcher",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        let mock = MockHTTPConnection()
        var savedPaths: [String]?
        LauncherRoute.handle(
            request,
            loader: { savedPaths ?? [] },
            saver: { paths in savedPaths = paths; return paths.count },
            on: mock
        )

        #expect(mock.status == 200)
        #expect(mock.json?["saved"] as? Int == 2)
        #expect(savedPaths == ["/Applications/Safari.app", "/Applications/Xcode.app"])
    }

    @Test func postWithInvalidCountReturns400() throws {
        let body = "n=8&paths=/Applications/Safari.app"
        let request = HTTPRequest(
            method: "POST",
            path: "/launcher",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        let mock = MockHTTPConnection()

        LauncherRoute.handle(
            request,
            loader: { [] },
            saver: { _ in 0 },
            on: mock
        )

        #expect(mock.status == 400)
        #expect(mock.body == "invalid-count")
    }

    @Test func postWithCountMismatchReturns400() throws {
        let body = "n=2&paths=/Applications/Safari.app"
        let request = HTTPRequest(
            method: "POST",
            path: "/launcher",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        let mock = MockHTTPConnection()

        LauncherRoute.handle(
            request,
            loader: { [] },
            saver: { _ in 0 },
            on: mock
        )

        #expect(mock.status == 400)
        #expect(mock.body == "count-mismatch")
    }

    @Test func postWithEntryTooLongReturns400() throws {
        let longPath = String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes + 1)
        let body = "n=1&paths=\(longPath)"
        let request = HTTPRequest(
            method: "POST",
            path: "/launcher",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        let mock = MockHTTPConnection()

        LauncherRoute.handle(
            request,
            loader: { [] },
            saver: { _ in 0 },
            on: mock
        )

        #expect(mock.status == 400)
        #expect(mock.body == "entry-too-long")
    }

    @Test func postWithSaveErrorReturns500() throws {
        let body = "n=1&paths=/Applications/Safari.app"
        let request = HTTPRequest(
            method: "POST",
            path: "/launcher",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        let mock = MockHTTPConnection()

        LauncherRoute.handle(
            request,
            loader: { [] },
            saver: { _ in throw NSError(domain: "test", code: 1) },
            on: mock
        )

        #expect(mock.status == 500)
        #expect(mock.body == "write-failed")
    }

    @Test func postWithLegacyBranchPreservesEmptyPaths() throws {
        // No `n` parameter: legacy branch, empty subsequences omitted.
        let body = "paths=/Applications/Safari.app\n\n/Applications/Xcode.app"
        let request = HTTPRequest(
            method: "POST",
            path: "/launcher",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        let mock = MockHTTPConnection()
        var savedPaths: [String]?
        LauncherRoute.handle(
            request,
            loader: { savedPaths ?? [] },
            saver: { paths in savedPaths = paths; return paths.count },
            on: mock
        )

        #expect(mock.status == 200)
        // Legacy branch omits empty subsequences, so the middle empty is dropped.
        #expect(savedPaths == ["/Applications/Safari.app", "/Applications/Xcode.app"])
    }
}
