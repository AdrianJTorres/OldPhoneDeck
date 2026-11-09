import Foundation
import Testing
@testable import oldphonedeck

private let widgetCombinations = [
    WidgetPreferences(internet: false, batteries: false),
    WidgetPreferences(internet: false, batteries: true),
    WidgetPreferences(internet: true, batteries: false),
    WidgetPreferences(internet: true, batteries: true),
]

private func metadataV1() throws -> DeckConfigurationV1 {
    let controls = [
        DeckControl(id: try #require(ControlID(rawValue: "custom-browser")), action: .appLaunch,
                    parameters: .appPath("/Missing.app"), presentation: ControlPresentation(title: "Browser")),
        DeckControl(id: try #require(ControlID(rawValue: "future-key")),
                    action: try #require(ActionID(rawValue: "future.action")),
                    parameters: .unmodeled(["opaque": "preserve me"]), presentation: ControlPresentation(title: nil)),
    ]
    return DeckConfigurationV1(controls: controls)
}

@Suite struct WidgetCodecTests {
    @Test(arguments: widgetCombinations)
    func strictRoundTripAndExplicitExport(_ preferences: WidgetPreferences) throws {
        let source = try metadataV1()
        var document = try ConfigurationMigrator.migrateToV2(source).get()
        #expect(document.controls == source.controls)
        #expect(document.widgets == .visible)
        document.widgets = preferences
        let bytes = try ConfigurationEncoder.encode(document)
        #expect(ConfigurationDecoder.decode(.data(bytes)) == .v2(document))
        let exported = try ConfigurationMigrator.exportV1(document).get()
        #expect(ConfigurationDecoder.decode(.data(exported)) == .v1(source))
        #expect(exported == ConfigurationCanonicalForm.data(source))
        // Preserving unknown action data never provides executable parameters.
        #expect(document.controls[1].parameters.actionParameters == nil)
    }

    @Test(arguments: [
        #"{"internet":true}"#, #"{"batteries":true}"#, #"null"#, #"[]"#,
        #"{"internet":1,"batteries":false}"#, #"{"internet":"true","batteries":true}"#,
        #"{"internet":null,"batteries":true}"#, #"{"internet":true,"batteries":true,"other":false}"#,
        #"{"internet":true,"internet":false,"batteries":true}"#,
        #"{"internet":true,"batteries":false,}"#,
    ])
    func invalidWidgetSchemasFailClosed(_ widgets: String) {
        let data = Data("{\"version\":2,\"controls\":[],\"widgets\":\(widgets)}".utf8)
        guard case .malformed = ConfigurationDecoder.decode(.data(data)) else {
            Issue.record("invalid widgets were accepted"); return
        }
    }

    @Test func schemaAndExactVersionBoundaries() {
        func decode(_ text: String) -> ConfigurationState { ConfigurationDecoder.decode(.data(Data(text.utf8))) }
        #expect(decode(#"{"version":2,"controls":[]}"#) == .malformed(.invalidWidgets))
        #expect(decode(#"{"version":1,"controls":[],"widgets":{"internet":true,"batteries":true}}"#) == .malformed(.unknownKey))
        #expect(decode(#"{"version":3,"arbitrary":true}"#) == .unsupportedVersion(found: 3))
        #expect(decode(#"{"version":2.0000000000000001,"controls":[],"widgets":{"internet":true,"batteries":true}}"#) == .malformed(.invalidVersion))
        #expect(decode(#"{"version":0.2e1,"controls":[],"widgets":{"internet":true,"batteries":false}}"#) == .v2(DeckConfigurationV2(controls: [], widgets: widgetCombinations[2])))
    }

    @Test func canonicalV2CapIsMeasuredInBothDirections() throws {
        // 4096 bounded inert controls can exceed the canonical cap while compact input fits.
        let controls = (1...3500).map { index in
            DeckControl(id: ControlID(rawValue: "key-\(index)")!, action: ActionID(rawValue: "future.action")!,
                        parameters: .unmodeled(["data": String(repeating: "x", count: 180)]),
                        presentation: ControlPresentation(title: nil))
        }
        let document = DeckConfigurationV2(controls: controls)
        let canonical = try #require(ConfigurationCanonicalForm.data(document))
        #expect(canonical.count > ConfigurationDecoder.maximumDocumentBytes)
        let json = try JSONSerialization.jsonObject(with: canonical)
        let compact = try JSONSerialization.data(withJSONObject: json)
        #expect(compact.count < ConfigurationDecoder.maximumDocumentBytes)
        #expect(ConfigurationDecoder.decode(.data(compact)) == .malformed(.documentTooLarge))
        #expect(ConfigurationEncoder.verifiedData(document) == .failure(.documentTooLarge))
    }
}

@Suite struct WidgetStoreTests {
    @Test(arguments: widgetCombinations)
    func widgetOnlyAndApplicationOnlySavesPreserveTheOtherHalf(_ preferences: WidgetPreferences) throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let initial = try appDocument(count: 6)
        try seedConfiguration(directory, initial)
        let store = ConfigurationStore(directory: directory)
        let before = store.load()
        guard case .saved(let widgetsSaved) = store.write(paths: nil, expectedRevision: before.revision, widgets: preferences),
              case .ready(let widgetsDocument) = widgetsSaved.state else {
            Issue.record("widget save failed"); return
        }
        #expect(widgetsDocument.controls == initial.controls)
        #expect(widgetsSaved.widgets == preferences)
        #expect(widgetsSaved.selected == before.selected)
        if preferences != .visible { #expect(widgetsSaved.revision != before.revision) }
        // An already-loaded M3.1 page sends no widget flags.
        let editedPaths = ["/New.app", "", "/New.app", "/Missing.app", "/E.app", "/F.app"]
        guard case .saved(let appsSaved) = store.write(paths: editedPaths, expectedRevision: widgetsSaved.revision) else {
            Issue.record("application save failed"); return
        }
        #expect(appsSaved.widgets == preferences)
        #expect(appsSaved.selected == editedPaths)
        #expect(store.load().widgets == preferences)
        guard case .ready(let latest) = appsSaved.state else { Issue.record("not ready"); return }
        let export = try ConfigurationMigrator.exportV1(latest).get()
        guard case .v1(let rolledBack) = ConfigurationDecoder.decode(.data(export)) else {
            Issue.record("export is not V1"); return
        }
        #expect(ConfigurationMigrator.legacySelection(rolledBack) == editedPaths)
    }

    @Test func migrationKeepsExactSnapshotAndMetadataAndNeverFlattens() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let source = try metadataV1()
        // Deliberately noncanonical whitespace is part of the immutable snapshot.
        let original = [UInt8](Data(" \n".utf8) + (try ConfigurationEncoder.encode(source)) + Data("\n ".utf8))
        let store = ConfigurationStore(directory: directory)
        try writeBytes(original, to: store.configurationPath)
        let frozen = try seedLegacy(directory, ["/Frozen.app"])
        let beforeRevision = ConfigurationStore.revision(for: store.classify())
        let migrated = store.load()
        #expect(migrated.status == .unrepresentable)
        #expect(!migrated.writable)
        #expect(migrated.revision == beforeRevision)
        #expect(migrated.selected == nil)
        guard case .unprojectable(let document) = migrated.state else {
            Issue.record("metadata lost during migration"); return
        }
        #expect(document.controls == source.controls)
        #expect(document.widgets == .visible)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.v1SnapshotName)) == original)
        #expect(readBytes(at: store.backupPath) == original)
        #expect(readBytes(at: store.legacyPath) == frozen)
        let committed = readBytes(at: store.configurationPath)
        #expect(store.write(paths: [], expectedRevision: migrated.revision, widgets: widgetCombinations[0]) ==
                .rejected(ConfigurationWriteFailure(rejection: .state(.unrepresentable), stateAfterFailure: nil)))
        #expect(readBytes(at: store.configurationPath) == committed)
        #expect(!store.load().writable)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func snapshotSurvivesLaterSavesAndMigrationIsIdempotent() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let source = try appDocument(count: 6).v1
        let store = ConfigurationStore(directory: directory)
        let original = [UInt8](try ConfigurationEncoder.encode(source))
        try writeBytes(original, to: store.configurationPath)
        let beforeRevision = ConfigurationStore.revision(for: store.classify())
        let migrated = store.load()
        #expect(migrated.status == .migrated)
        #expect(migrated.revision == beforeRevision)
        #expect(migrated.selected?.count == 6)
        let bytes = readBytes(at: store.configurationPath)
        #expect(store.load().status == .v2)
        #expect(readBytes(at: store.configurationPath) == bytes)
        var revision = migrated.revision
        for flags in widgetCombinations {
            guard case .saved(let saved) = store.write(paths: nil, expectedRevision: revision, widgets: flags) else {
                Issue.record("save failed"); return
            }
            revision = saved.revision
        }
        #expect(readBytes(at: storePath(directory, ConfigurationStore.v1SnapshotName)) == original)
        #expect(readBytes(at: store.backupPath) != original)
    }

    @Test func failedMigrationRestoresOriginalV1AndPreservesSnapshot() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let source = try appDocument(count: 6).v1
        let original = [UInt8](try ConfigurationEncoder.encode(source))
        try writeBytes(original, to: storePath(directory, ConfigurationStore.configurationName))
        var operations = ConfigurationFileOperations.live
        let live = operations
        let once = OneShot()
        operations.readForVerification = { path, limit in
            if path.hasSuffix("/config.json") && once.consume() { return .bytes(Array("broken".utf8)) }
            return live.readForVerification(path, limit)
        }
        let store = ConfigurationStore(directory: directory, operations: operations)
        let read = store.load()
        #expect(read.status == .legacyPending)
        #expect(read.selected?.count == 6)
        #expect(readBytes(at: store.configurationPath) == original)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.v1SnapshotName)) == original)
        #expect(leftoverTemporaries(directory).isEmpty)
        #expect(ConfigurationStore(directory: directory).load().status == .migrated)
    }

    @Test func snapshotFailureRefusesPromotionWithoutOverwritingEvidence() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let original = [UInt8](try ConfigurationEncoder.encode(appDocument(count: 6).v1))
        try writeBytes(original, to: store.configurationPath)
        let snapshot = storePath(directory, ConfigurationStore.v1SnapshotName)
        try writeText("evidence", to: snapshot)
        let read = store.load()
        #expect(read.status == .legacyPending)
        #expect(readBytes(at: store.configurationPath) == original)
        #expect(readBytes(at: snapshot) == Array("evidence".utf8))
        #expect(store.write(paths: read.selected, expectedRevision: read.revision, widgets: .visible) ==
                .rejected(ConfigurationWriteFailure(rejection: .writeFailed, stateAfterFailure: nil)))
    }

    @Test func validV1ThatCannotFitV2StaysUntouchedAndReadOnly() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        var controls = (1...256).map { index in
            DeckControl(id: ControlID(rawValue: "key-\(index)")!, action: ActionID(rawValue: "future.action")!,
                        parameters: .unmodeled(["data": ""]), presentation: ControlPresentation(title: nil))
        }
        let baseSize = try #require(ConfigurationCanonicalForm.data(DeckConfigurationV1(controls: controls))).count
        var remaining = ConfigurationDecoder.maximumDocumentBytes - 20 - baseSize
        for index in controls.indices {
            let length = min(remaining, ControlParameters.maximumUnmodeledValueBytes)
            controls[index] = DeckControl(id: controls[index].id, action: controls[index].action,
                parameters: .unmodeled(["data": String(repeating: "x", count: length)]),
                presentation: controls[index].presentation)
            remaining -= length
        }
        #expect(remaining == 0)
        let source = DeckConfigurationV1(controls: controls)
        let bytes = try ConfigurationEncoder.encode(source)
        #expect(bytes.count == ConfigurationDecoder.maximumDocumentBytes - 20)
        #expect(ConfigurationMigrator.migrateToV2(source) == .failure(.documentTooLarge))
        let store = ConfigurationStore(directory: directory)
        try writeBytes(Array(bytes), to: store.configurationPath)
        let read = store.load()
        #expect(read.status == .unrepresentable)
        #expect(!read.writable)
        #expect(read.revision != nil)
        #expect(readBytes(at: store.configurationPath) == Array(bytes))
        #expect(!fileExists(storePath(directory, ConfigurationStore.v1SnapshotName)))
    }

    @Test func v1PromotionDoesNotWaitAndAdoptsARacingWriter() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let original = [UInt8](try ConfigurationEncoder.encode(appDocument(count: 6).v1))
        let path = storePath(directory, ConfigurationStore.configurationName)
        try writeBytes(original, to: path)
        var blocked = ConfigurationFileOperations.live
        blocked.lockExclusiveNonblocking = { _ in false }
        let busy = ConfigurationStore(directory: directory, operations: blocked).load()
        #expect(busy.status == .migrating)
        #expect(busy.revision == nil)
        #expect(!busy.writable)
        #expect(busy.selected?.count == 6)
        #expect(readBytes(at: path) == original)

        var racing = ConfigurationFileOperations.live
        let live = racing
        let winner = DeckConfigurationV2(controls: try appDocument(count: 2).controls, widgets: widgetCombinations[0])
        let winnerBytes = try ConfigurationEncoder.encode(winner)
        racing.lockExclusiveNonblocking = { descriptor in
            // Model a different writer committing between classification and acquisition.
            do { try winnerBytes.write(to: URL(fileURLWithPath: path)) } catch { return false }
            return live.lockExclusiveNonblocking(descriptor)
        }
        let adopted = ConfigurationStore(directory: directory, operations: racing).load()
        #expect(adopted.state == .ready(winner))
        #expect(adopted.widgets == widgetCombinations[0])
        #expect(readBytes(at: path) == Array(winnerBytes))
        #expect(!fileExists(storePath(directory, ConfigurationStore.v1SnapshotName)))
    }

    @Test func mixedConcurrentWritesCannotMergePastTheSharedRevision() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let initial = try appDocument(count: 6)
        try seedConfiguration(directory, initial)
        let revision = store.load().revision
        let group = DispatchGroup(), lock = NSLock()
        var successes = 0
        var unexpected: [ConfigurationWriteRejection] = []
        for apps in [true, false] {
            group.enter()
            DispatchQueue.global().async {
                let result = store.write(paths: apps ? ["/Latest.app"] : nil,
                    expectedRevision: revision, widgets: apps ? nil : widgetCombinations[0])
                lock.lock()
                switch result {
                case .saved: successes += 1
                case .rejected(let failure):
                    if failure.rejection != .stale && failure.rejection != .busy { unexpected.append(failure.rejection) }
                }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        #expect(successes == 1)
        #expect(unexpected.isEmpty)
        guard case .ready(let final) = store.load().state else { Issue.record("not ready"); return }
        let appWinner = try appDocumentFrom(paths: ["/Latest.app"])
        #expect((final.controls == initial.controls && final.widgets == widgetCombinations[0]) ||
                (final.controls == appWinner.controls && final.widgets == .visible))
    }

    @Test func widgetChangeInvalidatesAnAppClientsRevisionAndFailedSaveRestoresBothHalves() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, appDocument(count: 6))
        let store = ConfigurationStore(directory: directory)
        let a = store.load(), b = store.load()
        guard case .saved(let saved) = store.write(paths: nil, expectedRevision: a.revision, widgets: widgetCombinations[0]) else {
            Issue.record("widget save failed"); return
        }
        let committed = readBytes(at: store.configurationPath)
        #expect(store.write(paths: ["/Stale.app"], expectedRevision: b.revision) ==
                .rejected(ConfigurationWriteFailure(rejection: .stale, stateAfterFailure: nil)))
        #expect(readBytes(at: store.configurationPath) == committed)
        let faulty = ConfigurationStore(directory: directory, operations: tornWriteOperations(garbage: Array("broken".utf8)))
        guard case .rejected(let failure) = faulty.write(paths: ["/New.app"], expectedRevision: saved.revision, widgets: .visible) else {
            Issue.record("torn save claimed success"); return
        }
        #expect(failure.rejection == .writeFailed)
        #expect(readBytes(at: store.configurationPath) == committed)
        #expect(store.load().widgets == widgetCombinations[0])
        #expect(store.load().selected == saved.selected)
    }
}
