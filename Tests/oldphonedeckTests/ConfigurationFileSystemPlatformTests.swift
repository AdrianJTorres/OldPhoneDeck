import Foundation
import Testing
@testable import oldphonedeck

/// Platform measurements ADR-016 rule 8 requires, and the POSIX properties the store's safety
/// arguments rest on. These are observations of this macOS build rather than assumptions about it:
/// where the design does not depend on an answer, the test records the answer instead of demanding
/// one.
@Suite struct ConfigurationFileSystemPlatformTests {
    @Test func fileSynchronizationSucceedsAndDirectorySynchronizationIsObserved() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try writeText("{}", to: storePath(directory, "probe.json"))

        // Load-bearing: a file-data sync is pre-commit and fatal, so it must actually work here.
        // If this fails, the store cannot commit anything and the durability policy has to be
        // revisited rather than quietly downgraded.
        let temporary = try #require(POSIXConfigurationFile.makeTemporary("probe.tmp-", directory.path))
        #expect(POSIXConfigurationFile.writeTemporary(temporary, [0x7B, 0x7D]))
        #expect(POSIXConfigurationFile.syncTemporary(temporary))
        close(temporary.descriptor)

        // Not load-bearing: a directory sync is post-commit and best-effort, because macOS documents
        // no guarantee that `fsync` on a directory fd persists directory metadata, and `F_FULLFSYNC`
        // on a directory fd returns `EINVAL`. The outcome is observed so the ADR's durability
        // sentence can be amended if a platform ever refuses the call.
        let outcome = POSIXConfigurationFile.syncDirectory(directory.path)
        switch outcome {
        case .synced:
            break
        case .openFailed(let observed), .syncFailed(let observed):
            print("configuration store: directory fsync unavailable on this platform, errno \(observed)")
        }
        // The directory exists, so it must at least be openable; a failure here would mean the
        // best-effort path is not merely unsynced but unreachable.
        #expect(outcome != .openFailed(ENOENT))
        // And the production wrapper swallows whatever happened.
        ConfigurationFileOperations.live.syncDirectory(directory.path)
        #expect(fileExists(storePath(directory, "probe.json")))
    }

    @Test func hardLinksAreSupportedBesideTheDocument() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let source = storePath(directory, ConfigurationStore.configurationName)
        try writeText("{\"version\":1,\"controls\":[]}", to: source)
        let destination = storePath(directory, ConfigurationStore.backupName)

        // Load-bearing: the backup is retained by hard link, which costs one directory entry and no
        // data copy. The copy fallback exists for a filesystem that refuses this.
        #expect(POSIXConfigurationFile.hardLink(source, newPath: destination))
        #expect(fileExists(destination))
        #expect(inode(of: destination) == inode(of: source))
        #expect(readBytes(at: destination) == readBytes(at: source))

        // A second link to the same name fails rather than silently replacing it, which is why the
        // store prepares the backup under a temporary name and renames it into place.
        #expect(!POSIXConfigurationFile.hardLink(source, newPath: destination))
        // And renaming over it succeeds atomically, leaving the original inode untouched.
        let replacement = storePath(directory, "replacement.json")
        try writeText("[]", to: replacement)
        #expect(POSIXConfigurationFile.renameFile(replacement, to: destination))
        #expect(readBytes(at: destination) == [UInt8]("[]".utf8))
        #expect(readBytes(at: source) == [UInt8]("{\"version\":1,\"controls\":[]}".utf8))
    }

    @Test func temporariesAreUniqueExclusivelyCreatedAndRestrictive() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }

        let first = try #require(POSIXConfigurationFile.makeTemporary(
            ConfigurationStore.temporaryPrefix, directory.path))
        let second = try #require(POSIXConfigurationFile.makeTemporary(
            ConfigurationStore.temporaryPrefix, directory.path))
        defer { close(first.descriptor); close(second.descriptor) }

        // `mkstemp` is `O_CREAT|O_EXCL` with a random suffix, so two calls in one process cannot
        // collide and no other process can guess or pre-create the name. A PID-derived name has
        // neither property.
        #expect(first.path != second.path)
        #expect(first.path.hasPrefix(storePath(directory, ConfigurationStore.temporaryPrefix)))
        #expect(fileExists(first.path))
        #expect(fileExists(second.path))

        for temporary in [first, second] {
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue == 0o600)
        }
    }

    @Test func anAbsentFileIsDistinguishedFromAnUnreadableOne() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }

        #expect(POSIXConfigurationFile.readBounded(storePath(directory, "missing.json"), 1024) == .absent)
        // A missing parent directory is also absence: the store creates the directory before it
        // writes, so a fresh `--config-dir` must classify as unconfigured rather than damaged.
        #expect(POSIXConfigurationFile.readBounded(
            storePath(directory, "no-such-directory/config.json"), 1024) == .absent)

        // Absent may be created; unreadable must never be overwritten. Collapsing the two is the
        // defect `ConfigurationInput` exists to remove, and only `ENOENT` means absence — a path
        // whose parent is not a directory cannot be created, so it must not read as absent.
        try writeText("{}", to: storePath(directory, "a-file"))
        #expect(POSIXConfigurationFile.readBounded(
            storePath(directory, "a-file/config.json"), 1024) == .unreadable)
    }

    @Test func aBoundedReadStopsAtTheCapWithoutAllocatingTheFile() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let cap = ConfigurationDecoder.maximumDocumentBytes
        let path = storePath(directory, "large.bin")

        // Exactly at the cap: every byte is returned, because the codec — not the reader — decides
        // what "too large" means.
        try writeBytes([UInt8](repeating: 0x61, count: cap), to: path)
        guard case .bytes(let atCap) = POSIXConfigurationFile.readBounded(path, cap) else {
            Issue.record("a file at the cap was not read")
            return
        }
        #expect(atCap.count == cap)

        // Far over it: the reader stops one byte past the cap, which is all the codec needs to
        // reject the document, and the remaining megabytes are never allocated.
        try writeBytes([UInt8](repeating: 0x61, count: cap * 3), to: path)
        guard case .bytes(let overCap) = POSIXConfigurationFile.readBounded(path, cap) else {
            Issue.record("an oversized file was not read")
            return
        }
        #expect(overCap.count == cap + 1)
    }

    @Test func aSymlinkIsReportedRatherThanFollowed() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let target = storePath(directory, "target.json")
        let link = storePath(directory, "link.json")
        try writeText("[\"/Applications/Safari.app\"]", to: target)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        // `O_NOFOLLOW`: the target's contents must not arrive as though they were the link's, and a
        // write must never be able to reach outside the configuration directory through it.
        #expect(POSIXConfigurationFile.readBounded(link, 1024) == .notRegularFile)
        #expect(POSIXConfigurationFile.readBounded(target, 1024)
            == .bytes([UInt8]("[\"/Applications/Safari.app\"]".utf8)))
    }

    @Test func nonRegularFilesAreReportedAndCannotBlockTheReader() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }

        let subdirectory = storePath(directory, "a-directory.json")
        try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
        #expect(POSIXConfigurationFile.readBounded(subdirectory, 1024) == .notRegularFile)

        // `O_NOFOLLOW` alone is not enough: opening a FIFO read-only blocks until a writer appears,
        // which on the shared HTTP queue would hang the whole deck including camera delivery.
        // `O_NONBLOCK` makes the open return at once and `fstat` identifies the file.
        let fifo = storePath(directory, "a-fifo.json")
        #expect(mkfifo(fifo, 0o600) == 0)
        let started = Date()
        let read = POSIXConfigurationFile.readBounded(fifo, 1024)
        let elapsed = Date().timeIntervalSince(started)
        #expect(read == .notRegularFile)
        #expect(elapsed < 5.0, "opening a FIFO blocked for \(elapsed)s")
    }

    @Test func anUnreadableFileIsReportedRatherThanTreatedAsAbsent() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let path = storePath(directory, "locked.json")
        try writeText("{\"version\":1,\"controls\":[]}", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }

        #expect(POSIXConfigurationFile.readBounded(path, 1024) == .unreadable)
    }

    @Test func anAdvisoryLockIsReleasedWhenItsDescriptorIsClosed() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let path = storePath(directory, ConfigurationStore.lockName)

        let holder = try #require(POSIXConfigurationFile.openLock(path))
        #expect(POSIXConfigurationFile.lockExclusiveNonblocking(holder))
        // A second descriptor in the same process conflicts, exactly as a second process would:
        // `flock` locks belong to the open file description.
        let contender = try #require(POSIXConfigurationFile.openLock(path))
        #expect(!POSIXConfigurationFile.lockExclusiveNonblocking(contender))
        close(contender)
        close(holder)

        // The kernel releases on close, so a crash cannot leave the configuration permanently
        // locked.
        let afterCrash = try #require(POSIXConfigurationFile.openLock(path))
        #expect(POSIXConfigurationFile.lockExclusiveNonblocking(afterCrash))
        close(afterCrash)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }
}
