import Foundation
import Network
import Testing
@testable import oldphonedeck

// MARK: - parseSelection

@Suite struct LauncherRouteParameterValidationTests {
    private func request(_ params: [String: String], method: String = "POST",
                         path: String = "/launcher") -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: params, headers: [:], body: Data())
    }

    @Test func sharedValidatorRejectsNoncanonicalOrOutOfRangeCounts() {
        for count in ["", "-1", "+1", "01", "8", "1.0", " 1", "１", String(repeating: "9", count: 100)] {
            #expect(DeckRoute.validateParameters(request(["n": count]))
                    == HTTPFailure(status: 400, message: "invalid-count"))
        }
    }

    @Test func sharedValidatorRejectsDisagreementWithoutPaddingOrTruncation() {
        for params in [["n": "0", "paths": "a"], ["n": "1", "paths": "a\nb"],
                       ["n": "2", "paths": "a"]] {
            #expect(DeckRoute.validateParameters(request(params))
                    == HTTPFailure(status: 400, message: "count-mismatch"))
        }
    }

    @Test func sharedValidatorUsesUTF8EntryBoundaries() {
        let path = String(repeating: "é", count: 2048)
        #expect(DeckRoute.validateParameters(request(["n": "1", "paths": path])) == nil)
        #expect(DeckRoute.validateParameters(request(["n": "1", "paths": path + "x"]))
                == HTTPFailure(status: 400, message: "entry-too-long"))
    }

    @Test func sharedValidatorPreservesEmptyAndLegacySelections() {
        for params in [[String: String](), ["paths": "a\n\nb"], ["n": "0"],
                       ["n": "1", "paths": ""], ["n": "2", "paths": "\n"]] {
            #expect(DeckRoute.validateParameters(request(params)) == nil)
        }
    }

    @Test func revisionRefusalsRemainTheStoresResponsibility() {
        #expect(DeckRoute.validateParameters(request(["n": "0"])) == nil)
        for expected in ["", "stale", "anything"] {
            #expect(DeckRoute.validateParameters(request(["n": "0", "expected": expected])) == nil)
        }
    }

    @Test func launcherSyntaxRulesApplyOnlyToLauncherPost() {
        #expect(DeckRoute.validateParameters(request(["n": "8"], method: "GET")) == nil)
        #expect(DeckRoute.validateParameters(request(["n": "8"], path: "/launch")) == nil)
    }
}

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

// MARK: - Wire integration through the production handler and a real ConfigurationStore
//
// M2.5 S3 (design §13, §14): every test runs the shipped `LauncherRoute.handle` behind production
// `DeckRoute.admit`/`match` over a loopback `HTTPServer(port: 0)`, against a `ConfigurationStore`
// on a temporary directory (`temporaryStoreDirectory`, the `TLSResourceTests` convention). The
// catalog is injected, so no test reaches `NSWorkspace`, and no test constructs a production
// `ActionRegistry()`. No test touches `~/.oldphonedeck`.

@Suite(.serialized)
struct LauncherRouteStoreWiringTests {
    private let token = "launcher-test-token"
    private let catalog = [["name": "Safari", "path": "/Applications/Safari.app"],
                           ["name": "Xcode", "path": "/Applications/Xcode.app"]]

    private func startServer(store: ConfigurationStore,
                             catalog: @escaping () -> [[String: String]] = { [] }) throws -> (HTTPServer, NWEndpoint.Port) {
        let server = try HTTPServer(port: 0, queue: DispatchQueue(label: "launcher-route-test"),
                                    budget: HTTPConnectionBudget())
        server.start(admission: { DeckRoute.admit($0, token: self.token) }) { req, conn in
            guard let route = DeckRoute.match(method: req.method, path: req.path),
                  route == .launcherRead || route == .launcherSave else {
                return conn.respond(404, text: "not found")
            }
            LauncherRoute.handle(req, store: store, on: conn, catalog: catalog)
        }
        try #require(resourceEventually { (server.port?.rawValue ?? 0) > 0 })
        return (server, try #require(server.port))
    }

    private func get(port: NWEndpoint.Port, target: String? = nil) throws -> String {
        let client = ResourceTestClient(port: port)
        defer { client.cancel() }
        let requestTarget = target ?? "/launcher?k=\(token)"
        client.send("GET \(requestTarget) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    private func post(port: NWEndpoint.Port, target: String? = nil, body: String) throws -> String {
        let client = ResourceTestClient(port: port)
        defer { client.cancel() }
        let requestTarget = target ?? "/launcher?k=\(token)"
        client.send("POST \(requestTarget) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    + body)
        try #require(resourceEventually { client.isClosed && !client.text.isEmpty })
        return client.text
    }

    private func jsonBody(_ response: String) throws -> [String: Any] {
        let separator = try #require(response.range(of: "\r\n\r\n"))
        #expect(response[..<separator.lowerBound].contains("Content-Type: application/json\r\n"))
        let data = Data(response[separator.upperBound...].utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func saveBody(_ paths: [String], expected: String?) -> String {
        var body = "n=\(paths.count)&paths=\(paths.joined(separator: "\n"))"
        if let expected { body += "&expected=\(expected)" }
        return body
    }

    private func deliver(_ response: String, to client: LauncherClientHarness) throws {
        let separator = try #require(response.range(of: "\r\n\r\n"))
        let statusText = try #require(response.split(separator: " ").dropFirst().first)
        let status = try #require(Int(statusText))
        try client.reply(String(response[separator.upperBound...]), status: status)
    }

    @Test func widgetsOnlySaveAfterDeferredLegacyMigrationPreservesAllSixSelections() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = (1...6).map { "/Legacy\($0).app" }
        let frozen = try seedLegacy(directory, paths)
        var operations = ConfigurationFileOperations.live
        let live = operations
        let firstCommit = OneShot()
        operations.commitDocument = { prepared, destination in
            if firstCommit.consume() { return false }
            return live.commitDocument(prepared, destination)
        }
        let store = ConfigurationStore(directory: directory, operations: operations)
        let (server, port) = try startServer(store: store)
        defer { server.stop() }
        let pending = try jsonBody(get(port: port))
        #expect(pending["configuration"] as? String == "legacy-pending")
        #expect(pending["writable"] as? Bool == true)
        #expect(pending["selected"] as? [String] == paths)
        #expect(!fileExists(store.configurationPath))
        let revision = try #require(pending["revision"] as? String)
        let saved = try jsonBody(post(port: port, body: "internet=0&batteries=1&expected=\(revision)"))
        #expect(saved["selected"] as? [String] == paths)
        #expect(saved["saved"] as? Int == 6)
        #expect(saved["widgets"] as? [String: Bool] == ["internet": false, "batteries": true])
        guard case .v2(let document) = ConfigurationDecoder.decode(.data(Data(try #require(readBytes(at: store.configurationPath))))) else {
            Issue.record("deferred migration did not commit V2"); return
        }
        #expect(document.controls == (try appDocumentFrom(paths: paths)).controls)
        #expect(readBytes(at: store.legacyPath) == frozen)
        #expect(!fileExists(store.backupPath))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func widgetWireContractPreservesSixAppsAndRefusesBadFlagsWithoutWriting() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, appDocument(count: 6))
        let store = ConfigurationStore(directory: directory)
        let (server, port) = try startServer(store: store)
        defer { server.stop() }
        let initial = try jsonBody(get(port: port))
        var revision = try #require(initial["revision"] as? String)
        let selected = try #require(initial["selected"] as? [String])
        #expect(selected.count == 6)
        for internet in ["0", "1"] {
            for batteries in ["0", "1"] {
                let response = try post(port: port, body: "internet=\(internet)&batteries=\(batteries)&expected=\(revision)")
                let json = try jsonBody(response)
                #expect(json["selected"] as? [String] == selected)
                let flags = try #require(json["widgets"] as? [String: Bool])
                #expect(flags == ["internet": internet == "1", "batteries": batteries == "1"])
                revision = try #require(json["revision"] as? String)
            }
        }
        let bytes = readBytes(at: store.configurationPath)
        for bad in ["internet=1", "batteries=0", "internet=true&batteries=0", "internet=0&batteries=01",
                    "internet=&batteries=1", "internet=2&batteries=1"] {
            let response = try post(port: port, body: bad + "&expected=\(revision)")
            #expect(response.hasPrefix("HTTP/1.1 400"))
            #expect(response.hasSuffix("invalid-widgets"))
            #expect(readBytes(at: store.configurationPath) == bytes)
        }
        let missing = try post(port: port, body: "internet=0&batteries=0")
        #expect(missing.hasPrefix("HTTP/1.1 400"))
        #expect(missing.hasSuffix("missing-revision"))
        let changed = try jsonBody(post(port: port, body: "internet=0&batteries=0&expected=\(revision)"))
        let stale = try post(port: port, body: saveBody(["/Stale.app"], expected: revision))
        #expect(stale.hasPrefix("HTTP/1.1 409"))
        #expect(stale.hasSuffix("stale"))
        let latestRevision = try #require(changed["revision"] as? String)
        let oldClientSave = try jsonBody(post(port: port, body: saveBody(selected.reversed(), expected: latestRevision)))
        #expect(oldClientSave["widgets"] as? [String: Bool] == ["internet": false, "batteries": false])
        #expect(oldClientSave["selected"] as? [String] == selected.reversed())
    }

    @Test func shippedClientEditsTwiceThroughTheStoreWithoutAnInterveningGet() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app"])
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory),
                                             catalog: { self.catalog })
        defer { server.stop() }
        let client = try LauncherClientHarness(token: token)
        try client.run("loadKeys()")
        try deliver(get(port: port, target: client.run("requests[0].path").toString()), to: client)

        // Exercise the actual editor selection handler, not just a manufactured draft.
        try client.run("openEditor(); $('editList').children[1].listeners.click(); $('editSave').tap()")
        let body = try #require(try client.run("requests[0].body").toString())
        #expect(HTTPRequest.parseForm(body)["n"] == "2")
        #expect(HTTPRequest.parseForm(body)["expected"]?.isEmpty == false)
        let saved = try post(port: port, target: client.run("requests[0].path").toString(), body: body)
        #expect(saved.hasPrefix("HTTP/1.1 200 OK\r\n"))
        try deliver(saved, to: client)
        #expect(try client.run("launcher.all.length").toInt32() == 2)
        #expect(try client.run("$('keys').children[1].lastChild.textContent").toString() == "Xcode")
        let revision = try client.run("cfg.revision").toString()

        // Preserve form delimiters, Unicode, empty entries and duplicates end to end.
        let paths = ["/Applications/A+B & 你好.app", "", "/Applications/A+B & 你好.app"]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: paths), as: UTF8.self)
        try client.run("openEditor(); draft = \(encoded); $('editSave').tap()")
        let secondBody = try #require(try client.run("requests[0].body").toString())
        #expect(HTTPRequest.parseForm(secondBody)["expected"] == revision)
        let second = try post(port: port, body: secondBody)
        #expect(second.hasPrefix("HTTP/1.1 200 OK\r\n"))
        try deliver(second, to: client)
        #expect(try client.run("launcher.selected").toArray() as? [String] == paths)
        #expect(try client.run("cfg.revision").toString() != revision)
        #expect(try client.run("notices[notices.length - 1]").toString() == "Deck saved")
        #expect(ConfigurationStore(directory: directory).load().selected == paths)
    }

    @Test func shippedClientRetainsItsEditWhenAnotherWriterMakesItsRevisionStale() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let (server, port) = try startServer(store: store)
        defer { server.stop() }
        let client = try LauncherClientHarness(token: token)
        try client.run("loadKeys()")
        try deliver(get(port: port), to: client)
        let originalRevision = try client.run("cfg.revision").toString()
        guard case .saved = store.write(paths: ["/Other.app"], expectedRevision: originalRevision) else {
            Issue.record("Fixture write failed")
            return
        }
        let original = readBytes(at: store.configurationPath)
        try client.run("openEditor(); draft = ['/Draft.app']; $('editSave').tap()")
        let body = try #require(try client.run("requests[0].body").toString())
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        try deliver(response, to: client)
        #expect(try client.run("cfg.revision").toString() == originalRevision)
        #expect(try client.run("draft[0]").toString() == "/Draft.app")
        #expect(try client.run("notices[notices.length - 1]").toString().contains("reload"))
        #expect(readBytes(at: store.configurationPath) == original)
    }

    @Test func shippedClientCannotPostATruncatedReadOnlySelection() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = (1...8).map { "/App\($0).app" }
        let legacy = try seedLegacy(directory, paths)
        let store = ConfigurationStore(directory: directory)
        let (server, port) = try startServer(store: store)
        defer { server.stop() }
        let client = try LauncherClientHarness(token: token)
        try client.run("loadKeys()")
        try deliver(get(port: port), to: client)
        let original = readBytes(at: store.configurationPath)
        #expect(try client.run("launcher.selected").toArray() as? [String] == paths)
        try client.run("openEditor(); $('editSave').tap()")
        #expect(try client.run("requests.length").toInt32() == 0)
        #expect(try client.run("cfg.writable").toBool() == false)
        #expect(try client.run("$('cfgWarn').textContent").toString().contains("7 keys"))
        #expect(readBytes(at: store.configurationPath) == original)
        #expect(readBytes(at: store.legacyPath) == legacy)
    }

    // MARK: T-A — GET → edit → POST → render → edit again

    @Test func getOnALegacyDirectoryMigratesAndServesTheFullShape() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let seeded = ["/Applications/Safari.app", "/Applications/Xcode.app", "/Applications/Notes.app"]
        let legacyBytes = try seedLegacy(directory, seeded)
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory),
                                             catalog: { self.catalog })
        defer { server.stop() }

        let response = try get(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let json = try jsonBody(response)
        #expect(json["selected"] as? [String] == seeded)
        #expect(json["all"] as? [[String: String]] == catalog)
        #expect(json["configuration"] as? String == "migrated")
        #expect(json["writable"] as? Bool == true)
        let revision = try #require(json["revision"] as? String)
        #expect(!revision.isEmpty)
        // GET never carries the POST-only field, and `version` only exists for unsupported-version.
        #expect(json["saved"] == nil)
        #expect(json["version"] == nil)

        // The migration committed config.json; the frozen legacy file is byte-intact.
        #expect(fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == legacyBytes)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func postSavesAndRefreshesTheRevisionSoASecondEditNeedsNoGet() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app", "/Applications/Xcode.app",
                                   "/Applications/Notes.app"])
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory),
                                             catalog: { self.catalog })
        defer { server.stop() }

        let getJSON = try jsonBody(try get(port: port))
        let firstRevision = try #require(getJSON["revision"] as? String)

        // Model the editor: drop one, add one, exactly seven or fewer.
        let draft = ["/Applications/Safari.app", "/Applications/Notes.app", "/Applications/Music.app"]
        let response = try post(port: port, body: saveBody(draft, expected: firstRevision))
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let json = try jsonBody(response)
        #expect(json["saved"] as? Int == 3)
        #expect(json["selected"] as? [String] == draft)
        // The catalog survives the save: renderKeys()/byPath() resolve against `all`.
        #expect(json["all"] as? [[String: String]] == catalog)
        #expect(json["configuration"] as? String == "v2")
        #expect(json["writable"] as? Bool == true)
        let secondRevision = try #require(json["revision"] as? String)
        #expect(secondRevision != firstRevision)
        // One shape for both methods: the POST keys are exactly the GET keys plus `saved`.
        #expect(Set(json.keys) == Set(getJSON.keys).union(["saved"]))

        // The first save over a migrated document keeps the previous generation.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) != nil)

        // Edit again using only the POST response — no second GET.
        let secondDraft = ["/Applications/Safari.app"]
        let second = try post(port: port, body: saveBody(secondDraft, expected: secondRevision))
        #expect(second.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let secondJSON = try jsonBody(second)
        #expect(secondJSON["saved"] as? Int == 1)
        #expect(secondJSON["selected"] as? [String] == secondDraft)
        #expect((secondJSON["revision"] as? String) != secondRevision)
    }

    // MARK: T-B — revision lifecycle

    @Test func aStaleRevisionIs409AndChangesNothing() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, appDocument(count: 1))
        let store = ConfigurationStore(directory: directory)
        let staleRevision = try #require(store.load().revision)

        // A second writer (another process, modeled by a second store) commits revision Y.
        let outcome = store.write(paths: ["/Applications/App2.app"], expectedRevision: staleRevision)
        guard case .saved(let committed) = outcome,
              let currentRevision = committed.revision, currentRevision != staleRevision else {
            Issue.record("the fixture's second write did not produce a fresh revision")
            return
        }
        let configAfterY = readBytes(at: storePath(directory, ConfigurationStore.configurationName))
        let backupAfterY = readBytes(at: storePath(directory, ConfigurationStore.backupName))

        let (server, port) = try startServer(store: store)
        defer { server.stop() }
        let response = try post(port: port,
                                body: saveBody(["/Applications/App3.app"], expected: staleRevision))
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        #expect(response.hasSuffix("\r\n\r\nstale"))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == configAfterY)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == backupAfterY)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aMissingOrEmptyExpectedRevisionIs400AndChangesNothing() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let baseBytes = try seedConfiguration(directory, appDocument(count: 1))
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        for body in ["n=1&paths=/Applications/Safari.app",
                     "n=1&paths=/Applications/Safari.app&expected="] {
            let response = try post(port: port, body: body)
            #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            #expect(response.hasSuffix("\r\n\r\nmissing-revision"))
            #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == baseBytes)
        }
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aDamagedDocumentRefusesBeforeTheMissingRevisionCheck() throws {
        // T-B7 precedence: "reload the page" is useless advice when the file is damaged.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let damaged = "{\"version\":1,\"controls\":[],}"
        try writeText(damaged, to: storePath(directory, ConfigurationStore.configurationName))
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let response = try post(port: port, body: "n=1&paths=/Applications/Safari.app")
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        #expect(response.hasSuffix("\r\n\r\nmalformed"))

        let getResponse = try get(port: port)
        #expect(getResponse.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let json = try jsonBody(getResponse)
        #expect(json["configuration"] as? String == "malformed")
        #expect(json["selected"] is NSNull)
        #expect(json["writable"] as? Bool == false)
        // A damaged document still publishes a raw-bytes revision, for diagnostics.
        #expect(json["revision"] is String)
        // The damaged file is preserved exactly: nothing deletes or repairs it.
        let bytes = readBytes(at: storePath(directory, ConfigurationStore.configurationName))
        #expect(bytes == [UInt8](Data(damaged.utf8)))
    }

    // MARK: Read-only states

    @Test func anUnsupportedVersionCarriesTheIntegerDiagnosisAndRefusesSaves() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let future = "{\"version\":3,\"controls\":[]}"
        try writeText(future, to: storePath(directory, ConfigurationStore.configurationName))
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let json = try jsonBody(try get(port: port))
        #expect(json["configuration"] as? String == "unsupported-version")
        #expect(json["version"] as? Int == 3)
        #expect(json["writable"] as? Bool == false)
        #expect(json["selected"] is NSNull)
        let revision = try #require(json["revision"] as? String)

        let response = try post(port: port, body: saveBody(["/Applications/Safari.app"], expected: revision))
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        #expect(response.hasSuffix("\r\n\r\nunsupported-version"))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == [UInt8](Data(future.utf8)))
    }

    @Test func anOverLimitDocumentIsServedWholeAndRefusesATruncatingSave() throws {
        // T-C: 8 controls must not become 7.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let document = try appDocument(count: 8)
        let baseBytes = try seedConfiguration(directory, document)
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let json = try jsonBody(try get(port: port))
        let expectedPaths = (1...8).map { "/Applications/App\($0).app" }
        #expect(json["selected"] as? [String] == expectedPaths)   // untruncated
        #expect(json["writable"] as? Bool == false)
        #expect(json["configuration"] as? String == "too-many-controls")
        let revision = try #require(json["revision"] as? String)

        // The editor's slice(0, 7) is exactly the save the server must refuse.
        let truncated = Array(expectedPaths.prefix(7))
        let response = try post(port: port, body: saveBody(truncated, expected: revision))
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        #expect(response.hasSuffix("\r\n\r\ntoo-many-controls"))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == baseBytes)
        #expect(!fileExists(storePath(directory, ConfigurationStore.backupName)))
        #expect(leftoverTemporaries(directory).isEmpty)

        // Control: the same shape at seven controls is writable and saves.
        let sevenDirectory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(sevenDirectory) }
        try seedConfiguration(sevenDirectory, try appDocument(count: 7))
        let (sevenServer, sevenPort) = try startServer(store: ConfigurationStore(directory: sevenDirectory))
        defer { sevenServer.stop() }
        let sevenJSON = try jsonBody(try get(port: sevenPort))
        #expect(sevenJSON["writable"] as? Bool == true)
        let sevenRevision = try #require(sevenJSON["revision"] as? String)
        let sevenPaths = (1...7).map { "/Applications/App\($0).app" }
        let saved = try post(port: sevenPort, body: saveBody(sevenPaths, expected: sevenRevision))
        #expect(saved.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(try jsonBody(saved)["saved"] as? Int == 7)
    }

    @Test func aWrongFormatDocumentIsReportedAndPreserved() throws {
        // A legacy array in config.json is a layout error, never a document to adopt.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let misplaced = "[\"/Applications/Safari.app\"]"
        try writeText(misplaced, to: storePath(directory, ConfigurationStore.configurationName))
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let json = try jsonBody(try get(port: port))
        #expect(json["configuration"] as? String == "wrong-format")
        #expect(json["writable"] as? Bool == false)
        #expect(json["selected"] is NSNull)
        let revision = try #require(json["revision"] as? String)
        let response = try post(port: port, body: saveBody(["/Applications/Safari.app"], expected: revision))
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        #expect(response.hasSuffix("\r\n\r\nwrong-format"))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName))
            == [UInt8](Data(misplaced.utf8)))
    }

    @Test func anUnrepresentableLegacySelectionIsServedReadOnlyAndPreserved() throws {
        // F4/R10: an entry too long to migrate is still shown, and never overwritten.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let longPath = String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes + 1)
        let legacyBytes = try seedLegacy(directory, [longPath])
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let json = try jsonBody(try get(port: port))
        #expect(json["configuration"] as? String == "legacy-readonly")
        #expect(json["selected"] as? [String] == [longPath])
        #expect(json["writable"] as? Bool == false)
        let revision = try #require(json["revision"] as? String)

        let response = try post(port: port, body: saveBody(["/Applications/Safari.app"], expected: revision))
        #expect(response.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        #expect(response.hasSuffix("\r\n\r\nlegacy-readonly"))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == legacyBytes)
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
    }

    // MARK: Concurrency

    @Test func aContendedLockReadsAsMigratingWithoutRevisionAndWritesAs503() throws {
        // T-B8: a contended read publishes no token the server cannot honour.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app"])
        let store = ConfigurationStore(directory: directory)
        let (server, port) = try startServer(store: store)
        defer { server.stop() }

        // Hold the real lock from a second file description, which is what another process does.
        let descriptor = store.lockPath.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
        guard descriptor >= 0 else {
            Issue.record("the lock file could not be opened")
            return
        }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }

        let response = try get(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let json = try jsonBody(response)
        #expect(json["configuration"] as? String == "migrating")
        #expect(json["writable"] as? Bool == false)
        #expect(json["revision"] == nil)   // the key is absent entirely, not null
        // The selection is still served: the legacy file is authoritative until migration commits.
        #expect(json["selected"] as? [String] == ["/Applications/Safari.app"])
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))

        let saveResponse = try post(port: port,
                                    body: saveBody(["/Applications/Safari.app"], expected: "0000000000000000"))
        #expect(saveResponse.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        #expect(saveResponse.hasSuffix("\r\n\r\nbusy"))
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
    }

    // MARK: Failure injection through the store's filesystem seam

    @Test func aFailedPrepareIs500WriteFailedAndLeavesNothingBehind() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let baseBytes = try seedConfiguration(directory, appDocument(count: 1))
        let revision = try #require(ConfigurationStore(directory: directory).load().revision)

        var operations = ConfigurationFileOperations.live
        operations.makeTemporary = { _, _ in nil }
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory,
                                                                       operations: operations))
        defer { server.stop() }

        let response = try post(port: port, body: saveBody(["/Applications/Safari.app"], expected: revision))
        #expect(response.hasPrefix("HTTP/1.1 500 Internal Server Error\r\n"))
        #expect(response.hasSuffix("\r\n\r\nwrite-failed"))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == baseBytes)
        #expect(!fileExists(storePath(directory, ConfigurationStore.backupName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aFailedVerificationOfAnInitialCommitIs500MigrationFailedAndRetainsTheDocument() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let unconfiguredRevision = try #require(store.load().revision)

        var operations = ConfigurationFileOperations.live
        operations.readForVerification = { _, _ in .unreadable }
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory,
                                                                       operations: operations))
        defer { server.stop() }

        let response = try post(port: port,
                                body: saveBody(["/Applications/Safari.app"], expected: unconfiguredRevision))
        #expect(response.hasPrefix("HTTP/1.1 500 Internal Server Error\r\n"))
        #expect(response.hasSuffix("\r\n\r\nmigration-failed"))
        // Retained as evidence, never deleted, and never reported as migrated or saved.
        let expectedBytes = try [UInt8](encodedDocument(try appDocumentFrom(paths: ["/Applications/Safari.app"])))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == expectedBytes)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    // MARK: Preservation (requirement 6 — no Apps.isKnown filter)

    @Test func aSavePreservesOrderEmptyEntriesDuplicatesAndUninstalledPaths() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let (server, port) = try startServer(store: store, catalog: { self.catalog })
        defer { server.stop() }

        let unconfigured = try jsonBody(try get(port: port))
        #expect(unconfigured["configuration"] as? String == "unconfigured")
        #expect(unconfigured["selected"] is NSNull)
        #expect(unconfigured["writable"] as? Bool == true)
        let revision = try #require(unconfigured["revision"] as? String)

        // One uninstalled path, one empty entry, one duplicate — in a chosen order.
        let selection = ["/NotInstalled/Zed.app", "", "/Applications/Safari.app", "/Applications/Safari.app"]
        let body = "n=4&paths=\(selection.joined(separator: "\n"))&expected=\(revision)"
        let response = try post(port: port, body: body)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let json = try jsonBody(response)
        #expect(json["saved"] as? Int == 4)
        #expect(json["selected"] as? [String] == selection)   // element-for-element, in order

        // A follow-up GET returns the same array, and the stored document round-trips.
        let reread = try jsonBody(try get(port: port))
        #expect(reread["selected"] as? [String] == selection)
        #expect(reread["configuration"] as? String == "v2")
    }

    @Test func anUnconfiguredDirectorySavesAnEmptySelection() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let revision = try #require(store.load().revision)
        #expect(revision == ConfigurationRevision.ofUnconfigured())
        let (server, port) = try startServer(store: store)
        defer { server.stop() }

        let response = try post(port: port, body: "n=0&paths=&expected=\(revision)")
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let json = try jsonBody(response)
        #expect(json["saved"] as? Int == 0)
        // An empty selection is an empty array, not null: null means "cannot be expressed".
        #expect(json["selected"] as? [String] == [])
        #expect(json["configuration"] as? String == "v2")
    }

    // MARK: Syntax refusals (route level, before any store access)

    @Test func routeSyntaxRefusalsAre400AndTouchNothing() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let longPath = String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes + 1)
        for (body, tokenText) in [("n=8&paths=/Applications/Safari.app", "invalid-count"),
                                  ("n=2&paths=/Applications/Safari.app", "count-mismatch"),
                                  ("n=1&paths=\(longPath)", "entry-too-long")] {
            let response = try post(port: port, body: body)
            #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            #expect(response.hasSuffix("\r\n\r\n\(tokenText)"))
        }
        // A legacy client (no `n`) is bounded by the store's product rule instead.
        let eightPaths = (1...8).map { "/Applications/App\($0).app" }.joined(separator: "\n")
        let legacy = try post(port: port, body: "paths=\(eightPaths)")
        #expect(legacy.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(legacy.hasSuffix("\r\n\r\ntoo-many-keys"))
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    // MARK: Authorization boundary

    @Test func authenticationIsRequiredBeforeTheStoreIsTouched() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let (server, port) = try startServer(store: ConfigurationStore(directory: directory))
        defer { server.stop() }

        let body = saveBody(["/Applications/Changed.app"], expected: "0000000000000000")
        for (target, status) in [
            ("/launcher", "403 Forbidden"),
            ("/launcher?k=wrong-token", "403 Forbidden"),
            ("/launcher?k=\(token)&k=\(token)", "400 Bad Request"),
        ] {
            let readResponse = try get(port: port, target: target)
            #expect(readResponse.hasPrefix("HTTP/1.1 \(status)\r\n"))
            let saveResponse = try post(port: port, target: target, body: body)
            #expect(saveResponse.hasPrefix("HTTP/1.1 \(status)\r\n"))
        }
        // A token in the body cannot substitute for query-token authentication.
        let bodyToken = try post(port: port, target: "/launcher", body: "k=\(token)&" + body)
        #expect(bodyToken.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        // Admission refused every request before the handler, so the store never ran: no lock
        // file, no migration, no temporaries.
        #expect(directoryEntries(directory).isEmpty)
    }
}
