import Foundation
import Testing
@testable import oldphonedeck

/// Records launches instead of performing them, so no test reaches NSWorkspace or opens an
/// application. Shared with `AppLaunchRouteTests.swift`.
final class LaunchRecorder {
    struct Launch: Equatable {
        let path: String
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Launch] = []

    func launch(_ path: String) {
        lock.lock(); recorded.append(Launch(path: path, onMainThread: Thread.isMainThread)); lock.unlock()
    }

    var launches: [Launch] { lock.lock(); defer { lock.unlock() }; return recorded }
    var paths: [String] { launches.map(\.path) }
    var count: Int { launches.count }
}

/// Deterministic stand-in for the Mac's own approved application catalog. It also counts the
/// authorization queries the boundary makes, so a test can prove the check ran. Shared with
/// `AppLaunchRouteTests.swift`.
final class FakeAppCatalog {
    static let approved = [
        "/Applications/Safari.app",
        "/Applications/Utilities/Terminal.app",
        "/System/Applications/Calculator.app",
        NSHomeDirectory() + "/Applications/Private Tools.app",
    ]

    private let lock = NSLock()
    private let approvedPaths: Set<String>
    private var queries: [String] = []

    init(_ approved: [String] = FakeAppCatalog.approved) { approvedPaths = Set(approved) }

    func isKnown(_ path: String) -> Bool {
        lock.lock(); queries.append(path); lock.unlock()
        return approvedPaths.contains(path)
    }

    var consulted: [String] { lock.lock(); defer { lock.unlock() }; return queries }
}

/// A registry wired only to test doubles: nothing it dispatches can open an application.
func testRegistry(catalog: FakeAppCatalog = FakeAppCatalog(), recorder: LaunchRecorder) -> ActionRegistry {
    ActionRegistry(approvedAppPath: catalog.isKnown, launchApp: recorder.launch)
}

// MARK: A. Action identity

struct ActionIdentityTests {
    @Test func registeredAppLaunchActionResolves() throws {
        let registry = testRegistry(recorder: LaunchRecorder())
        let id = try #require(ActionID(rawValue: "app.launch"))
        #expect(id == .appLaunch)
        #expect(registry.descriptor(for: id) == ActionDescriptor(id: .appLaunch, displayName: "Launch app",
                                                                kind: .launchApplication))
    }

    @Test(arguments: ["app.quit", "app.relaunch", "shell.exec", "admin.run", "app", "launch", "app.launchx",
                      "App.Launch", "APP.LAUNCH", "app.launch ", " app.launch", "app..launch", ".app.launch",
                      "app.launch.", "app.launch\n", "/bin/sh", "app.launch;rm", "",
                      String(repeating: "a", count: ActionID.maximumLength + 1)])
    func unknownActionIDsFailClosed(raw: String) {
        let recorder = LaunchRecorder()
        let registry = testRegistry(recorder: recorder)
        // An identifier that is not even a lowercase dotted name cannot be constructed at all.
        guard let id = ActionID(rawValue: raw) else {
            #expect(recorder.count == 0)
            return
        }
        // A well-formed but unregistered identifier resolves to no descriptor, and an
        // otherwise approved path does not make it executable.
        #expect(registry.descriptor(for: id) == nil)
        #expect(registry.dispatch(id, parameters: .appPath(FakeAppCatalog.approved[0])) == .unknownAction)
        #expect(recorder.count == 0)
    }

    @Test func registeredMetadataIsServerAuthored() {
        let recorder = LaunchRecorder()
        let registry = testRegistry(recorder: recorder)
        let empty = testRegistry(catalog: FakeAppCatalog([]), recorder: LaunchRecorder())
        // The table is identical whatever catalog or executor a registry was built with,
        // because it is a server constant rather than anything derived from a request.
        #expect(empty.descriptor(for: .appLaunch) == registry.descriptor(for: .appLaunch))
        #expect(registry.descriptor(for: .appLaunch)?.displayName == "Launch app")
        #expect(registry.descriptor(for: .appLaunch)?.kind == .launchApplication)
    }

    @Test func clientMetadataCannotAuthorizeAnAction() throws {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog([]) // nothing is approved
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        // A descriptor is not an input to dispatch: inventing one, or naming a different
        // display name, changes nothing about what may execute.
        let invented = ActionDescriptor(id: .appLaunch, displayName: "Run anything", kind: .launchApplication)
        #expect(invented.displayName != registry.descriptor(for: .appLaunch)?.displayName)
        #expect(registry.dispatch(invented.id, parameters: .appPath("/Applications/Safari.app")) == .notAuthorized)
        #expect(recorder.count == 0)
        #expect(catalog.consulted == ["/Applications/Safari.app"]) // authorization ran, and refused
        // Nor does a syntactically valid identifier the client invented become executable.
        let inventedID = try #require(ActionID(rawValue: "system.shutdown"))
        #expect(registry.descriptor(for: inventedID) == nil)
        #expect(registry.dispatch(inventedID, parameters: .appPath("/Applications/Safari.app")) == .unknownAction)
        #expect(recorder.count == 0)
        #expect(catalog.consulted == ["/Applications/Safari.app"]) // an unregistered action never gets that far
    }
}

// MARK: B. Parameters

struct ActionParameterTests {
    @Test func missingPathIsRejected() {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog()
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        // The adapter decodes an absent parameter exactly as the pre-M2.3 route did
        // (`p["path"] ?? ""`), and the boundary rejects it before authorization.
        #expect(AppLaunchAdapter.handle([:], registry: registry) == HTTPFailure(status: 404, message: "unknown app"))
        #expect(AppLaunchAdapter.handle(["cmd": "playpause"], registry: registry)?.status == 404)
        #expect(recorder.count == 0)
        #expect(catalog.consulted.isEmpty)
    }

    @Test func emptyPathIsRejected() {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog()
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        #expect(AppLaunchParameters(path: "") == nil)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath("")) == .invalidParameters)
        #expect(AppLaunchAdapter.handle(["path": ""], registry: registry)?.status == 404)
        #expect(recorder.count == 0)
        #expect(catalog.consulted.isEmpty)
    }

    @Test func overlongPathIsRejected() {
        let recorder = LaunchRecorder()
        let registry = testRegistry(recorder: recorder)
        // The boundary counts UTF-8 bytes, not characters, and mirrors the wire limit that
        // `DeckRoute.validateParameters` enforces with a 413 — the two layers cannot drift.
        #expect(AppLaunchParameters.maximumPathBytes == 4096)
        let exact = String(repeating: "a", count: AppLaunchParameters.maximumPathBytes)
        #expect(AppLaunchParameters(path: exact)?.path == exact)
        #expect(AppLaunchParameters(path: exact + "a") == nil)
        #expect(AppLaunchParameters(path: String(repeating: "é", count: 2049)) == nil) // 4098 bytes
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(exact + "a")) == .invalidParameters)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(String(repeating: "é", count: 2049)))
                == .invalidParameters)
        #expect(recorder.count == 0)
        // A well-formed overlong-free path is still not an approved one.
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(exact)) == .notAuthorized)
        #expect(recorder.count == 0)
    }

    @Test(arguments: ["/etc/passwd", "/bin/sh", "/usr/bin/osascript", "/tmp/evil", "~/Applications/Safari.app",
                      "/Applications/NotInstalled.app", "/Applications", "/", "Safari.app", "app.launch"])
    func arbitraryPathsOutsideTheCatalogAreRejected(path: String) {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog()
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(path)) == .notAuthorized)
        #expect(recorder.count == 0)
        #expect(catalog.consulted == [path])
    }

    @Test(arguments: ["/tmp/evil.app", "/Applications/evil.app", "/tmp/../Applications/Safari.app",
                      NSHomeDirectory() + "/Downloads/Installer.app", "/Applications/Safari.app/Contents/MacOS/Safari",
                      "/var/folders/zz/T/com.apple.launchd.tmp/fake.app"])
    func anAppSuffixDoesNotAuthorizeAPath(path: String) {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog([FakeAppCatalog.approved[0]]) // only Safari is approved
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(path)) == .notAuthorized)
        #expect(recorder.count == 0)
    }
}

// MARK: C. Authorization

struct ActionAuthorizationTests {
    @Test func exactApprovedPathsAreAuthorized() {
        for path in FakeAppCatalog.approved {
            let recorder = LaunchRecorder()
            let registry = testRegistry(recorder: recorder)
            #expect(registry.dispatch(.appLaunch, parameters: .appPath(path)) == .dispatched)
            #expect(recorder.paths == [path])
        }
    }

    @Test(arguments: ["/Applications/Safari.app ", " /Applications/Safari.app", "/Applications/Safari.App",
                      "/applications/Safari.app", "/Applications/Safari.app/", "//Applications/Safari.app",
                      "/private/Applications/Safari.app", "/Applications/./Safari.app", "/Applications/Safari.app\n"])
    func similarButNonIdenticalPathsAreRejected(variant: String) {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog([FakeAppCatalog.approved[0]])
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(variant)) == .notAuthorized)
        #expect(recorder.count == 0)
        #expect(catalog.consulted == [variant]) // exact membership was asked about the exact string
    }

    @Test func rejectedActionsNeverReachTheExecutor() {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog([]) // a catalog that approves nothing at all
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        for path in FakeAppCatalog.approved + ["/tmp/evil.app", "/Applications/Safari.app ", "/bin/sh", ""] {
            #expect(registry.dispatch(.appLaunch, parameters: .appPath(path)) != .dispatched)
        }
        #expect(recorder.count == 0)
        #expect(catalog.consulted.count == 7) // the empty path is rejected before authorization
    }

    @Test func authorizationLivesInsideTheBoundary() {
        // Dispatch is called directly here: no HTTP request, no adapter, no parameter
        // decoding in front of it. Authorization still runs, once per dispatch, and its
        // answer is final.
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog()
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath("/tmp/evil.app")) == .notAuthorized)
        #expect(catalog.consulted == ["/tmp/evil.app"])
        #expect(recorder.count == 0)
        let approved = FakeAppCatalog.approved[1]
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(approved)) == .dispatched)
        #expect(catalog.consulted == ["/tmp/evil.app", approved])
        #expect(recorder.paths == [approved])
        // The adapter adds no authorization of its own and cannot weaken the registry's.
        #expect(AppLaunchAdapter.handle(["path": "/tmp/evil.app"], registry: registry)?.status == 404)
        #expect(recorder.paths == [approved])
    }

    @Test func productionCatalogPolicyFailsClosed() throws {
        // The real production authorization policy — `Apps.isKnown`, which rescans the Mac's
        // own application directories — behind a recording executor.
        //
        // No test may construct `ActionRegistry()`: that initializer retains the real
        // `Apps.launch`, so a regressed or mutated authorization gate would carry a path
        // straight to NSWorkspace. Injecting the executor means a regression can only fail an
        // expectation here, never open an application. The two production ingredients are
        // pinned separately instead: this test for the catalog policy, and
        // `productionExecutorKeepsAsynchronousMainQueueDispatch` for the executor's dispatch.
        let recorder = LaunchRecorder()
        let registry = ActionRegistry(approvedAppPath: Apps.isKnown, launchApp: recorder.launch)
        for path in ["", "/bin/sh", "/etc/hosts", "/etc/passwd", "/Applications", "/Applications/Safari.app ",
                     "/tmp/evil.app", "app.launch"] {
            #expect(registry.dispatch(.appLaunch, parameters: .appPath(path)) != .dispatched)
        }
        // An unregistered identifier must not resolve to the registered action.
        let unregistered = try #require(ActionID(rawValue: "app.quit"))
        #expect(registry.dispatch(unregistered, parameters: .appPath("/bin/sh")) == .unknownAction)
        #expect(recorder.count == 0)
        #expect(registry.descriptor(for: .appLaunch) != nil)
    }
}

// MARK: D. Execution

struct ActionExecutionTests {
    @Test func approvedActionCallsTheExecutorExactlyOnce() {
        let recorder = LaunchRecorder()
        let registry = testRegistry(recorder: recorder)
        let approved = FakeAppCatalog.approved[0]
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(approved)) == .dispatched)
        #expect(recorder.paths == [approved])
        // A second dispatch is a second, separately authorized launch — never an implicit repeat.
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(approved)) == .dispatched)
        #expect(recorder.count == 2)
        #expect(recorder.paths == [approved, approved])
    }

    @Test func invalidActionsCallTheExecutorZeroTimes() throws {
        let recorder = LaunchRecorder()
        let registry = testRegistry(recorder: recorder)
        let unregistered = try #require(ActionID(rawValue: "app.relaunch"))
        let approved = FakeAppCatalog.approved[0]
        #expect(registry.dispatch(unregistered, parameters: .appPath(approved)) == .unknownAction)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath("")) == .invalidParameters)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(String(repeating: "a", count: 4097)))
                == .invalidParameters)
        #expect(recorder.count == 0)
    }

    @Test func failurePathsDoNotExecuteAndLeaveNoState() {
        // A catalog that approves nothing, and a catalog that approves a different app than
        // the one requested, must both leave the executor untouched.
        let none = LaunchRecorder()
        let noneRegistry = testRegistry(catalog: FakeAppCatalog([]), recorder: none)
        #expect(noneRegistry.dispatch(.appLaunch, parameters: .appPath(FakeAppCatalog.approved[0])) == .notAuthorized)
        #expect(none.count == 0)

        let recorder = LaunchRecorder()
        let other = FakeAppCatalog.approved[1]
        let registry = testRegistry(catalog: FakeAppCatalog([other]), recorder: recorder)
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(FakeAppCatalog.approved[0])) == .notAuthorized)
        #expect(recorder.count == 0)
        // The rejected dispatch left nothing behind that a later one could reuse.
        #expect(registry.dispatch(.appLaunch, parameters: .appPath(other)) == .dispatched)
        #expect(recorder.paths == [other])
    }

    @Test func concurrentDispatchesAuthorizeIndependently() {
        let recorder = LaunchRecorder()
        let catalog = FakeAppCatalog([FakeAppCatalog.approved[0]])
        let registry = testRegistry(catalog: catalog, recorder: recorder)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let path = index.isMultiple(of: 2) ? FakeAppCatalog.approved[0] : "/tmp/evil.app"
            #expect(registry.dispatch(.appLaunch, parameters: .appPath(path))
                    == (index.isMultiple(of: 2) ? .dispatched : .notAuthorized))
        }
        #expect(recorder.count == 50)
        #expect(recorder.paths.allSatisfy { $0 == FakeAppCatalog.approved[0] })
        #expect(catalog.consulted.count == 100)
    }

    @Test func productionExecutorKeepsAsynchronousMainQueueDispatch() {
        // `AppLaunchExecutor.schedule` is the production execution boundary; only its launch
        // callback is replaced, so NSWorkspace is never called. The pre-M2.3 route used
        // `DispatchQueue.main.async { Apps.launch(path) }`, and that shape must survive: the
        // caller's acknowledgement means "accepted and dispatched", not "the app activated".
        let recorder = LaunchRecorder()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { entered.signal(); release.wait() } // occupy the main queue
        #expect(entered.wait(timeout: .now() + 5) == .success)
        AppLaunchExecutor.schedule(FakeAppCatalog.approved[0], launch: recorder.launch)
        #expect(recorder.count == 0) // nothing ran inline on the calling thread
        DispatchQueue.main.async { drained.signal() } // queued behind the scheduled launch
        release.signal()
        #expect(drained.wait(timeout: .now() + 5) == .success)
        #expect(recorder.paths == [FakeAppCatalog.approved[0]])
        #expect(recorder.launches == [LaunchRecorder.Launch(path: FakeAppCatalog.approved[0], onMainThread: true)])
    }

    @Test func registryDispatchIsSynchronousThroughTheInjectedExecutor() {
        // The registry adds no queue hop of its own: the executor has already run when
        // dispatch returns. That is what lets the HTTP route answer `ok` for an accepted
        // launch and `404` for every rejection in a single pass.
        let recorder = LaunchRecorder()
        let registry = testRegistry(recorder: recorder)
        var executed: [String] = []
        for path in FakeAppCatalog.approved {
            #expect(registry.dispatch(.appLaunch, parameters: .appPath(path)) == .dispatched)
            executed.append(path)
            #expect(recorder.paths == executed)
        }
        #expect(recorder.paths == FakeAppCatalog.approved)
    }
}
