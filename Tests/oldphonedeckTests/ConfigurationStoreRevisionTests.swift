import Foundation
import Testing
@testable import oldphonedeck

// MARK: - Revision token

@Suite struct ConfigurationStoreRevisionTests {
    @Test func twoReadsWithoutAWritePublishTheSameRevision() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, try appDocument(count: 3))
        let store = ConfigurationStore(directory: directory)

        let first = store.load()
        let second = store.load()
        #expect(first.revision != nil)
        #expect(first.revision == second.revision)
    }

    @Test func aCommitChangesTheRevision() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let before = store.load()

        guard case .saved(let after) = store.write(paths: ["/Applications/Safari.app"],
                                                   expectedRevision: before.revision) else {
            Issue.record("the first save was refused")
            return
        }
        #expect(after.revision != nil)
        #expect(after.revision != before.revision)
        // The save response carries the new token, so a second edit needs no intervening read.
        #expect(after.status == .v1)
        #expect(after.writable)
    }

    /// The property that distinguishes a content fingerprint from a byte fingerprint: migration is
    /// lossless and commits exactly the canonical bytes the pre-migration revision was taken over,
    /// so a client that read the legacy selection is not stale afterwards.
    @Test func migrationDoesNotInvalidateARevisionTakenBeforeIt() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let paths = ["/Applications/Safari.app", "/Applications/Music.app"]
        try seedLegacy(directory, paths)

        let observer = ConfigurationStore(directory: directory)
        let pending = observer.classify()
        guard case .migrationPending = pending.state else {
            Issue.record("the legacy file did not classify as a pending migration")
            return
        }
        let revisionBeforeMigration = try #require(ConfigurationStore.revision(for: pending))

        // Another process commits the migration.
        let migrated = ConfigurationStore(directory: directory).load()
        #expect(migrated.status == .migrated)
        #expect(migrated.revision == revisionBeforeMigration)
        #expect(migrated.selected == paths)

        // The observer's token still describes the document that is there, so its save is accepted
        // rather than refused as stale — nothing it saw was lost.
        let edited = ["/Applications/Safari.app", "/Applications/Xcode.app"]
        guard case .saved(let after) = observer.write(paths: edited,
                                                      expectedRevision: revisionBeforeMigration) else {
            Issue.record("a pre-migration revision was rejected after the migration")
            return
        }
        #expect(after.selected == edited)
        #expect(after.revision != revisionBeforeMigration)
        guard case .ready(let saved) = after.state else {
            Issue.record("the save did not leave a ready document")
            return
        }
        #expect(saved.controls.count == 2)
    }

    @Test func aStaleRevisionIsRefusedAndChangesNothing() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let first = store.load()

        // Browser A reads; browser B saves.
        guard case .saved = store.write(paths: ["/Applications/Safari.app"],
                                        expectedRevision: first.revision) else {
            Issue.record("browser B's save was refused")
            return
        }
        let committedByB = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))

        // Browser A now posts the draft it built from revision `first`.
        let outcome = store.write(paths: ["/Applications/Stale.app"], expectedRevision: first.revision)
        guard case .rejected(let failure) = outcome else {
            Issue.record("a stale revision overwrote a newer document")
            return
        }
        #expect(failure.rejection == .stale)
        #expect(failure.stateAfterFailure == nil)
        #expect(readBytes(at: storePath(directory, ConfigurationStore.configurationName)) == committedByB)
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test(arguments: [nil, ""])
    func aMissingRevisionIsRefusedWithNothingWritten(expected: String?) throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()

        let outcome = store.write(paths: ["/Applications/Safari.app"], expectedRevision: expected)
        #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .missingRevision,
                                                               stateAfterFailure: nil)))
        // An unconfigured deck publishes the empty document's revision, so a refusal here proves the
        // token was checked rather than the state.
        #expect(read.revision != nil)
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        #expect(leftoverTemporaries(directory).isEmpty)
    }

    @Test func aWhitespaceOnlyReformatDoesNotInvalidateARevision() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, try appDocument(count: 2))
        let store = ConfigurationStore(directory: directory)
        let canonical = store.load()

        // The same document, compact: different bytes on disk, identical content.
        let compact = "{\"version\":1,\"controls\":["
            + "{\"id\":\"app-1\",\"action\":\"app.launch\",\"parameters\":{\"path\":\"/Applications/App1.app\"}},"
            + "{\"id\":\"app-2\",\"action\":\"app.launch\",\"parameters\":{\"path\":\"/Applications/App2.app\"}}]}"
        try writeText(compact, to: storePath(directory, ConfigurationStore.configurationName))
        let reformatted = store.load()

        #expect(reformatted.status == .v1)
        #expect(reformatted.revision == canonical.revision)
        #expect(reformatted.selected == canonical.selected)
    }

    @Test func differentContentProducesDifferentRevisions() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)

        let unconfigured = store.load()
        try seedConfiguration(directory, try appDocument(count: 1))
        let oneControl = store.load()
        try seedConfiguration(directory, try appDocument(count: 2))
        let twoControls = store.load()

        #expect(unconfigured.revision != oneControl.revision)
        #expect(oneControl.revision != twoControls.revision)
        #expect(unconfigured.revision != twoControls.revision)
        // A fixed, deterministic token for the one state with no bytes at all.
        #expect(unconfigured.revision == ConfigurationRevision.ofUnconfigured())
    }

    /// The source tag is part of the payload, so the same undecodable bytes in the two files are not
    /// the same revision. Without the tag, a repaired `launcher.json` and a damaged `config.json`
    /// holding identical bytes would be indistinguishable to a client.
    @Test func identicalDamagedBytesInDifferentFilesProduceDifferentRevisions() throws {
        let damaged = "{\"version\":1,\"controls\":[],}"
        let configDirectory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(configDirectory) }
        let legacyDirectory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(legacyDirectory) }
        try writeText(damaged, to: storePath(configDirectory, ConfigurationStore.configurationName))
        try writeText(damaged, to: storePath(legacyDirectory, ConfigurationStore.legacyName))

        let fromConfig = ConfigurationStore(directory: configDirectory).load()
        let fromLegacy = ConfigurationStore(directory: legacyDirectory).load()
        #expect(fromConfig.status == .malformed)
        #expect(fromLegacy.status == .malformed)
        #expect(fromConfig.revision != nil)
        #expect(fromConfig.revision != fromLegacy.revision)
    }

    @Test func aContendedReadPublishesNoRevision() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app"])
        let store = ConfigurationStore(directory: directory)

        var operations = ConfigurationFileOperations.live
        operations.lockExclusiveNonblocking = { _ in false }
        let contended = ConfigurationStore(directory: directory, operations: operations).load()

        #expect(contended.state == .busy)
        #expect(contended.status == .migrating)
        #expect(contended.writable == false)
        // Never publish a token that was not computed under coordination.
        #expect(contended.revision == nil)
        // The selection is still served: the migration has not happened, so the legacy file is
        // still authoritative.
        #expect(contended.selected == ["/Applications/Safari.app"])
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
        // The uncontended store is unaffected.
        #expect(store.load().status == .migrated)
    }
}

// MARK: - Locking

@Suite struct ConfigurationStoreLockingTests {
    /// Holds the real lock from a second file description, which is what another process does.
    /// `flock` locks belong to the open file description, so this also proves two writers inside one
    /// process serialize the same way.
    private func holdingLock(_ store: ConfigurationStore, _ body: () throws -> Void) throws {
        let descriptor = store.lockPath.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
        guard descriptor >= 0 else {
            Issue.record("the lock file could not be opened")
            return
        }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

    @Test func aWriteRefusesRatherThanWaitingForTheLock() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        let read = store.load()

        try holdingLock(store) {
            let started = Date()
            let outcome = store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
            let elapsed = Date().timeIntervalSince(started)
            #expect(outcome == .rejected(ConfigurationWriteFailure(rejection: .busy, stateAfterFailure: nil)))
            // Non-blocking, because this runs on the queue that also carries MJPEG delivery.
            #expect(elapsed < 1.0, "the write waited \(elapsed)s for the lock")
            #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
            #expect(leftoverTemporaries(directory).isEmpty)
        }
        // The lock is released by the kernel, so the next write proceeds.
        #expect(store.write(paths: ["/Applications/Safari.app"], expectedRevision: read.revision)
            != .rejected(ConfigurationWriteFailure(rejection: .busy, stateAfterFailure: nil)))
    }

    @Test func aStoreThatCannotOpenItsLockFileNeverWrites() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedLegacy(directory, ["/Applications/Safari.app"])
        var operations = ConfigurationFileOperations.live
        operations.openLock = { _ in nil }
        let store = ConfigurationStore(directory: directory, operations: operations)

        // Fail closed: a write that cannot be serialized is a write that can lose an update.
        #expect(store.load().status == .migrating)
        #expect(store.write(paths: [], expectedRevision: nil)
            == .rejected(ConfigurationWriteFailure(rejection: .busy, stateAfterFailure: nil)))
        #expect(!fileExists(storePath(directory, ConfigurationStore.configurationName)))
    }

    /// Two stores on two queues over one directory, hammering the migration and the save path. The
    /// invariants are the ones that matter: no failure class that means "the filesystem is now
    /// inconsistent", no torn document, no leaked temporary, and the frozen legacy file untouched.
    @Test func concurrentReadersAndWritersNeverTearTheDocument() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let seededLegacy = try seedLegacy(directory, ["/Applications/Seed.app"])
        let storeA = ConfigurationStore(directory: directory)
        let storeB = ConfigurationStore(directory: directory)
        let queueA = DispatchQueue(label: "concurrency-a")
        let queueB = DispatchQueue(label: "concurrency-b")
        let lock = NSLock()
        var unexpected: [ConfigurationWriteRejection] = []
        var savedDocuments: [[String]] = []
        let group = DispatchGroup()

        for iteration in 0..<24 {
            for (queue, store, prefix) in [(queueA, storeA, "A"), (queueB, storeB, "B")] {
                group.enter()
                queue.async {
                    // A read may migrate, which is the write-on-read path under contention.
                    _ = store.load()
                    let current = store.load()
                    let paths = ["/Applications/\(prefix)\(iteration).app"]
                    switch store.write(paths: paths, expectedRevision: current.revision) {
                    case .saved(let read):
                        lock.lock(); savedDocuments.append(read.selected ?? []); lock.unlock()
                    case .rejected(let failure):
                        // Contention and staleness are the expected outcomes of a race. Anything
                        // else means a commit or recovery went wrong.
                        switch failure.rejection {
                        case .busy, .stale: break
                        default:
                            lock.lock(); unexpected.append(failure.rejection); lock.unlock()
                        }
                        if failure.stateAfterFailure != nil {
                            lock.lock(); unexpected.append(failure.rejection); lock.unlock()
                        }
                    }
                    group.leave()
                }
            }
        }
        group.wait()

        #expect(unexpected.isEmpty, "concurrent writes produced \(unexpected)")
        #expect(savedDocuments.count > 0, "no write succeeded, so nothing was proven")

        // Whatever survived is a complete, decodable document — never a prefix of one.
        let finalBytes = try #require(readBytes(at: storePath(directory, ConfigurationStore.configurationName)))
        guard case .v1(let document) = ConfigurationDecoder.decode(.data(Data(finalBytes))) else {
            Issue.record("the committed document does not decode")
            return
        }
        #expect(document.controls.count <= ConfigurationStorePolicy.maximumAppControls)
        #expect(savedDocuments.contains(document.controls.compactMap {
            if case .appPath(let path) = $0.parameters { return path }
            return nil
        }))
        // The frozen legacy file is byte-identical, and nothing was left behind. A backup may or may
        // not exist: it is created only when a write replaces an existing document, and the first
        // commit here can be the migration, which has no previous generation.
        #expect(readBytes(at: storePath(directory, ConfigurationStore.legacyName)) == seededLegacy)
        #expect(leftoverTemporaries(directory).isEmpty)
        let entries = Set(directoryEntries(directory))
        #expect(entries.isSubset(of: [
            ConfigurationStore.backupName, ConfigurationStore.configurationName,
            ConfigurationStore.legacyName, ConfigurationStore.lockName,
        ]))
        #expect(entries.isSuperset(of: [
            ConfigurationStore.configurationName, ConfigurationStore.legacyName,
            ConfigurationStore.lockName,
        ]))
    }
}
