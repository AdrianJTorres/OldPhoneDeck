// M2.5 S2 — `--config-dir` option coverage: default paths are the production paths exactly,
// custom paths are resolved to absolute, and the token/TLS/store redirection seam works.
// Never reads or writes the real ~/.oldphonedeck, never starts the application.
// `--config-dir` with a missing value and an unusable path exit(2) from `Options.init`, which
// cannot run inside the test process; those paths are covered by the fixture run of the binary.

import Foundation
import Testing
@testable import oldphonedeck

/// Serialized because `LocalTLS.dir` is process-wide; every mutating test restores the production
/// default before the next one runs.
@Suite(.serialized)
struct ConfigDirOptionTests {
    private static let productionDir =
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck")

    private func tempConfigDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedeck-configdir-" + UUID().uuidString)
    }

    private func restoreProductionDefaults() {
        LocalTLS.use(configDir: Self.productionDir)
    }

    // MARK: Defaults (requirement 1 — unchanged without --config-dir)

    @Test func defaultConfigDirIsTheProductionDirectory() {
        let opts = Options(["oldphonedeck"])
        #expect(opts.configDir == Self.productionDir)
    }

    @Test func defaultTLSAndStorePathsAreTheProductionPaths() {
        #expect(LocalTLS.dir == Self.productionDir.appendingPathComponent("tls"))
        let store = ConfigurationStore(directory: Self.productionDir)
        #expect(store.legacyPath == Self.productionDir.appendingPathComponent("launcher.json").path)
        #expect(store.configurationPath == Self.productionDir.appendingPathComponent("config.json").path)
    }

    // MARK: Resolution (requirement 3 — always absolute)

    @Test func resolveKeepsAnAbsolutePath() throws {
        let resolved = try Options.resolveConfigDir("/tmp/phonedeck-configdir-fixture")
        #expect(resolved.path == "/tmp/phonedeck-configdir-fixture")
        #expect(resolved.path.hasPrefix("/"))
    }

    @Test func resolveExpandsATildePrefix() throws {
        let resolved = try Options.resolveConfigDir("~/phonedeck-configdir-fixture")
        #expect(resolved.path == NSHomeDirectory() + "/phonedeck-configdir-fixture")
    }

    @Test func resolveMakesARelativePathAbsoluteAgainstTheCurrentDirectory() throws {
        let resolved = try Options.resolveConfigDir("phonedeck-configdir-fixture")
        #expect(resolved.path == FileManager.default.currentDirectoryPath + "/phonedeck-configdir-fixture")
    }

    @Test func resolveStandardizesDotDotSegments() throws {
        let resolved = try Options.resolveConfigDir("/tmp/phonedeck-a/../phonedeck-b")
        #expect(resolved.path == "/tmp/phonedeck-b")
    }

    // MARK: Failure (requirement 4 — never silently fall back)

    @Test func resolveRejectsAMissingValue() {
        #expect(throws: Options.ConfigDirError.missingValue) { try Options.resolveConfigDir(nil) }
    }

    @Test func resolveRejectsAnEmptyPath() {
        #expect(throws: Options.ConfigDirError.empty) { try Options.resolveConfigDir("") }
    }

    @Test func resolveRejectsAValueThatLooksLikeAnotherOption() {
        #expect(throws: Options.ConfigDirError.flagLike("--port")) { try Options.resolveConfigDir("--port") }
        #expect(throws: Options.ConfigDirError.flagLike("-h")) { try Options.resolveConfigDir("-h") }
    }

    // MARK: Permissions (ADR-016 — a newly created configuration directory is 0700)

    @Test func createConfigDirAppliesMode0700ToANewDirectory() throws {
        let dir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Options.createConfigDir(dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func createConfigDirNeverChangesAnExistingDirectorysMode() throws {
        let dir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try Options.createConfigDir(dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    // MARK: Custom directory (requirement 2 — isolate token, TLS and configuration)

    @Test func customDirIsCreatedUpFrontAndRedirectsTokenTLSAndStore() throws {
        let dir = tempConfigDir()
        defer {
            restoreProductionDefaults()
            try? FileManager.default.removeItem(at: dir)
        }
        let opts = Options(["oldphonedeck", "--config-dir", dir.path])
        // Options.init creates the directory so an unusable path fails at startup, with 0700.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: opts.configDir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attrs = try FileManager.default.attributesOfItem(atPath: opts.configDir.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        LocalTLS.use(configDir: opts.configDir)
        #expect(LocalTLS.dir.path == opts.configDir.path + "/tls")
        #expect(LocalTLS.caDER.path == opts.configDir.path + "/tls/oldphonedeck-ca.cer")
        let store = ConfigurationStore(directory: opts.configDir)
        #expect(store.legacyPath == opts.configDir.path + "/launcher.json")
        #expect(store.configurationPath == opts.configDir.path + "/config.json")
        #expect(store.lockPath == opts.configDir.path + "/config.lock")

        // The token path derives from the same directory: a fresh config dir holds no token, so
        // loadToken() would mint an isolated one instead of reading the production token.
        let tokenFile = opts.configDir.appendingPathComponent("token")
        #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
    }

    @Test func restoringTheProductionDirRecoversTheDefaultTLSPath() throws {
        let dir = tempConfigDir()
        defer {
            restoreProductionDefaults()
            try? FileManager.default.removeItem(at: dir)
        }
        LocalTLS.use(configDir: dir)
        #expect(LocalTLS.dir.path == dir.path + "/tls")
        restoreProductionDefaults()
        #expect(LocalTLS.dir == Self.productionDir.appendingPathComponent("tls"))
    }

    // Requirement 5 (the app catalog is never redirected) is structural: `Apps.list()` keeps
    // deriving its directories from the real `/Applications` tree and `NSHomeDirectory()`, and
    // S2 gives it no configuration-directory input to derive anything from.
}
