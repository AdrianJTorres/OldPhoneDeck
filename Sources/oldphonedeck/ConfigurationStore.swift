import Foundation

/// Configuration storage (M2.5 S1, ADR-016): the layer that gives the M2.4 codec a file to live in.
///
/// This file owns every byte that reaches or leaves `config.json` and `launcher.json`. It is the
/// only place in the product that decides what a configuration file is allowed to be, when a
/// document may be replaced, and what happens when a replacement cannot be completed. The codec in
/// `Configuration.swift` is untouched and stays pure: this store supplies its `ConfigurationInput`
/// and consumes its `ConfigurationState`, and adds the two things a codec deliberately cannot know
/// — which file a document came from, and what the filesystem did.
///
/// **This slice is unwired.** Nothing in `main.swift`, `Control.swift` or the HTTP route table
/// calls it, so no endpoint behaviour has changed and no real configuration has been read or
/// written. `Launcher.selected()` and `Launcher.save` remain the runtime path until S3.
///
/// Three rules from ADR-016 shape everything below:
///
/// 1. **Source-aware shapes** (rule 1). `config.json` must hold a V1 object and `launcher.json`
///    must hold a legacy array. The codec reports a bare array as `.legacy` no matter where it came
///    from, so the store — not the codec — decides that an array in `config.json` is `wrongFormat`
///    rather than a document to adopt.
/// 2. **Readers never lock; writers always do** (rules 4–6). `rename(2)` gives atomic visibility, so
///    a read needs no coordination. Every write holds one non-blocking exclusive lock, including a
///    migration triggered by a read, and never waits: the queue this runs on also carries MJPEG
///    delivery.
/// 3. **No silent fallback** (rules 3, 9). A damaged document is reported and left exactly where it
///    is. Nothing here deletes a configuration file, truncates a selection, or substitutes
///    `launcher.json` for a `config.json` it could not understand.

// MARK: - Product policy

/// Writer-side product policy, as distinct from the codec's corruption guards.
///
/// `ConfigurationDecoder.maximumControlCount` stays 4096 because it bounds what untrusted bytes may
/// ask for. This is the number of keys the product has: the client's `APP_SLOTS` in `web/index.html`
/// is the same limit expressed as a rendering loop, and ADR-015 deferred making it a writer-side
/// rule to this milestone.
enum ConfigurationStorePolicy {
    static let maximumAppControls = 7

    /// Mirrors `ControlParameters.maximumPathBytes` and `AppLaunchParameters.maximumPathBytes`, so a
    /// stored path is never longer than a dispatchable one.
    static let maximumEntryBytes = ControlParameters.maximumPathBytes
}

// MARK: - States

/// Which file a state was derived from. Kept separate because the same codec outcome means
/// opposite things depending on the source: an array is the expected shape of `launcher.json` and a
/// wrong shape for `config.json`.
enum ConfigurationSource: Equatable {
    case config
    case legacy
}

/// Why a file that exists could not be used. Finer than the wire vocabulary on purpose: a symlink
/// and a permission failure both report `unreadable` to a client, but they have different repairs,
/// and the distinction matters when deciding whether anything may be written.
enum ConfigurationDamage: Equatable {
    case malformed(ConfigurationError)
    case unsupportedVersion(found: Int)
    /// The file could not be opened or read: a permission failure, an I/O error, or a directory
    /// that does not exist.
    case unreadable
    /// The path exists but is not a regular file — a symlink, a directory, a FIFO or a device.
    /// Never written through and never renamed over.
    case notRegularFile
}

/// Every outcome of looking at the configuration directory, with no two collapsed into one. This is
/// the store-level successor to `Launcher.selected()`'s single `nil`; the codec's
/// `ConfigurationState` describes one file's bytes, while this describes the pair.
enum ConfigurationStoreState: Equatable {
    /// `config.json` holds a V1 document that the current page can show and re-save.
    case ready(DeckConfigurationV1)
    /// A V1 document with more controls than the product has keys. Served in full and read-only:
    /// the editor truncates to `APP_SLOTS` on load, so a save from it would silently discard every
    /// control past the seventh.
    case overLimit(DeckConfigurationV1)
    /// A V1 document that cannot be expressed as a path list at all — a title, a custom or gapped
    /// id, an unregistered action or `.unmodeled` parameters. `selected` is nil, never a subset.
    case unprojectable(DeckConfigurationV1)
    /// Neither file exists. The one state in which there is genuinely nothing to lose.
    case unconfigured
    /// `config.json` is absent and `launcher.json` holds a legacy selection that migrates cleanly.
    /// The document exists in memory and has not been committed yet.
    case migrationPending(DeckConfigurationV1, [String])
    /// `launcher.json` is valid legacy data that cannot be represented as V1. Its selection is
    /// still served — hiding it would be worse than refusing to upgrade it — but nothing may be
    /// written, because writing seven controls over it would destroy preserved data.
    case legacyUnrepresentable([String], ConfigurationError)
    case damaged(ConfigurationSource, ConfigurationDamage)
    /// A well-formed document in the wrong file. Reported, never adopted: adopting a legacy array
    /// found in `config.json` would create two sources of legacy truth with no defined precedence
    /// when both files hold arrays.
    case wrongFormat(ConfigurationSource)
    /// Another process holds the write lock. A per-response state, never persisted.
    case busy
}

/// The fixed, server-authored status vocabulary published as `configuration` on the wire and reused
/// as the body of a refused `POST`. One table, two uses, and no token carries document content —
/// the same rule `ConfigurationError` follows.
enum ConfigurationStatusToken: String, Equatable {
    case v1
    case migrated
    case migrating
    case legacyPending = "legacy-pending"
    case unconfigured
    case unrepresentable
    case tooManyControls = "too-many-controls"
    case legacyReadonly = "legacy-readonly"
    case malformed
    case unsupportedVersion = "unsupported-version"
    case unreadable
    case wrongFormat = "wrong-format"
    case corrupt
}

/// What a configuration read yields: everything a route needs to answer, and nothing it has to
/// decide for itself. `writable` is a prediction — the server re-checks every condition under the
/// lock — and `revision` is absent whenever the store could not classify under coordination.
struct ConfigurationRead: Equatable {
    let state: ConfigurationStoreState
    let selected: [String]?
    let status: ConfigurationStatusToken
    /// Non-nil only for `.unsupportedVersion`, where the integer is the diagnosis.
    let version: Int?
    let writable: Bool
    let revision: String?
}

// MARK: - Revision

/// An opaque fingerprint of the configuration **content** a client observed.
///
/// This is a concurrency control, not an integrity or authentication control: a client holding the
/// access token can always read a fresh revision and then write anything it likes. It exists to stop
/// an accidental stale overwrite, which is the same job an `If-Match` ETag does in a single-user
/// application — so it is a 64-bit non-cryptographic fingerprint rather than a digest, and no
/// framework is added for it.
///
/// The payload is the *canonical* V1 form for any state that has one, which gives two properties
/// that a fingerprint of the file's raw bytes would not. A whitespace-only hand edit does not
/// invalidate a client, because the content is unchanged. And **migration does not invalidate a
/// client either**, because `ConfigurationEncoder.verifiedData` returns
/// `ConfigurationCanonicalForm.data(configuration)` unchanged, so the bytes a migration commits are
/// byte-identical to the bytes this fingerprinted beforehand.
enum ConfigurationRevision {
    /// A state with a V1 denotation: the canonical encoding of the document.
    static let versionedTag: UInt8 = 0x76   // 'v'
    /// Raw bytes of `config.json`, for a document that could not be decoded.
    static let configTag: UInt8 = 0x63      // 'c'
    /// Raw bytes of `launcher.json`, for a legacy source that could not be used.
    static let legacyTag: UInt8 = 0x6C      // 'l'

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// nil when the value cannot be encoded canonically, which cannot happen for a document the
    /// decoder just accepted. A missing revision means read-only, never "any revision accepted".
    static func ofDocument(_ configuration: DeckConfigurationV1) -> String? {
        guard let data = ConfigurationCanonicalForm.data(configuration) else { return nil }
        return fingerprint(tag: versionedTag, payload: [UInt8](data))
    }

    /// The empty V1 document is the denotation of `.unconfigured`, so a client that reads an
    /// unconfigured deck and then saves an empty selection is not writing over anything.
    static func ofUnconfigured() -> String? { ofDocument(DeckConfigurationV1(controls: [])) }

    static func ofRawBytes(tag: UInt8, _ bytes: [UInt8]?) -> String {
        fingerprint(tag: tag, payload: bytes ?? [])
    }

    static func fingerprint(tag: UInt8, payload: [UInt8]) -> String {
        var hash = offsetBasis
        hash = (hash ^ UInt64(tag)) &* prime
        for byte in payload { hash = (hash ^ UInt64(byte)) &* prime }
        // Fixed width so the token is always 16 characters and a short hash cannot be confused
        // with a differently shaped one.
        let text = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - text.count) + text
    }
}

// MARK: - Filesystem seam

/// What came back from an attempt to read one file. Absence and unreadability stay apart because
/// they demand opposite responses: an absent document may be created, an unreadable one must never
/// be overwritten.
enum ConfigurationFileRead: Equatable {
    case absent
    case unreadable
    /// The path exists but is not a regular file. Reported separately from `.unreadable` because
    /// the file may be perfectly readable and still must not be written through or renamed over.
    case notRegularFile
    case bytes([UInt8])

    /// The codec's own input vocabulary. A non-regular file collapses to `.unreadable` here — the
    /// distinction the store needs has already been taken.
    var codecInput: ConfigurationInput {
        switch self {
        case .absent: return .absent
        case .unreadable, .notRegularFile: return .unreadable
        case .bytes(let bytes): return .data(Data(bytes))
        }
    }
}

/// An open temporary file. The descriptor is owned by whoever created it and is closed exactly once,
/// on every path.
struct ConfigurationTemporaryFile: Equatable {
    let path: String
    let descriptor: Int32
}

/// The observed outcome of syncing a directory, for the measurement ADR-016 rule 8 requires.
///
/// macOS documents no guarantee that `fsync` on a directory fd persists directory metadata, and
/// `F_FULLFSYNC` on a directory fd returns `EINVAL`. The production path therefore treats a
/// directory sync as best-effort and never fails a save for it; this type exists so a test can
/// record what the platform actually did instead of the design assuming it.
enum DirectorySyncOutcome: Equatable {
    case openFailed(Int32)
    case syncFailed(Int32)
    case synced
}

/// Every filesystem operation the store performs, as one closure per **algorithm step** rather than
/// per syscall.
///
/// That granularity is the point. `rename(2)` is used three times — to swap the backup, to commit
/// the document and to restore it — and each has different consequences when it fails, so a seam
/// keyed on the syscall could not express "fail the commit but not the backup". Naming the steps
/// lets a test fail exactly one of them, deterministically, without filling a volume or pulling the
/// plug. It follows the injecting-initializer idiom `ActionRegistry` and `AppLaunchExecutor`
/// established in M2.3, so production behaviour is one value (`.live`) and tests substitute single
/// closures.
struct ConfigurationFileOperations {
    /// Bounded, non-following read of one file.
    var readBounded: (_ path: String, _ maximumBytes: Int) -> ConfigurationFileRead
    /// The post-commit re-read. Separated from `readBounded` so verification can be made to fail
    /// while classification keeps working.
    var readForVerification: (_ path: String, _ maximumBytes: Int) -> ConfigurationFileRead
    var createDirectory: (_ path: String) -> Bool
    /// `mkstemp`: a unique, exclusively created file. Never a PID-derived name.
    var makeTemporary: (_ prefix: String, _ directory: String) -> ConfigurationTemporaryFile?
    var writeTemporary: (_ temporary: ConfigurationTemporaryFile, _ bytes: [UInt8]) -> Bool
    /// Fatal when it fails, because it happens before anything is visible.
    var syncTemporary: (_ temporary: ConfigurationTemporaryFile) -> Bool
    var closeTemporary: (_ temporary: ConfigurationTemporaryFile) -> Void
    var hardLink: (_ existing: String, _ newPath: String) -> Bool
    /// C1: move the prepared backup into place, atomically replacing the previous one.
    var swapBackup: (_ prepared: String, _ backup: String) -> Bool
    /// C2: the atomic replacement that makes the new document visible.
    var commitDocument: (_ prepared: String, _ destination: String) -> Bool
    /// R1: put the base generation back after a failed verification.
    var restoreDocument: (_ prepared: String, _ destination: String) -> Bool
    var remove: (_ path: String) -> Void
    /// Best-effort, after the fact: any failure is swallowed and never reaches a client.
    var syncDirectory: (_ path: String) -> Void
    var openLock: (_ path: String) -> Int32?
    var lockExclusiveNonblocking: (_ descriptor: Int32) -> Bool
    var closeDescriptor: (_ descriptor: Int32) -> Void

    /// The real POSIX implementation. Every closure is total: none traps, and a failure is a
    /// `false`/`nil` the caller has to handle rather than an exception that could escape mid-commit.
    static let live = ConfigurationFileOperations(
        readBounded: POSIXConfigurationFile.readBounded,
        readForVerification: POSIXConfigurationFile.readBounded,
        createDirectory: POSIXConfigurationFile.createDirectory,
        makeTemporary: POSIXConfigurationFile.makeTemporary,
        writeTemporary: POSIXConfigurationFile.writeTemporary,
        syncTemporary: POSIXConfigurationFile.syncTemporary,
        closeTemporary: { close($0.descriptor) },
        hardLink: POSIXConfigurationFile.hardLink,
        swapBackup: POSIXConfigurationFile.renameFile,
        commitDocument: POSIXConfigurationFile.renameFile,
        restoreDocument: POSIXConfigurationFile.renameFile,
        remove: { unlink($0) },
        syncDirectory: { _ = POSIXConfigurationFile.syncDirectory($0) },
        openLock: POSIXConfigurationFile.openLock,
        lockExclusiveNonblocking: POSIXConfigurationFile.lockExclusiveNonblocking,
        closeDescriptor: { close($0) }
    )
}

/// The POSIX primitives, isolated so the seam above stays about steps and this stays about syscalls.
enum POSIXConfigurationFile {
    /// Opens without following a symlink and without ever blocking, requires a regular file, and
    /// reads at most `maximumBytes + 1` bytes.
    ///
    /// `O_NOFOLLOW` alone is not enough: opening a FIFO read-only **blocks** until a writer appears,
    /// which on the shared HTTP queue would hang the whole deck. `O_NONBLOCK` makes that open
    /// return immediately, and `fstat` then identifies the file as non-regular. `O_NONBLOCK` has no
    /// effect on reading a regular file. The one-extra-byte allowance lets `ConfigurationDecoder`
    /// remain the single authority on "too large" — an oversized file is reported as
    /// `.malformed(.documentTooLarge)` by the codec rather than by a second, separate size rule
    /// here, and it is never fully allocated.
    static func readBounded(_ path: String, _ maximumBytes: Int) -> ConfigurationFileRead {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            // ENOENT is absence. ELOOP means `O_NOFOLLOW` stopped at a symlink, which is a path that
            // exists and is not a regular file — reported separately because it must never be
            // written through or renamed over. Everything else (EACCES, EISDIR, ENOTDIR, EIO) is a
            // file that could not be read, and must never be overwritten.
            switch errno {
            case ENOENT: return .absent
            case ELOOP: return .notRegularFile
            default: return .unreadable
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadable }
        guard UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { return .notRegularFile }

        // Stop at cap + 1 rather than at the end of the file: the codec decides what "too large"
        // means, and it only needs one byte past the cap to know. Reading a whole chunk past the
        // bound would allocate up to 64 KiB more than the contract promises.
        let limit = maximumBytes + 1
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(min(max(info.st_size, 0), Int64(limit))))
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while bytes.count < limit {
            let wanted = min(chunk, limit - bytes.count)
            let count = buffer.withUnsafeMutableBufferPointer {
                read(descriptor, $0.baseAddress, wanted)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .unreadable
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer[0..<count])
        }
        return .bytes(bytes)
    }

    /// Creates the directory with `0700` when it does not exist. An existing directory is left
    /// alone: the real `~/.oldphonedeck` is `0755` today and this has no business changing it.
    ///
    /// The mode is applied explicitly rather than through `createDirectory`'s `attributes:`, whose
    /// effect on intermediate components is not documented. The leaf is what will hold the token and
    /// a copied TLS identity under `--config-dir`; intermediates keep the process default.
    static func createDirectory(_ path: String) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) { return true }
        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    /// `mkstemp` performs `O_CREAT|O_EXCL` with a random suffix, so the name cannot collide with,
    /// predict or open another process's file — the property a PID-derived name does not have.
    static func makeTemporary(_ prefix: String, _ directory: String) -> ConfigurationTemporaryFile? {
        let template = directory + "/" + prefix + "XXXXXX"
        var buffer = Array(template.utf8CString)
        let descriptor = mkstemp(&buffer)
        guard descriptor >= 0 else { return nil }
        let path = String(cString: buffer)
        // `mkstemp` already uses 0600, but the guarantee is explicit rather than inherited from a
        // libc detail, and umask cannot widen it because this is an `fchmod` on the descriptor.
        guard fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            unlink(path)
            return nil
        }
        return ConfigurationTemporaryFile(path: path, descriptor: descriptor)
    }

    static func writeTemporary(_ temporary: ConfigurationTemporaryFile, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                write(temporary.descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    static func syncTemporary(_ temporary: ConfigurationTemporaryFile) -> Bool {
        while true {
            if fsync(temporary.descriptor) == 0 { return true }
            if errno == EINTR { continue }
            return false
        }
    }

    static func hardLink(_ existing: String, newPath: String) -> Bool {
        link(existing, newPath) == 0
    }

    /// Named `renameFile` rather than `rename` so the body reaches the Darwin function instead of
    /// recursing into itself.
    static func renameFile(_ old: String, to new: String) -> Bool {
        rename(old, new) == 0
    }

    /// Returns the outcome instead of swallowing it, so the measurement test can record what this
    /// platform actually does. Production ignores the result.
    static func syncDirectory(_ path: String) -> DirectorySyncOutcome {
        let descriptor = path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return .openFailed(errno) }
        defer { close(descriptor) }
        if fsync(descriptor) == 0 { return .synced }
        return .syncFailed(errno)
    }

    /// `O_NONBLOCK` here for the same reason as in `readBounded`: if something replaced the lock
    /// file with a FIFO, opening it must not block the shared HTTP queue.
    static func openLock(_ path: String) -> Int32? {
        let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_NONBLOCK, 0o600) }
        guard descriptor >= 0 else { return nil }
        guard fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    static func lockExclusiveNonblocking(_ descriptor: Int32) -> Bool {
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            if errno == EINTR { continue }
            return false
        }
    }
}

// MARK: - Write outcomes

/// Why a write did not happen, or could not be undone. The tokens are the wire vocabulary: the first
/// group is a `400`, `busy` is a `503`, `state` and `stale` are a `409`, and the last three are a
/// `500`.
enum ConfigurationWriteRejection: Equatable {
    /// More entries than the product has keys.
    case tooManyKeys
    /// An entry longer than a dispatchable path.
    case entryTooLong
    /// The document could not be built or self-verified before anything was touched.
    case writeFailed
    case busy
    /// The on-disk state refuses the write; the payload is the state to report.
    case state(ConfigurationStatusToken)
    /// The client's revision does not describe the document that is there now.
    case stale
    /// `expected` was absent or empty.
    case missingRevision
    /// The commit succeeded but verification failed and the base generation was restored.
    case recoveredFromFailedCommit
    /// The commit succeeded, verification failed, and restoration failed too. Nothing was deleted.
    case recoveryFailed
    /// An initial migration committed and could not be verified, with no previous generation to
    /// return to. The damaged document is retained as evidence and is never reported as migrated.
    case migrationFailed
}

struct ConfigurationWriteFailure: Equatable {
    let rejection: ConfigurationWriteRejection
    /// Non-nil only when the commit changed what is on disk and could not be undone, so the caller
    /// can report the resulting state rather than the state the request started from.
    let stateAfterFailure: ConfigurationRead?
}

enum ConfigurationWriteOutcome: Equatable {
    /// The document is on disk, verified, and `read` is the complete response to serve.
    case saved(ConfigurationRead)
    case rejected(ConfigurationWriteFailure)
}

// MARK: - Store

/// Reads, migrates and replaces the deck configuration.
///
/// The directory is **injected** rather than derived from `NSHomeDirectory()`, which is what makes
/// any of this testable on this macOS build: `NSHomeDirectory()` resolves from the password database
/// and ignores `$HOME`, so a temporary home directory does not isolate anything. Production passes
/// `~/.oldphonedeck`; tests pass a temporary directory; `--config-dir` (S2) will pass an operator's
/// choice.
struct ConfigurationStore {
    static let configurationName = "config.json"
    static let backupName = "config.json.prev"
    static let legacyName = "launcher.json"
    static let lockName = "config.lock"
    static let temporaryPrefix = "config.json.tmp-"
    static let backupTemporaryPrefix = "config.json.prev.tmp-"

    let directory: URL
    let operations: ConfigurationFileOperations

    init(directory: URL, operations: ConfigurationFileOperations = .live) {
        self.directory = directory
        self.operations = operations
    }

    var directoryPath: String { directory.path }
    var configurationPath: String { directory.appendingPathComponent(Self.configurationName).path }
    var backupPath: String { directory.appendingPathComponent(Self.backupName).path }
    var legacyPath: String { directory.appendingPathComponent(Self.legacyName).path }
    var lockPath: String { directory.appendingPathComponent(Self.lockName).path }

    // MARK: Reading

    /// Classifies the directory and, when a legacy selection is waiting to be migrated, migrates it.
    ///
    /// ADR-007 puts migration on the read path, so this is the one read that may write. Nothing is
    /// memoized: every call looks at the disk again, which is what keeps a second process's write
    /// visible and matches the stateless request handling the rest of the product assumes.
    func load() -> ConfigurationRead {
        let classification = classify()
        guard case .migrationPending(let configuration, let paths) = classification.state else {
            return Self.read(from: classification)
        }
        // A migration writes, so it needs the lock a plain read does not.
        guard let descriptor = acquireLock() else {
            return ConfigurationRead(state: .busy, selected: paths, status: .migrating,
                                     version: nil, writable: false, revision: nil)
        }
        defer { releaseLock(descriptor) }

        // Double-check under the lock. Another process may have committed the same migration, or a
        // concurrent save may have written something newer; either way this one must not write over
        // it. Committing only while `config.json` is still absent is what makes a stale migration
        // unable to lose an update.
        let rechecked = classify()
        guard case .migrationPending = rechecked.state else { return Self.read(from: rechecked) }

        switch commit(document: configuration, baseBytes: nil, baseValue: nil) {
        case .success:
            // Re-classify what was actually committed rather than assuming the result. A legacy file
            // holding more entries than the product has keys migrates faithfully and lands in
            // `.overLimit`; reporting `migrated` with `writable: true` there would let the editor
            // truncate it on the next save.
            let committed = classify()
            let migratedCleanly = committed.state == .ready(configuration)
            return Self.read(from: committed, statusOverride: migratedCleanly ? .migrated : nil)
        case .failure(.preCommit):
            // Nothing became visible, so the legacy selection is still authoritative and a later
            // read will attempt the migration again.
            return ConfigurationRead(state: rechecked.state, selected: paths, status: .legacyPending,
                                     version: nil, writable: true, revision: Self.revision(for: rechecked))
        case .failure(.postCommit):
            // The damaged document stays on disk as evidence and now shadows the legacy selection.
            // This is reported as corrupt, and never as migrated.
            let damaged = classify()
            return ConfigurationRead(state: damaged.state, selected: nil, status: .corrupt,
                                     version: nil, writable: false,
                                     revision: Self.revision(for: damaged))
        }
    }

    /// Classification plus the raw bytes it read, because the revision of an undecodable file is a
    /// fingerprint of exactly those bytes.
    struct Classification: Equatable {
        let state: ConfigurationStoreState
        let configBytes: [UInt8]?
        let legacyBytes: [UInt8]?
    }

    func classify() -> Classification {
        let configRead = operations.readBounded(configurationPath, ConfigurationDecoder.maximumDocumentBytes)
        let configBytes: [UInt8]?
        if case .bytes(let bytes) = configRead { configBytes = bytes } else { configBytes = nil }

        switch configRead {
        case .bytes(let bytes):
            switch ConfigurationDecoder.decode(.data(Data(bytes))) {
            case .v1(let configuration):
                return Classification(state: Self.projectableState(configuration),
                                      configBytes: configBytes, legacyBytes: nil)
            // An array here is legacy data in the versioned file's place. Reported, never adopted.
            case .legacy:
                return Classification(state: .wrongFormat(.config), configBytes: configBytes, legacyBytes: nil)
            case .malformed(let error):
                return Classification(state: .damaged(.config, .malformed(error)),
                                      configBytes: configBytes, legacyBytes: nil)
            case .unsupportedVersion(let found):
                return Classification(state: .damaged(.config, .unsupportedVersion(found: found)),
                                      configBytes: configBytes, legacyBytes: nil)
            case .absent, .unreadable:
                return Classification(state: .damaged(.config, .unreadable),
                                      configBytes: configBytes, legacyBytes: nil)
            }
        case .notRegularFile:
            return Classification(state: .damaged(.config, .notRegularFile), configBytes: nil, legacyBytes: nil)
        case .unreadable:
            return Classification(state: .damaged(.config, .unreadable), configBytes: nil, legacyBytes: nil)
        case .absent:
            break
        }

        // `config.json` is absent, so and only so is the frozen legacy file consulted.
        let legacyRead = operations.readBounded(legacyPath, ConfigurationDecoder.maximumDocumentBytes)
        let legacyBytes: [UInt8]?
        if case .bytes(let bytes) = legacyRead { legacyBytes = bytes } else { legacyBytes = nil }

        switch legacyRead {
        case .absent:
            return Classification(state: .unconfigured, configBytes: nil, legacyBytes: nil)
        case .notRegularFile:
            return Classification(state: .damaged(.legacy, .notRegularFile), configBytes: nil, legacyBytes: nil)
        case .unreadable:
            return Classification(state: .damaged(.legacy, .unreadable), configBytes: nil, legacyBytes: nil)
        case .bytes(let bytes):
            switch ConfigurationDecoder.decode(.data(Data(bytes))) {
            case .legacy(let paths):
                switch ConfigurationMigrator.migrateToV1(paths) {
                case .success(let configuration):
                    return Classification(state: .migrationPending(configuration, paths),
                                          configBytes: nil, legacyBytes: legacyBytes)
                case .failure(let error):
                    return Classification(state: .legacyUnrepresentable(paths, error),
                                          configBytes: nil, legacyBytes: legacyBytes)
                }
            // A versioned document in the legacy file is a layout error, not a document to adopt:
            // moving it would be a mutation nobody asked for, and is undefined when both files hold
            // one.
            case .v1, .unsupportedVersion:
                return Classification(state: .wrongFormat(.legacy), configBytes: nil, legacyBytes: legacyBytes)
            case .malformed(let error):
                return Classification(state: .damaged(.legacy, .malformed(error)),
                                      configBytes: nil, legacyBytes: legacyBytes)
            case .absent, .unreadable:
                return Classification(state: .damaged(.legacy, .unreadable),
                                      configBytes: nil, legacyBytes: legacyBytes)
            }
        }
    }

    /// Projectability is decided before the control count, so a titled nine-control document reports
    /// `unrepresentable`. Which of two read-only reasons wins matters less than the answer being the
    /// same every time.
    private static func projectableState(_ configuration: DeckConfigurationV1) -> ConfigurationStoreState {
        guard ConfigurationMigrator.legacySelection(configuration) != nil else { return .unprojectable(configuration) }
        guard configuration.controls.count <= ConfigurationStorePolicy.maximumAppControls else {
            return .overLimit(configuration)
        }
        return .ready(configuration)
    }

    static func read(from classification: Classification,
                     statusOverride: ConfigurationStatusToken? = nil) -> ConfigurationRead {
        ConfigurationRead(state: classification.state,
                          selected: selected(for: classification.state),
                          status: statusOverride ?? status(for: classification.state),
                          version: version(for: classification.state),
                          writable: isWritable(classification.state),
                          revision: revision(for: classification))
    }

    static func selected(for state: ConfigurationStoreState) -> [String]? {
        switch state {
        case .ready(let configuration), .overLimit(let configuration):
            // `.overLimit` serves every path: `selected: nil` means "cannot be expressed as a path
            // list at all", and an eight-control document of app launches can be. The client
            // truncates for display; the server never truncates on disk.
            return ConfigurationMigrator.legacySelection(configuration)
        case .migrationPending(_, let paths), .legacyUnrepresentable(let paths, _):
            return paths
        case .unprojectable, .unconfigured, .damaged, .wrongFormat, .busy:
            return nil
        }
    }

    static func status(for state: ConfigurationStoreState) -> ConfigurationStatusToken {
        switch state {
        case .ready: return .v1
        case .overLimit: return .tooManyControls
        case .unprojectable: return .unrepresentable
        case .unconfigured: return .unconfigured
        case .migrationPending: return .legacyPending
        case .legacyUnrepresentable: return .legacyReadonly
        case .damaged(_, let damage):
            switch damage {
            case .malformed: return .malformed
            case .unsupportedVersion: return .unsupportedVersion
            case .unreadable, .notRegularFile: return .unreadable
            }
        case .wrongFormat: return .wrongFormat
        case .busy: return .migrating
        }
    }

    static func version(for state: ConfigurationStoreState) -> Int? {
        if case .damaged(_, .unsupportedVersion(let found)) = state { return found }
        return nil
    }

    /// The five conditions of ADR-016's writable rule, minus the lock, which is per-response.
    /// Conditions 1 and 4 are already encoded in the state: a state with a V1 denotation implies the
    /// file was absent or a readable regular file.
    static func isWritable(_ state: ConfigurationStoreState) -> Bool {
        switch state {
        case .ready, .unconfigured, .migrationPending: return true
        case .overLimit, .unprojectable, .legacyUnrepresentable, .damaged, .wrongFormat, .busy:
            return false
        }
    }

    static func revision(for classification: Classification) -> String? {
        switch classification.state {
        case .ready(let configuration), .overLimit(let configuration), .unprojectable(let configuration),
             .migrationPending(let configuration, _):
            return ConfigurationRevision.ofDocument(configuration)
        case .unconfigured:
            return ConfigurationRevision.ofUnconfigured()
        case .legacyUnrepresentable:
            return ConfigurationRevision.ofRawBytes(tag: ConfigurationRevision.legacyTag,
                                                    classification.legacyBytes)
        case .damaged(let source, _), .wrongFormat(let source):
            switch source {
            case .config:
                return ConfigurationRevision.ofRawBytes(tag: ConfigurationRevision.configTag,
                                                        classification.configBytes)
            case .legacy:
                return ConfigurationRevision.ofRawBytes(tag: ConfigurationRevision.legacyTag,
                                                        classification.legacyBytes)
            }
        case .busy:
            // Never publish a token that was not computed under coordination.
            return nil
        }
    }

    // MARK: Writing

    /// Replaces the authoritative document with a selection of application paths.
    ///
    /// `paths` is already parsed: turning `n=` and `paths=` into this array is the route's job
    /// (S1b), which keeps this slice free of wire concerns. `expectedRevision` is the token the
    /// client was given, and nil or empty means it had none.
    func write(paths: [String], expectedRevision: String?) -> ConfigurationWriteOutcome {
        // P1 — product bounds, before any I/O.
        guard paths.count <= ConfigurationStorePolicy.maximumAppControls else {
            return .rejected(ConfigurationWriteFailure(rejection: .tooManyKeys, stateAfterFailure: nil))
        }
        guard paths.allSatisfy({ $0.utf8.count <= ConfigurationStorePolicy.maximumEntryBytes }) else {
            return .rejected(ConfigurationWriteFailure(rejection: .entryTooLong, stateAfterFailure: nil))
        }

        // P2 — pre-commit validation. `migrateToV1` is the one builder for both a save and a
        // migration, so the two cannot drift apart about ids, order or encodability, and
        // `verifiedData` requires the encoder's own output to decode back to this value.
        guard case .success(let document) = ConfigurationMigrator.migrateToV1(paths),
              case .success(let bytes) = ConfigurationEncoder.verifiedData(document) else {
            return .rejected(ConfigurationWriteFailure(rejection: .writeFailed, stateAfterFailure: nil))
        }
        let payload = [UInt8](bytes)

        // P3 — non-blocking. Waiting here would wait on the queue that also carries MJPEG.
        guard let descriptor = acquireLock() else {
            return .rejected(ConfigurationWriteFailure(rejection: .busy, stateAfterFailure: nil))
        }
        defer { releaseLock(descriptor) }

        // P4 — re-classify under the lock, and capture the base generation while it is still there.
        let classification = classify()
        guard Self.isWritable(classification.state) else {
            return .rejected(ConfigurationWriteFailure(rejection: .state(Self.status(for: classification.state)),
                                                       stateAfterFailure: nil))
        }
        // State before revision: "reload the page" is useless advice when the file is damaged.
        let expected = (expectedRevision?.isEmpty == false) ? expectedRevision : nil
        guard let expected else {
            return .rejected(ConfigurationWriteFailure(rejection: .missingRevision, stateAfterFailure: nil))
        }
        guard expected == Self.revision(for: classification) else {
            return .rejected(ConfigurationWriteFailure(rejection: .stale, stateAfterFailure: nil))
        }
        // The base exists exactly when `config.json` decoded to a V1 document, which is the only
        // writable state that has one. Recovery restores these bytes, so it cannot restore a
        // generation older than the one the client's revision described.
        var baseValue: DeckConfigurationV1?
        if case .ready(let current) = classification.state { baseValue = current }
        let baseBytes = baseValue == nil ? nil : classification.configBytes

        switch commit(document: document, baseBytes: baseBytes, baseValue: baseValue,
                      encodedPayload: payload) {
        case .success(let revision):
            // Derived rather than assumed. `.ready` is provable here — the bounds checked above cap
            // the count and `migrateToV1` only produces projectable controls — but a response must
            // never be able to claim `writable` for a document the writable rule would refuse.
            let resulting = Self.projectableState(document)
            return .saved(ConfigurationRead(state: resulting,
                                            selected: Self.selected(for: resulting),
                                            status: Self.status(for: resulting),
                                            version: nil,
                                            writable: Self.isWritable(resulting),
                                            revision: revision))
        case .failure(.preCommit(let rejection)):
            // Nothing became visible, so the state the request started from is still the truth.
            return .rejected(ConfigurationWriteFailure(rejection: rejection, stateAfterFailure: nil))
        case .failure(.postCommit(let rejection)):
            // The document changed on disk and could not be verified. Report what is there now,
            // not what the request started from.
            let after = classify()
            let recovered = rejection == .recoveredFromFailedCommit
            return .rejected(ConfigurationWriteFailure(
                rejection: recovered ? .writeFailed : rejection,
                stateAfterFailure: recovered
                    ? Self.read(from: after)
                    : ConfigurationRead(state: after.state, selected: nil, status: .corrupt,
                                        version: nil, writable: false,
                                        revision: Self.revision(for: after))))
        }
    }

    // MARK: Commit

    private enum CommitFailure: Error {
        case preCommit(ConfigurationWriteRejection)
        /// The document is on disk and could not be verified or undone.
        case postCommit(ConfigurationWriteRejection)
    }

    /// The three-phase commit: prepare, commit, verify — and recover from the base when verification
    /// fails.
    ///
    /// `baseBytes`/`baseValue` are nil for an initial migration, which has no previous generation to
    /// retain or return to. `encodedPayload` is the encoded document, computed by the caller for a
    /// save and here for a migration.
    private func commit(document: DeckConfigurationV1, baseBytes: [UInt8]?, baseValue: DeckConfigurationV1?,
                        encodedPayload: [UInt8]? = nil) -> Result<String, CommitFailure> {
        let payload: [UInt8]
        if let supplied = encodedPayload {
            payload = supplied
        } else {
            guard case .success(let data) = ConfigurationEncoder.verifiedData(document) else {
                return .failure(.preCommit(.writeFailed))
            }
            payload = [UInt8](data)
        }

        // P5 — prepare the replacement fully before anything else is touched.
        guard operations.createDirectory(directoryPath) else {
            return .failure(.preCommit(.writeFailed))
        }
        guard let temporary = operations.makeTemporary(Self.temporaryPrefix, directoryPath) else {
            return .failure(.preCommit(.writeFailed))
        }
        guard operations.writeTemporary(temporary, payload) else {
            operations.closeTemporary(temporary)
            operations.remove(temporary.path)
            return .failure(.preCommit(.writeFailed))
        }
        // Fatal, and still free: nothing is visible yet, so a document that may not have reached
        // stable storage is discarded rather than committed.
        guard operations.syncTemporary(temporary) else {
            operations.closeTemporary(temporary)
            operations.remove(temporary.path)
            return .failure(.preCommit(.writeFailed))
        }
        operations.closeTemporary(temporary)

        // P6 — prepare the backup under a temporary name. An existing backup stays visible and
        // byte-intact until its successor exists, so a failure here cannot destroy a good generation.
        var preparedBackup: String?
        if let baseBytes {
            let candidate = Self.backupCandidateName(for: temporary.path)
            if operations.hardLink(configurationPath, candidate) {
                // A hard link costs one directory entry and no data copy, and is safe precisely
                // because writes never mutate in place.
                preparedBackup = candidate
            } else if let copy = operations.makeTemporary(Self.backupTemporaryPrefix, directoryPath) {
                // Fallback for a filesystem that will not link: the base bytes were already read
                // under the lock, so no second read is needed.
                guard operations.writeTemporary(copy, baseBytes), operations.syncTemporary(copy) else {
                    operations.closeTemporary(copy)
                    operations.remove(copy.path)
                    operations.remove(temporary.path)
                    return .failure(.preCommit(.writeFailed))
                }
                operations.closeTemporary(copy)
                preparedBackup = copy.path
            } else {
                operations.remove(temporary.path)
                return .failure(.preCommit(.writeFailed))
            }
            // Best-effort: this makes the new directory entry durable, and is never a reason to fail.
            operations.syncDirectory(directoryPath)
        }

        // C1 — swap the backup into place before the document, so that at the moment recovery could
        // be needed the backup already holds the base generation.
        if let preparedBackup {
            guard operations.swapBackup(preparedBackup, backupPath) else {
                operations.remove(preparedBackup)
                operations.remove(temporary.path)
                return .failure(.preCommit(.writeFailed))
            }
        }

        // C2 — the atomic replacement. From here the new document is visible.
        guard operations.commitDocument(temporary.path, configurationPath) else {
            operations.remove(temporary.path)
            return .failure(.preCommit(.writeFailed))
        }
        // C3 — best-effort, after the fact: the rename already happened, and undoing it would be
        // worse than an unsynced directory entry.
        operations.syncDirectory(directoryPath)

        // V1 — post-commit verification. It should be unreachable for a payload `verifiedData`
        // already accepted; it exists because the alternative is trusting the rename.
        guard let verified = readVerifiedDocument(at: configurationPath), verified == document else {
            return recover(baseBytes: baseBytes, baseValue: baseValue)
        }
        guard let revision = ConfigurationRevision.ofDocument(document) else {
            return recover(baseBytes: baseBytes, baseValue: baseValue)
        }
        return .success(revision)
    }

    /// R1/R2 — undo a commit that could not be verified, or admit that it cannot be undone.
    private func recover(baseBytes: [UInt8]?, baseValue: DeckConfigurationV1?) -> Result<String, CommitFailure> {
        guard let baseBytes, let baseValue else {
            // An initial migration has no previous generation. The damaged document is retained as
            // evidence rather than deleted, and is never reported as a successful migration. Its
            // recovery is the frozen `launcher.json`, byte-intact precisely because migration never
            // writes it.
            return .failure(.postCommit(.migrationFailed))
        }
        guard let temporary = operations.makeTemporary(Self.temporaryPrefix, directoryPath),
              operations.writeTemporary(temporary, baseBytes) else {
            return .failure(.postCommit(.recoveryFailed))
        }
        guard operations.syncTemporary(temporary) else {
            operations.closeTemporary(temporary)
            operations.remove(temporary.path)
            return .failure(.postCommit(.recoveryFailed))
        }
        operations.closeTemporary(temporary)
        guard operations.restoreDocument(temporary.path, configurationPath) else {
            operations.remove(temporary.path)
            return .failure(.postCommit(.recoveryFailed))
        }
        operations.syncDirectory(directoryPath)
        // Restored, and proved restored: a recovery that is not verified is a second unverified
        // commit.
        guard let restored = readVerifiedDocument(at: configurationPath), restored == baseValue else {
            return .failure(.postCommit(.recoveryFailed))
        }
        return .failure(.postCommit(.recoveredFromFailedCommit))
    }

    private func readVerifiedDocument(at path: String) -> DeckConfigurationV1? {
        switch operations.readForVerification(path, ConfigurationDecoder.maximumDocumentBytes) {
        case .bytes(let bytes):
            if case .v1(let configuration) = ConfigurationDecoder.decode(.data(Data(bytes))) {
                return configuration
            }
            return nil
        case .absent, .unreadable, .notRegularFile:
            return nil
        }
    }

    /// The pending backup's name, derived from the random suffix `mkstemp` already guaranteed to be
    /// unique. `link(2)` needs a destination that does not exist, so a second `mkstemp` cannot be
    /// used; reusing the suffix keeps the name unpredictable without creating and unlinking a file
    /// to reserve it.
    private static func backupCandidateName(for temporaryPath: String) -> String {
        let suffix = String(temporaryPath.suffix(6))
        return (temporaryPath as NSString).deletingLastPathComponent + "/" + backupTemporaryPrefix + suffix
    }

    // MARK: Locking

    /// `flock` locks belong to the open file description, so two descriptors in one process also
    /// conflict: the policy is the same whether the second writer is another queue or another
    /// process. The kernel releases them on process death, so a crash cannot leave the
    /// configuration permanently locked.
    private func acquireLock() -> Int32? {
        guard operations.createDirectory(directoryPath) else { return nil }
        guard let descriptor = operations.openLock(lockPath) else { return nil }
        guard operations.lockExclusiveNonblocking(descriptor) else {
            operations.closeDescriptor(descriptor)
            return nil
        }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) {
        operations.closeDescriptor(descriptor)
    }
}
