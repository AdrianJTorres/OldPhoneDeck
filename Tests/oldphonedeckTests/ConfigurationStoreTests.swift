import Foundation
import Testing
@testable import oldphonedeck

// MARK: - Shared helpers
//
// Every test here owns a fresh temporary directory, so none of them touches `~/.oldphonedeck`,
// reads the real token or `launcher.json`, starts the application, or needs `$HOME` redirection —
// which would not work anyway, because `NSHomeDirectory()` ignores `$HOME` on this macOS build and
// is exactly why `ConfigurationStore` takes an injected directory.

/// Creates a `0700` temporary configuration directory. The caller removes it with
/// `removeStoreDirectory`, matching the `TLSResourceTests` convention.
func temporaryStoreDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("phonedeck-store-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

func removeStoreDirectory(_ url: URL) {
    // A file chmod-ed to 000 by a test is still removable, because the directory is writable.
    try? FileManager.default.removeItem(at: url)
}

func storePath(_ directory: URL, _ name: String) -> String {
    directory.appendingPathComponent(name).path
}

func writeBytes(_ bytes: [UInt8], to path: String) throws {
    try Data(bytes).write(to: URL(fileURLWithPath: path))
}

func writeText(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

func readBytes(at path: String) -> [UInt8]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return [UInt8](data)
}

func fileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func directoryEntries(_ directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
}

/// Temporary files left behind by a store operation. A clean run leaves none: every failure path
/// unlinks its own temps, and no startup sweep is allowed to remove another process's.
func leftoverTemporaries(_ directory: URL) -> [String] {
    directoryEntries(directory).filter { $0.contains(".tmp-") }
}

/// A legacy launcher document in the exact shape `Launcher.save` writes: a pretty-printed bare JSON
/// array of application paths.
func legacyDocument(_ paths: [String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: paths, options: .prettyPrinted)
}

func appControl(index: Int, path: String) throws -> DeckControl {
    let id = try #require(ControlID(rawValue: "app-\(index)"))
    return DeckControl(id: id, action: .appLaunch, parameters: .appPath(path),
                       presentation: ControlPresentation(title: nil))
}

/// A document of `count` positional app-launch controls, i.e. exactly what a migration produces.
func appDocument(count: Int, prefix: String = "/Applications/App") throws -> DeckConfigurationV1 {
    guard count > 0 else { return DeckConfigurationV1(controls: []) }
    var controls: [DeckControl] = []
    for index in 1...count {
        controls.append(try appControl(index: index, path: "\(prefix)\(index).app"))
    }
    return DeckConfigurationV1(controls: controls)
}

/// Thrown when a test's own fixture is impossible, so a broken fixture fails loudly instead of
/// silently asserting against `nil`.
struct FixtureError: Error {
    let message: String
}

func encodedDocument(_ configuration: DeckConfigurationV1) throws -> Data {
    guard case .success(let data) = ConfigurationEncoder.verifiedData(configuration) else {
        throw FixtureError(message: "the encoder rejected a test fixture")
    }
    return data
}

/// The document a migration of `paths` produces, for assertions that need the value rather than the
/// bytes.
func appDocumentFrom(paths: [String]) throws -> DeckConfigurationV1 {
    guard case .success(let document) = ConfigurationMigrator.migrateToV1(paths) else {
        throw FixtureError(message: "the fixture selection did not migrate")
    }
    return document
}

/// Seeds `config.json` with a valid V1 document and returns the store's own canonical bytes, so a
/// test can assert byte-equality after a refusal.
@discardableResult
func seedConfiguration(_ directory: URL, _ configuration: DeckConfigurationV1) throws -> [UInt8] {
    let data = try encodedDocument(configuration)
    try data.write(to: URL(fileURLWithPath: storePath(directory, ConfigurationStore.configurationName)))
    return [UInt8](data)
}

@discardableResult
func seedLegacy(_ directory: URL, _ paths: [String]) throws -> [UInt8] {
    let data = try legacyDocument(paths)
    try data.write(to: URL(fileURLWithPath: storePath(directory, ConfigurationStore.legacyName)))
    return [UInt8](data)
}

/// A one-shot switch, so an injected fault can fail exactly one call and then pass through to the
/// live implementation. Recovery verification needs this: the first read must look corrupt and the
/// second must succeed.
final class OneShot {
    private let lock = NSLock()
    private var used = false
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Records the order in which the store invoked each filesystem step, so a test can assert the
/// algorithm's sequencing (prepare → backup swap → commit → verify) and not just its outcome.
final class StepRecorder {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ step: String) {
        lock.lock(); recorded.append(step); lock.unlock()
    }
    var steps: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Classification

@Suite struct ConfigurationStoreClassificationTests {
    @Test func absentEverywhereIsUnconfiguredAndWritable() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)

        let read = store.load()
        #expect(read.state == .unconfigured)
        #expect(read.selected == nil)
        #expect(read.status == .unconfigured)
        #expect(read.writable)
        #expect(read.version == nil)
        // An unconfigured deck still publishes a revision: it denotes the empty V1 document, so a
        // client that reads it and then saves an empty selection is not writing over anything.
        #expect(read.revision != nil)
        // Nothing was created by looking.
        #expect(directoryEntries(directory).isEmpty)
    }

    @Test func aVersionedDocumentIsReady() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app", "/Applications/Xcode.app", "/Applications/Music.app"]
        let document = try appDocumentFrom(paths: paths)
        try seedConfiguration(directory, document)
        let store = ConfigurationStore(directory: directory)

        let read = store.load()
        #expect(read.state == .ready(document))
        #expect(read.selected == paths)
        #expect(read.status == .v1)
        #expect(read.writable)
        #expect(read.revision != nil)
    }

    @Test func sevenControlsIsTheWritableBoundary() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, try appDocument(count: 7))

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.status == .v1)
        #expect(read.writable)
        #expect(read.selected?.count == 7)
    }

    /// The regression Steering named: a representable document of eight app controls must not become
    /// writable, because the editor truncates to `APP_SLOTS` on load and a save would silently
    /// discard the eighth.
    @Test func eightControlsAreServedInFullAndReadOnly() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let document = try appDocument(count: 8)
        let seeded = try seedConfiguration(directory, document)
        let store = ConfigurationStore(directory: directory)

        let read = store.load()
        #expect(read.state == .overLimit(document))
        #expect(read.status == .tooManyControls)
        #expect(!read.writable)
        // Served in full: `selected: nil` means "cannot be expressed as a path list", and eight app
        // launches can be. The client truncates for display; the server never truncates on disk.
        #expect(read.selected?.count == 8)
        #expect(read.selected?.last == "/Applications/App8.app")
        // Still published, for diagnostics and so a client can see it is not a stale token.
        #expect(read.revision != nil)

        // The editor's own truncation, modelled: this is the draft a save would have sent.
        let draft = Array((read.selected ?? []).prefix(7))
        #expect(draft.count == 7)
        let outcome = store.write(paths: draft, expectedRevision: read.revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("an over-limit document accepted a truncating save")
            return
        }
        #expect(failure.rejection == .state(.tooManyControls))
        #expect(failure.stateAfterFailure == nil)
        // Byte-identical: the refusal changed nothing.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == seeded)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test(arguments: [
        ("a presentation title", "titled"),
        ("a custom control id", "custom-id"),
        ("a gapped id sequence", "gapped"),
        ("an unregistered action", "unregistered"),
    ])
    func unprojectableDocumentsAreReadOnlyWithNoSelection(_ label: String, _ kind: String) throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }

        let document: DeckConfigurationV1
        switch kind {
        case "titled":
            var controls = try appDocument(count: 2).controls
            controls[0] = DeckControl(id: controls[0].id, action: .appLaunch,
                                      parameters: .appPath("/Applications/Safari.app"),
                                      presentation: ControlPresentation(title: "Browser"))
            document = DeckConfigurationV1(controls: controls)
        case "custom-id":
            let id = try #require(ControlID(rawValue: "build"))
            document = DeckConfigurationV1(controls: [
                DeckControl(id: id, action: .appLaunch, parameters: .appPath("/Applications/Xcode.app"),
                            presentation: ControlPresentation(title: nil)),
            ])
        case "gapped":
            document = DeckConfigurationV1(controls: [
                try appControl(index: 1, path: "/Applications/Safari.app"),
                try appControl(index: 3, path: "/Applications/Music.app"),
            ])
        default:
            let action = try #require(ActionID(rawValue: "shortcuts.run"))
            let id = try #require(ControlID(rawValue: "app-1"))
            document = DeckConfigurationV1(controls: [
                DeckControl(id: id, action: action, parameters: .unmodeled(["name": "Build"]),
                            presentation: ControlPresentation(title: nil)),
            ])
        }
        try seedConfiguration(directory, document)
        let read = ConfigurationStore(directory: directory).load()

        #expect(read.state == .unprojectable(document), "\(label) was not reported as unprojectable")
        #expect(read.status == .unrepresentable)
        #expect(read.selected == nil, "\(label) produced a partial projection")
        #expect(!read.writable)
    }

    @Test func malformedConfigurationIsReportedNotReinterpreted() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        // A trailing comma: `JSONSerialization` accepts it, the codec's strict scanner does not.
        let damaged = "{\"version\":1,\"controls\":[],}"
        try writeText(damaged, to: storePath(directory, ConfigurationStore.configurationName))
        // A legacy selection that a fallback would happily adopt.
        try seedLegacy(directory, ["/Applications/Safari.app"])

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.state == .damaged(.config, .malformed(.notJSON)))
        #expect(read.status == .malformed)
        #expect(read.writable == false)
        // The legacy file is NOT substituted for a damaged authoritative one: that is the silent
        // fallback ADR-016 forbids, and it would resurrect a stale selection over a newer document.
        #expect(read.selected == nil)
        #expect(read.revision != nil)
    }

    @Test func aNewerVersionIsUnsupportedNotCorrupt() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try writeText("{\"version\":2,\"controls\":[]}",
                      to: storePath(directory, ConfigurationStore.configurationName))

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.state == .damaged(.config, .unsupportedVersion(found: 2)))
        #expect(read.status == .unsupportedVersion)
        #expect(read.version == 2)
        #expect(!read.writable)
    }

    @Test func aVersionBelowOneIsCorruptNotFromTheFuture() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try writeText("{\"version\":0,\"controls\":[]}",
                      to: storePath(directory, ConfigurationStore.configurationName))

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.status == .malformed)
        #expect(read.version == nil)
    }

    @Test func aLegacyArrayInTheVersionedFileIsWrongFormatAndNotAdopted() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let seeded = try seedLegacy(directory, ["/Applications/Safari.app", "/Applications/Music.app"])
        try writeBytes(seeded, to: storePath(directory, ConfigurationStore.configurationName))

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.state == .wrongFormat(.config))
        #expect(read.status == .wrongFormat)
        #expect(read.selected == nil, "an array in config.json was adopted as a selection")
        #expect(!read.writable)
        // Reported, not repaired: the file is exactly as the user left it.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == seeded)
    }

    @Test func aVersionedDocumentInTheLegacyFileIsWrongFormatAndNotAdopted() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let document = try encodedDocument(try appDocument(count: 2))
        try writeBytes([UInt8](document), to: storePath(directory, ConfigurationStore.legacyName))

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.state == .wrongFormat(.legacy))
        #expect(read.status == .wrongFormat)
        #expect(read.selected == nil)
        #expect(!read.writable)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == [UInt8](document))
    }

    @Test func aSymlinkedConfigurationIsNeverWrittenThrough() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        // A target outside the configuration directory, standing in for a synced or shared file.
        let target = directory.appendingPathComponent("elsewhere.json").path
        let seeded = try seedConfiguration(directory, try appDocument(count: 2))
        try FileManager.default.moveItem(atPath: storePath(directory, ConfigurationStore.configurationName),
                                         toPath: target)
        try FileManager.default.createSymbolicLink(
            atPath: storePath(directory, ConfigurationStore.configurationName), withDestinationPath: target)

        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        #expect(read.state == .damaged(.config, .notRegularFile))
        #expect(read.status == .unreadable)
        #expect(!read.writable)

        let outcome = store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .state(.unreadable),
                                                               stateAfterFailure: nil)))
        // Neither the link nor its target was touched: `rename` over a symlink would have replaced
        // the user's link with a regular file, and writing through it would have reached outside
        // the configuration directory.
        #expect(readBytes(at: target) == seeded)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: storePath(directory, ConfigurationStore.configurationName), isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aDirectoryInPlaceOfTheConfigurationIsNotARegularFile() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try FileManager.default.createDirectory(
            atPath: storePath(directory, ConfigurationStore.configurationName),
            withIntermediateDirectories: true)

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.state == .damaged(.config, .notRegularFile))
        #expect(read.status == .unreadable)
        #expect(!read.writable)
    }

    /// `O_NOFOLLOW` is not sufficient on its own: opening a FIFO read-only blocks until a writer
    /// appears, which on the shared HTTP queue would hang the whole deck. This test is the proof
    /// that `O_NONBLOCK` is there — without it the suite would hang rather than fail.
    @Test func aFifoInPlaceOfTheConfigurationDoesNotBlock() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let path = storePath(directory, ConfigurationStore.configurationName)
        #expect(mkfifo(path, 0o600) == 0)

        let started = Date()
        let read = ConfigurationStore(directory: directory).load()
        let elapsed = Date().timeIntervalSince(started)

        #expect(read.state == .damaged(.config, .notRegularFile))
        #expect(read.status == .unreadable)
        #expect(!read.writable)
        #expect(elapsed < 5.0, "reading a FIFO blocked for \(elapsed)s")
    }

    @Test func anUnreadableConfigurationIsReportedAndNeverOverwritten() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let path = storePath(directory, ConfigurationStore.configurationName)
        let seeded = try seedConfiguration(directory, try appDocument(count: 2))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }

        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        #expect(read.state == .damaged(.config, .unreadable))
        #expect(read.status == .unreadable)
        #expect(read.selected == nil)
        #expect(!read.writable)
        #expect(store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
            == .rejected(ConfigurationWriteFailure(rejection: .state(.unreadable), stateAfterFailure: nil)))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(readBytes(at: path) == seeded)
    }

    @Test func anUnreadableLegacyFileDoesNotFallBackToNothing() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let path = storePath(directory, ConfigurationStore.legacyName)
        try writeText("[\"/Applications/Safari.app\"]", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }

        let read = ConfigurationStore(directory: directory).load()
        // Unreadable is not absent: reporting `unconfigured` here would let a later save create a
        // document that silently replaces whatever this file holds.
        #expect(read.state == .damaged(.legacy, .unreadable))
        #expect(read.status == .unreadable)
        #expect(!read.writable)
    }

    @Test func anOversizedDocumentIsRejectedWithoutBeingAllocated() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let cap = ConfigurationDecoder.maximumDocumentBytes
        // Three megabytes of one JSON string: valid JSON syntax, far over the cap.
        var text = "[\""
        text += String(repeating: "a", count: 3 * 1024 * 1024)
        text += "\"]"
        try writeText(text, to: storePath(directory, ConfigurationStore.configurationName))

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.state == .damaged(.config, .malformed(.documentTooLarge)))
        #expect(read.status == .malformed)
        #expect(!read.writable)
        // The bounded read stopped at cap + 1, which is what lets the codec stay the single
        // authority on "too large" without the store allocating the whole file.
        let bounded = POSIXConfigurationFile.readBounded(
            storePath(directory, ConfigurationStore.configurationName), cap)
        guard case .bytes(let bytes) = bounded else {
            Issue.record("bounded read did not return bytes")
            return
        }
        #expect(bytes.count == cap + 1)
    }

    @Test func anEmptyLegacySelectionIsAPendingMigrationNotAnAbsentOne() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, [])

        let classification = ConfigurationStore(directory: directory).classify()
        #expect(classification.state == .migrationPending(DeckConfigurationV1(controls: []), []))
        let read = ConfigurationStore(directory: directory).load()
        // A deliberately empty deck round-trips and is not the same as an unconfigured one.
        #expect(read.selected == [])
        #expect(read.writable)
    }

    @Test func theAuthoritativeFileWinsOverAFrozenLegacyFile() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, try appDocument(count: 2))
        try seedLegacy(directory, ["/Applications/Completely.app", "/Applications/Different.app"])

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.status == .v1)
        #expect(read.selected == ["/Applications/App1.app", "/Applications/App2.app"])
    }

    @Test func everyNonWritableStateRefusesAWriteBeforeTheRevisionIsConsulted() throws {
        // State before revision, because "reload the page" is useless advice when the file itself is
        // damaged: a client holding no revision at all must still be told the real reason.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try writeText("{\"version\":1,\"controls\":[],}",
                      to: storePath(directory, ConfigurationStore.configurationName))
        let store = ConfigurationStore(directory: directory)

        #expect(store.write(paths: [], expectedRevision: nil)
            == .rejected(ConfigurationWriteFailure(rejection: .state(.malformed), stateAfterFailure: nil)))
        #expect(store.write(paths: [], expectedRevision: "0000000000000000")
            == .rejected(ConfigurationWriteFailure(rejection: .state(.malformed), stateAfterFailure: nil)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }
}
