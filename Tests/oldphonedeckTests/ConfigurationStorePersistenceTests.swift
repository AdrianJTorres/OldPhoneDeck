import Foundation
import Testing
@testable import oldphonedeck

// MARK: - Injection helpers

func inode(of path: String) -> UInt64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
    return number.uint64Value
}

/// Wraps every step in a recorder while delegating to the live implementation, so a test can assert
/// the algorithm's ordering — in particular that the backup is swapped in **before** the document is
/// committed — and not only its outcome.
func recordingOperations(_ recorder: StepRecorder) -> ConfigurationFileOperations {
    var operations = ConfigurationFileOperations.live
    let live = operations
    operations.makeTemporary = { prefix, directory in
        recorder.record("makeTemporary")
        return live.makeTemporary(prefix, directory)
    }
    operations.writeTemporary = { temporary, bytes in
        recorder.record("writeTemporary")
        return live.writeTemporary(temporary, bytes)
    }
    operations.syncTemporary = { temporary in
        recorder.record("syncTemporary")
        return live.syncTemporary(temporary)
    }
    operations.hardLink = { existing, newPath in
        recorder.record("hardLink")
        return live.hardLink(existing, newPath)
    }
    operations.swapBackup = { prepared, backup in
        recorder.record("swapBackup")
        return live.swapBackup(prepared, backup)
    }
    operations.commitDocument = { prepared, destination in
        recorder.record("commitDocument")
        return live.commitDocument(prepared, destination)
    }
    operations.syncDirectory = { path in
        recorder.record("syncDirectory")
        live.syncDirectory(path)
    }
    operations.readForVerification = { path, maximumBytes in
        recorder.record("verify")
        return live.readForVerification(path, maximumBytes)
    }
    operations.restoreDocument = { prepared, destination in
        recorder.record("restoreDocument")
        return live.restoreDocument(prepared, destination)
    }
    return operations
}

/// Models a torn write: the bytes that reach the disk are not the bytes `verifiedData` accepted. The
/// first `writeTemporary` is the document, so only it is corrupted; the recovery temporary written
/// afterwards carries the real base bytes.
func tornWriteOperations(garbage: [UInt8]) -> ConfigurationFileOperations {
    var operations = ConfigurationFileOperations.live
    let live = operations
    let torn = OneShot()
    operations.writeTemporary = { temporary, bytes in
        live.writeTemporary(temporary, torn.consume() ? garbage : bytes)
    }
    return operations
}

// MARK: - Migration on read

@Suite struct ConfigurationStoreMigrationTests {
    @Test func migrationOnReadCommitsAndFreezesTheLegacyFile() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app", "/Applications/Music.app", "/Applications/Xcode.app"]
        let seededLegacy = try seedLegacy(directory, paths)
        let store = ConfigurationStore(directory: directory)

        let read = store.load()
        #expect(read.status == .migrated)
        #expect(read.selected == paths)
        #expect(read.writable)
        #expect(read.revision != nil)

        // The committed document is exactly what a migration produces, and it decodes.
        let committed = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))
        guard case .v1(let document) = ConfigurationDecoder.decode(.data(Data(committed))) else {
            Issue.record("the migrated document does not decode as V1")
            return
        }
        let expectedDocument = try appDocumentFrom(paths: paths)
        #expect(document == expectedDocument)
        #expect(document.controls.map(\.id.rawValue) == ["app-1", "app-2", "app-3"])
        #expect(document.controls.allSatisfy { $0.action == .appLaunch })

        // The legacy file is frozen: byte-identical, still there, never rewritten.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        // An initial migration has no previous generation, so it must not fabricate one.
        #expect(!fileExists(storePath(directory, ConfigurationStore.backupName)))
        #expect(leftoverTemporaries(directory).isEmpty)
        // The lock file is the only other addition.
        #expect(Set(directoryEntries(directory)) == Set([
            ConfigurationStore.configurationName, ConfigurationStore.legacyName,
            ConfigurationStore.lockName,
        ]))
    }

    @Test func aLaterReadReportsTheDocumentNotTheMigration() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app"])
        let store = ConfigurationStore(directory: directory)

        let first = store.load()
        let committed = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))
        let second = store.load()

        #expect(first.status == .migrated)
        #expect(second.status == .v1)
        #expect(second.revision == first.revision)
        #expect(second.selected == first.selected)
        // Idempotent: nothing was rewritten.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == committed)
    }

    @Test func migrationPreservesOrderDuplicatesAndEmptyPaths() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app", "", "/Applications/Safari.app", "/Applications/Music.app"]
        try seedLegacy(directory, paths)

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.status == .migrated)
        // Nothing was filtered, sorted, deduplicated or dropped: a migration that dropped the empty
        // entry would shift every later key.
        #expect(read.selected == paths)
        let committed = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))
        guard case .v1(let document) = ConfigurationDecoder.decode(.data(Data(committed))) else {
            Issue.record("the migrated document does not decode as V1")
            return
        }
        let storedPaths = document.controls.compactMap { control -> String? in
            if case .appPath(let path) = control.parameters { return path }
            return nil
        }
        // Every control is an app path, and the sequence is exactly the legacy sequence.
        #expect(storedPaths.count == document.controls.count)
        #expect(storedPaths == paths)
        #expect(document.controls.map(\.id.rawValue) == ["app-1", "app-2", "app-3", "app-4"])
    }

    /// Two processes classify the same pending migration; the one that reaches the lock second must
    /// adopt the winner's document instead of writing its own.
    @Test func migrationUnderTheLockAdoptsAConcurrentWinner() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app", "/Applications/Music.app"]
        try seedLegacy(directory, paths)
        let competitor = ConfigurationStore(directory: directory)

        var operations = ConfigurationFileOperations.live
        let live = operations
        let raced = OneShot()
        operations.lockExclusiveNonblocking = { descriptor in
            // The competing process commits the migration in the window between this store's
            // classification and its acquisition of the lock.
            if raced.consume() { _ = competitor.load() }
            return live.lockExclusiveNonblocking(descriptor)
        }
        let read = ConfigurationStore(directory: directory, operations: operations).load()

        // It adopted rather than committed, so it reports the document, not a migration.
        #expect(read.status == .v1)
        #expect(read.selected == paths)
        #expect(read.writable)
        let winner = try appDocumentFrom(paths: paths)
        #expect(read.revision == ConfigurationRevision.ofDocument(winner))
    }

    /// BLOCKER 1 regression: the legacy file may change between the initial classification and lock
    /// acquisition. The store must commit the configuration derived from the locked classification,
    /// not the stale one from before the lock.
    @Test func migrationRebindsConfigurationFromLockedClassification() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let oldPaths = ["/Applications/Old.app"]
        let newPaths = ["/Applications/New.app"]
        try seedLegacy(directory, oldPaths)

        var operations = ConfigurationFileOperations.live
        let live = operations
        let acquiredLock = OneShot()
        operations.lockExclusiveNonblocking = { descriptor in
            // Simulate the legacy file changing after classification but before lock acquisition.
            if acquiredLock.consume() {
                // Overwrite the legacy file with new content.
                _ = try? seedLegacy(directory, newPaths)
            }
            return live.lockExclusiveNonblocking(descriptor)
        }

        let read = ConfigurationStore(directory: directory, operations: operations).load()
        // The migration committed the NEW configuration, not the stale one.
        #expect(read.status == .migrated)
        #expect(read.selected == newPaths)
        #expect(read.selected != oldPaths)

        // The committed document is exactly what the new legacy file produces.
        let committed = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))
        guard case .v1(let document) = ConfigurationDecoder.decode(.data(Data(committed))) else {
            Issue.record("the migrated document does not decode as V1")
            return
        }
        let expected = try appDocumentFrom(paths: newPaths)
        #expect(document == expected)
    }

    @Test func anUnrepresentableLegacyFileIsServedReadOnlyAndNeverUpgraded() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        // A legacy array the decoder accepts but migration cannot represent: the codec places no
        // per-entry length limit on a legacy document, while `migrateToV1` mirrors the dispatchable
        // path limit. This is the reachable shape of "valid legacy data that cannot become V1".
        let paths = ["/Applications/Safari.app",
                     String(repeating: "a", count: ConfigurationStorePolicy.maximumEntryBytes + 1),
                     "/Applications/Music.app"]
        let seededLegacy = try seedLegacy(directory, paths)
        let store = ConfigurationStore(directory: directory)

        let read = store.load()
        guard case .legacyUnrepresentable(let served, let error) = read.state else {
            Issue.record("an unrepresentable legacy file was not reported as such: \(read.state)")
            return
        }
        #expect(error == .invalidParameters)
        // The selection is served, not hidden: refusing to upgrade is not a reason to blank the deck.
        #expect(served == paths)
        #expect(read.selected == paths)
        #expect(read.status == .legacyReadonly)
        #expect(!read.writable)

        let outcome = store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .state(.legacyReadonly),
                                                               stateAfterFailure: nil)))
        // Writing one control over a three-entry selection would destroy preserved data, so nothing
        // at all was written.
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    /// A legacy array past the codec's control cap never reaches migration: the corruption guard in
    /// `decode(legacyArray:)` rejects it first, so the store reports damage rather than
    /// `legacy-readonly`, and the selection is not served. That is a consequence of the codec's caps
    /// being applied to both sources, and of this slice not being allowed to change
    /// `Configuration.swift`. Recorded as a finding rather than worked around with a second parser.
    @Test func anOversizedLegacyArrayIsDamagedRatherThanUnrepresentable() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = (1...(ConfigurationDecoder.maximumControlCount + 1)).map { "/Applications/App\($0).app" }
        let seededLegacy = try seedLegacy(directory, paths)
        let store = ConfigurationStore(directory: directory)

        let read = store.load()
        #expect(read.state == .damaged(.legacy, .malformed(.tooManyControls)))
        #expect(read.status == .malformed)
        #expect(read.selected == nil)
        #expect(!read.writable)
        #expect(store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
            == .rejected(ConfigurationWriteFailure(rejection: .state(.malformed), stateAfterFailure: nil)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
    }

    /// A consequence worth stating plainly: a legacy file with more entries than the product has keys
    /// migrates faithfully and then becomes read-only, because the editor would otherwise truncate
    /// it on the next save.
    @Test func anOverLimitLegacyFileMigratesAndBecomesReadOnly() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = (1...8).map { "/Applications/App\($0).app" }
        let seededLegacy = try seedLegacy(directory, paths)

        let read = ConfigurationStore(directory: directory).load()
        #expect(read.status == .tooManyControls)
        #expect(read.selected == paths)
        #expect(!read.writable)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
    }

    /// BLOCKER 2 regression: when migration of an eight-entry legacy fails, a subsequent save of
    /// seven entries must be refused, and all eight entries must remain intact in the legacy file.
    @Test func overLimitMigrationFailurePreservesAllEntries() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let eightPaths = (1...8).map { "/Applications/App\($0).app" }
        let seededLegacy = try seedLegacy(directory, eightPaths)

        var operations = ConfigurationFileOperations.live
        operations.commitDocument = { _, _ in false }

        let store = ConfigurationStore(directory: directory, operations: operations)
        let read = store.load()
        // The migration failed pre-commit, so the state is still migration-pending with eight
        // controls, and it must be read-only.
        #expect(read.status == .tooManyControls)
        #expect(read.selected == eightPaths)
        #expect(!read.writable)

        // A save of seven entries must be refused: it would discard the eighth.
        let sevenPaths = Array(eightPaths.prefix(7))
        let outcome = store.write(paths: sevenPaths, expectedRevision: read.revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("an over-limit pending migration accepted a truncating save")
            return
        }
        #expect(failure.rejection == .state(.tooManyControls))

        // All eight entries remain intact in the legacy file.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aMigrationThatCannotCommitLeavesTheLegacyFileAuthoritative() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app"]
        let seededLegacy = try seedLegacy(directory, paths)
        var operations = ConfigurationFileOperations.live
        operations.commitDocument = { _, _ in false }

        let read = ConfigurationStore(directory: directory, operations: operations).load()
        // Pre-commit failure: nothing became visible, so the legacy selection is still the truth and
        // a later read will try again.
        #expect(read.status == .legacyPending)
        #expect(read.selected == paths)
        #expect(read.writable)
        #expect(read.revision != nil)
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    /// A failed post-commit verification of an initial migration must never be reported as a
    /// successful migration, and must never delete the only generation that exists.
    @Test func aFailedInitialMigrationIsCorruptAndNeverMigrated() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app", "/Applications/Music.app"]
        let seededLegacy = try seedLegacy(directory, paths)

        let read = ConfigurationStore(directory: directory,
                                      operations: tornWriteOperations(garbage: [0x7B, 0x2C])).load()
        #expect(read.status == .corrupt)
        #expect(read.status != .migrated)
        #expect(read.selected == nil)
        #expect(!read.writable)
        // Retained as evidence rather than cleaned up: deleting it would destroy the only record of
        // what went wrong.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == [0x7B, 0x2C])
        #expect(!fileExists(storePath(directory, ConfigurationStore.backupName)))
        // The frozen legacy file is untouched, which is what makes the documented manual recovery —
        // remove the damaged `config.json` and read again — lossless.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        #expect(leftoverTemporaries(directory).isEmpty)

        // And the recovery the documentation promises actually works.
        try FileManager.default.removeItem(atPath: storePath(directory, ConfigurationStore.configurationName))
        let recovered = ConfigurationStore(directory: directory).load()
        #expect(recovered.status == .migrated)
        #expect(recovered.selected == paths)
    }

    @Test func noStoreReadsOrWritesAFileItWasNotPointedAt() throws {
        // The directory is injected, so a store aimed at a temporary directory cannot reach
        // `~/.oldphonedeck`. This is the isolation the whole slice depends on, and the reason
        // `NSHomeDirectory()` appears nowhere in `ConfigurationStore.swift`.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app"])
        let store = ConfigurationStore(directory: directory)
        _ = store.load()

        // Assert only on the injected directory: the store created files where it was pointed,
        // not in any real user configuration directory.
        #expect(fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(fileExists(storePath(directory, ConfigurationStore.lockName)))
    }
}

// MARK: - Writing

@Suite struct ConfigurationStoreWriteTests {
    @Test func aSaveReplacesTheDocumentAndRetainsThePreviousGeneration() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let base = try appDocument(count: 2)
        let baseBytes = try seedConfiguration(directory, base)
        let baseInode = try #require(inode(of: storePath(directory, ConfigurationStore.configurationName)))
        let store = ConfigurationStore(directory: directory)
        let read = store.load()

        let paths = ["/Applications/Safari.app", "/Applications/Music.app", "/Applications/Xcode.app"]
        guard case .saved(let after) = store.write(paths: paths, expectedRevision: read.revision) else {
            Issue.record("a valid save was refused")
            return
        }
        #expect(after.selected == paths)
        #expect(after.status == .v1)
        #expect(after.writable)
        #expect(after.revision != read.revision)

        // The response is the complete read shape, so a client can replace its state wholesale.
        #expect(store.load().revision == after.revision)

        // The backup holds exactly the base generation, and holds it by hard link: same inode, no
        // data copied, safe because writes never mutate in place.
        let backup = storePath(directory, ConfigurationStore.backupName)
        #expect(readBytes(at: backup) == baseBytes)
        #expect(inode(of: backup) == baseInode)
        #expect(inode(of: storePath(directory, ConfigurationStore.configurationName)) != baseInode)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func theBackupIsSwappedBeforeTheDocumentIsCommitted() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, try appDocument(count: 1))
        let recorder = StepRecorder()
        let store = ConfigurationStore(directory: directory, operations: recordingOperations(recorder))
        let read = store.load()

        _ = store.write(paths: ["/Applications/Safari.app", "/Applications/Music.app"],
                        expectedRevision: read.revision)
        let steps = recorder.steps
        let backup = steps.firstIndex(of: "swapBackup")
        let commit = steps.firstIndex(of: "commitDocument")
        let verify = steps.firstIndex(of: "verify")
        let sync = steps.firstIndex(of: "syncTemporary")

        #expect(sync != nil)
        #expect(backup != nil)
        #expect(commit != nil)
        #expect(verify != nil)
        // The ordering ADR-016 rule 9 requires: prepared and synced, backup swapped, then committed,
        // then verified. Committing first would leave a window in which the backup is a generation
        // behind the document recovery would need to restore.
        if let sync, let backup, let commit, let verify {
            #expect(sync < backup)
            #expect(backup < commit)
            #expect(commit < verify)
        }
    }

    @Test(arguments: [
        ([String](), "an empty selection"),
        ([""], "one empty path"),
        (["", ""], "two empty paths"),
        (["/Applications/Safari.app", ""], "a trailing empty path"),
        (["", "/Applications/Safari.app"], "a leading empty path"),
        (["/Applications/Safari.app", "/Applications/Safari.app"], "a duplicate path"),
        (["/Applications/Safari.app", "", "/Applications/Music.app", ""], "mixed empties"),
    ])
    func aSavePreservesTheSelectionExactly(_ paths: [String], _ label: String) throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()

        guard case .saved(let after) = store.write(paths: paths, expectedRevision: read.revision) else {
            Issue.record("\(label) was refused")
            return
        }
        #expect(after.selected == paths, "\(label) did not round-trip through the write")
        // And it survives a fresh classification, which is the claim that matters: the bytes on disk
        // hold what the client sent.
        let reloaded = ConfigurationStore(directory: directory).load()
        #expect(reloaded.selected == paths, "\(label) did not survive a reload")
        #expect(reloaded.status == .v1)
        #expect(reloaded.writable)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aSaveRefusesMoreEntriesThanTheProductHasKeys() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        let paths = (1...8).map { "/Applications/App\($0).app" }

        let outcome = store.write(paths: paths, expectedRevision: read.revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .tooManyKeys, stateAfterFailure: nil)))
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aSaveRefusesAnOverlongEntryAndAcceptsOneAtTheLimit() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        let limit = ConfigurationStorePolicy.maximumEntryBytes

        let overlong = store.write(paths: [String(repeating: "a", count: limit + 1)],
                                   expectedRevision: read.revision)
        #expect(overlong == .rejected(ConfigurationWriteFailure(rejection: .entryTooLong,
                                                                stateAfterFailure: nil)))
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))

        // At the limit it is accepted, and still only data: `ActionRegistry.dispatch` re-validates
        // and re-authorizes against the Mac's own catalog regardless of what was stored.
        guard case .saved = store.write(paths: [String(repeating: "a", count: limit)],
                                        expectedRevision: read.revision) else {
            Issue.record("an entry at the documented limit was refused")
            return
        }
    }

    @Test func aSaveFromAnUnconfiguredDeckCreatesNoBackup() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        #expect(read.status == .unconfigured)

        guard case .saved = store.write(paths: ["/Applications/Safari.app"],
                                        expectedRevision: read.revision) else {
            Issue.record("the first save was refused")
            return
        }
        // There is no previous generation, and fabricating one would make a later recovery restore
        // something that never existed.
        #expect(!fileExists(storePath(directory, ConfigurationStore.backupName)))
        #expect(fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aSaveIsRefusedWhenTheDocumentCannotBeProjected() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        var controls = try appDocument(count: 2).controls
        controls[0] = DeckControl(id: controls[0].id, action: .appLaunch,
                                  parameters: .appPath("/Applications/App1.app"),
                                  presentation: ControlPresentation(title: "Browser"))
        let seeded = try seedConfiguration(directory, DeckConfigurationV1(controls: controls))
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        #expect(read.status == .unrepresentable)

        // `paths=` cannot express a title, so a save would destroy what the page could not show.
        let outcome = store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .state(.unrepresentable),
                                                               stateAfterFailure: nil)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == seeded)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aSaveCreatesTheDirectoryWhenItDoesNotExist() throws {
        let parent = try temporaryStoreDirectory()
        defer { removeStoreDirectory(parent) }
        let directory = parent.appendingPathComponent("nested/config")
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        #expect(read.status == .unconfigured)

        guard case .saved = store.write(paths: ["/Applications/Safari.app"],
                                        expectedRevision: read.revision) else {
            Issue.record("a save into a missing directory was refused")
            return
        }
        #expect(fileExists(storePath(directory, ConfigurationStore.configurationName)))
        // Created `0700`, because it will hold a copied TLS identity under `--config-dir`.
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o700)
    }

    @Test func aCommittedDocumentIsWrittenWithRestrictivePermissions() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        guard case .saved = store.write(paths: ["/Applications/Safari.app"],
                                        expectedRevision: read.revision) else {
            Issue.record("the save was refused")
            return
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storePath(directory, ConfigurationStore.configurationName))
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    /// MINOR 2 regression: a symlinked lock file must be rejected, and the target's mode must be
    /// unchanged. `O_NOFOLLOW` stops the open, and the `fstat` check rejects any non-regular file.
    @Test func aSymlinkedLockFileIsRejectedAndTargetModeUnchanged() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        // Create a real file that the symlink will point to.
        let target = storePath(directory, "lock-target")
        try writeText("target", to: target)
        // Symlink the lock path to the target.
        let lockPath = storePath(directory, ConfigurationStore.lockName)
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: target)

        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        #expect(read.status == .unconfigured)

        // The write must fail because the lock cannot be acquired through a symlink.
        let outcome = store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("a symlinked lock file accepted a write")
            return
        }
        #expect(failure.rejection == .busy)

        // The target file's mode is unchanged: the store never operated on it.
        let attributes = try FileManager.default.attributesOfItem(atPath: target)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        // Default permissions from writeText, not 0o600 from fchmod. The store never reached
        // the target because O_NOFOLLOW rejected the symlink.
        #expect(permissions.intValue != 0o600)
    }
}

// MARK: - Failure injection

@Suite struct ConfigurationStoreFailureInjectionTests {
    /// A base document plus a previous generation, which is the state most failure rows need.
    private func seededWithBackup() throws -> (URL, ConfigurationStore, [UInt8], [UInt8], String) {
        let directory = try temporaryStoreDirectory()
        let store = ConfigurationStore(directory: directory)
        let older = try seedConfiguration(directory, try appDocument(count: 1))
        let firstRevision = try #require(store.load().revision)
        guard case .saved = store.write(paths: ["/Applications/App1.app", "/Applications/App2.app"],
                                        expectedRevision: firstRevision) else {
            throw FixtureError(message: "the seeding save was refused")
        }
        let base = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))
        let backup = try #require(readBytes(at: storePath(directory, ConfigurationStore.backupName)))
        #expect(backup == older)
        let revision = try #require(store.load().revision)
        return (directory, store, base, older, revision)
    }

    @Test func aFailedTemporaryCreationChangesNothing() throws {
        let (directory, store, base, older, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        operations.makeTemporary = { _, _ in nil }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Changed.app"], expectedRevision: revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .writeFailed, stateAfterFailure: nil)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == older)
        #expect(leftoverTemporaries(directory).isEmpty)
        #expect(store.load().revision == revision)
    }

    @Test func aFailedTemporaryWriteOrSyncUnlinksTheTemporary() throws {
        for failSync in [false, true] {
            let (directory, store, base, older, revision) = try seededWithBackup()
            defer { removeStoreDirectory(directory) }
            var operations = ConfigurationFileOperations.live
            if failSync {
                operations.syncTemporary = { _ in false }
            } else {
                operations.writeTemporary = { _, _ in false }
            }

            let outcome = ConfigurationStore(directory: directory, operations: operations)
                .write(paths: ["/Applications/Changed.app"], expectedRevision: revision)
            #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .writeFailed,
                                                                   stateAfterFailure: nil)))
            // Pre-commit, so both generations are exactly as they were and nothing leaked.
            #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
            #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == older)
            #expect(leftoverTemporaries(directory).isEmpty)
            #expect(store.load().revision == revision)
        }
    }

    /// The defect Steering named: unlinking the old backup before creating the new one destroys a
    /// good generation when the replacement fails. The backup is now prepared under a temporary name
    /// and swapped in, so a failure here leaves it byte-identical.
    @Test func aFailedBackupCreationLeavesTheExistingBackupIntact() throws {
        let (directory, store, base, older, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        operations.hardLink = { _, _ in false }
        // The copy fallback also has to fail, or it would simply succeed by another route.
        operations.makeTemporary = { prefix, directory in
            prefix == ConfigurationStore.backupTemporaryPrefix
                ? nil
                : ConfigurationFileOperations.live.makeTemporary(prefix, directory)
        }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Changed.app"], expectedRevision: revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .writeFailed, stateAfterFailure: nil)))
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == older)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(leftoverTemporaries(directory).isEmpty)
        #expect(store.load().revision == revision)
    }

    @Test func aFilesystemThatWillNotLinkFallsBackToCopyingTheBackup() throws {
        let (directory, _, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        operations.hardLink = { _, _ in false }

        guard case .saved = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Copied.app"], expectedRevision: revision) else {
            Issue.record("the copy fallback did not save")
            return
        }
        // The backup holds the base bytes by copy rather than by inode.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == base)
        #expect(inode(of: storePath(directory, ConfigurationStore.backupName))
            != inode(of: storePath(directory, ConfigurationStore.configurationName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aFailedBackupSwapCommitsNothing() throws {
        let (directory, store, base, older, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        operations.swapBackup = { _, _ in false }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Changed.app"], expectedRevision: revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .writeFailed, stateAfterFailure: nil)))
        // Nothing became visible, and the backup still holds the older generation rather than a
        // half-prepared one.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == older)
        #expect(leftoverTemporaries(directory).isEmpty)
        #expect(store.load().revision == revision)
    }

    @Test func aFailedCommitLeavesTheBaseDocumentAndADuplicateBackup() throws {
        let (directory, store, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        operations.commitDocument = { _, _ in false }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Changed.app"], expectedRevision: revision)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .writeFailed, stateAfterFailure: nil)))
        // The backup was already swapped, so it now duplicates the base. That is the disclosed cost
        // of swapping first: degraded backup freshness, never data loss.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == base)
        #expect(leftoverTemporaries(directory).isEmpty)
        #expect(store.load().revision == revision)
    }

    @Test func aDirectorySyncFailureNeverFailsASave() throws {
        let (directory, _, _, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        var attempts = 0
        // Best-effort by contract: the rename has already happened, and undoing it would be worse
        // than an unsynced directory entry.
        operations.syncDirectory = { _ in attempts += 1 }

        guard case .saved = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Synced.app"], expectedRevision: revision) else {
            Issue.record("a directory sync failure was treated as a failed save")
            return
        }
        #expect(attempts > 0)
        #expect(ConfigurationStore(directory: directory).load().selected == ["/Applications/Synced.app"])
    }

    @Test func aTornCommitIsUndoneFromTheBaseCapturedUnderTheLock() throws {
        let (directory, store, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }

        let outcome = ConfigurationStore(directory: directory, operations: tornWriteOperations(garbage: [0x7B, 0x2C]))
            .write(paths: ["/Applications/Torn.app"], expectedRevision: revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("a torn commit was reported as saved")
            return
        }
        // Post-commit failure with a successful recovery: reported as a failed write, and the state
        // served afterwards is the restored base generation.
        #expect(failure.rejection == .writeFailed)
        #expect(failure.stateAfterFailure?.status == .v1)
        #expect(failure.stateAfterFailure?.writable == true)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == base)
        #expect(leftoverTemporaries(directory).isEmpty)

        let after = store.load()
        #expect(after.status == .v1)
        #expect(after.revision == revision)
        #expect(after.selected == ["/Applications/App1.app", "/Applications/App2.app"])
    }

    @Test func postCommitVerificationActuallyRuns() throws {
        let (directory, store, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = ConfigurationFileOperations.live
        let live = operations
        let firstVerification = OneShot()
        // The document on disk is fine; only the first verification read is made to disagree, so the
        // recovery that follows can be verified by the real implementation. If the verification step
        // were removed, this write would report success and the test would fail.
        operations.readForVerification = { path, maximumBytes in
            firstVerification.consume()
                ? .bytes([0x5B, 0x5D])
                : live.readForVerification(path, maximumBytes)
        }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Unverified.app"], expectedRevision: revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("a commit that could not be verified was reported as saved")
            return
        }
        #expect(failure.rejection == .writeFailed)
        #expect(failure.stateAfterFailure?.status == .v1)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(store.load().revision == revision)
    }

    @Test func aFailedRestorationKeepsTheDamagedDocumentAndTheBaseGeneration() throws {
        let (directory, store, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = tornWriteOperations(garbage: [0x7B, 0x2C])
        operations.restoreDocument = { _, _ in false }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Unrecoverable.app"], expectedRevision: revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("an unrecoverable commit was reported as saved")
            return
        }
        #expect(failure.rejection == .recoveryFailed)
        #expect(failure.stateAfterFailure?.status == .corrupt)
        #expect(failure.stateAfterFailure?.writable == false)
        // Neither file is deleted: the damaged document is the evidence and the backup is the
        // recovery, and choosing between them is the operator's decision. The backup holds the base
        // generation — the one the client's revision described — because the swap at C1 ran before
        // the commit at C2.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == [0x7B, 0x2C])
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == base)
        #expect(leftoverTemporaries(directory).isEmpty)
        // And the damage is visible to the next reader rather than papered over.
        let after = store.load()
        #expect(after.status == .malformed)
        #expect(!after.writable)
        #expect(after.selected == nil)
    }

    @Test func aFailedRestorationVerificationIsNotReportedAsRecovered() throws {
        let (directory, _, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = tornWriteOperations(garbage: [0x7B, 0x2C])
        // The restore lands, but the restored document cannot be verified either.
        operations.readForVerification = { path, _ in
            path.hasSuffix(ConfigurationStore.configurationName) ? .bytes([0x5B, 0x5D]) : .absent
        }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Unverifiable.app"], expectedRevision: revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("an unverifiable recovery was reported as saved")
            return
        }
        #expect(failure.rejection == .recoveryFailed)
        #expect(failure.stateAfterFailure?.status == .corrupt)
        #expect(failure.stateAfterFailure?.writable == false)
        // The base was written back even though it could not be verified, and the backup still holds
        // it: nothing was deleted on the strength of an unproven recovery, and a recovery that is
        // not verified is not reported as one.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == base)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == base)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    /// MINOR 1 regression: a failed recovery write must close the temporary file descriptor and
    /// unlink the temporary file, not leak either.
    @Test func aFailedRecoveryWriteClosesDescriptorAndUnlinksTemporary() throws {
        let (directory, _, base, _, revision) = try seededWithBackup()
        defer { removeStoreDirectory(directory) }
        var operations = tornWriteOperations(garbage: [0x7B, 0x2C])
        let live = operations
        // Fail the recovery write: the first writeTemporary is the document (torn), the second is
        // the recovery temporary. Make the second one fail.
        let documentWriteDone = OneShot()
        operations.writeTemporary = { temporary, bytes in
            if documentWriteDone.consume() {
                // First call: the torn document write.
                return live.writeTemporary(temporary, bytes)
            }
            // Second call: the recovery write. Fail it.
            return false
        }
        // Record closeTemporary calls to prove the descriptor was closed on the failed recovery.
        let closeCount = NSLock()
        var closes = 0
        let liveClose = operations.closeTemporary
        operations.closeTemporary = { temporary in
            closeCount.lock(); closes += 1; closeCount.unlock()
            liveClose(temporary)
        }

        let outcome = ConfigurationStore(directory: directory, operations: operations)
            .write(paths: ["/Applications/Unrecoverable.app"], expectedRevision: revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("a failed recovery write was reported as saved")
            return
        }
        #expect(failure.rejection == .recoveryFailed)
        // The recovery temporary's descriptor was closed: the failed write path did not leak it.
        closeCount.lock(); let finalCloses = closes; closeCount.unlock()
        #expect(finalCloses >= 2, "expected at least 2 closeTemporary calls (document + recovery)")
        // No temporary file was left behind: the failed recovery cleaned up after itself.
        #expect(leftoverTemporaries(directory).isEmpty)
        // The damaged document is still there (evidence), and the backup is intact.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == [0x7B, 0x2C])
        #expect(readBytes(at: storePath(directory, ConfigurationStore.backupName)) == base)
    }

    @Test func noFailurePathLeavesATemporaryBehind() throws {
        // Every row above asserts an empty temporary set; this one exercises them in sequence over
        // one directory to prove the cleanups compose rather than each working only in isolation.
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()
        _ = store.write(paths: ["/Applications/First.app"], expectedRevision: read.revision)
        let revision = try #require(store.load().revision)

        let injections: [(inout ConfigurationFileOperations) -> Void] = [
            { operations in operations.commitDocument = { _, _ in false } },
            { operations in operations.swapBackup = { _, _ in false } },
            { operations in operations.syncTemporary = { _ in false } },
            { operations in operations.writeTemporary = { _, _ in false } },
            { operations in operations.makeTemporary = { _, _ in nil } },
        ]
        for inject in injections {
            var operations = ConfigurationFileOperations.live
            inject(&operations)
            let outcome = ConfigurationStore(directory: directory, operations: operations)
                .write(paths: ["/Applications/Never.app"], expectedRevision: revision)
            guard case .rejected(let failure) = outcome else {
                Issue.record("an injected failure was reported as a save")
                return
            }
            #expect(failure.rejection == .writeFailed)
            #expect(failure.stateAfterFailure == nil)
            #expect(leftoverTemporaries(directory).isEmpty)
        }
        // The document is still the one that was there before the failed attempts, and the revision
        // that describes it is still the one the client holds.
        #expect(store.load().selected == ["/Applications/First.app"])
        #expect(store.load().revision == revision)
    }
}
