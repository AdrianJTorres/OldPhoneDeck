import Foundation

/// Stable identifier of a server-approved action. The syntax is validated on construction,
/// and the identifier must also name a registered action before anything can execute, so an
/// arbitrary name can never resolve to executable behaviour.
struct ActionID: Hashable, RawRepresentable {
    static let maximumLength = 64

    let rawValue: String

    /// nil for anything that is not a lowercase dotted name — including `"App.Launch"`,
    /// `"app.launch "`, `"app..launch"`, `""` and `"/bin/sh"`.
    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= Self.maximumLength,
              !rawValue.hasPrefix("."), !rawValue.hasSuffix("."), !rawValue.contains(".."),
              rawValue.utf8.allSatisfy(Self.isNameByte) else { return nil }
        self.rawValue = rawValue
    }

    /// The only capability migrated onto the boundary in M2.3.
    static let appLaunch = ActionID(rawValue: "app.launch")!
    static let shortcutRun = ActionID(rawValue: "shortcut.run")!

    private static func isNameByte(_ b: UInt8) -> Bool {
        (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 46 // a-z, 0-9, "."
    }
}

/// Coarse server-defined category. `ActionRegistry.dispatch` switches on it with no default
/// case, so a new kind must be authorized explicitly before it can execute.
enum ActionKind: Equatable {
    case launchApplication
    case runShortcut
}

/// Server-authored display metadata. It describes an action and never authorizes one; it is
/// not persisted (versioned configuration is a later slice).
struct ActionDescriptor: Equatable {
    let id: ActionID
    let displayName: String
    let kind: ActionKind
}

/// Validated parameters of an approved action. Everything here is data: an application path
/// is a lookup key into the Mac's own catalog, never a command, argv element, script,
/// environment variable or working directory. No case can express those (ADR-005).
enum ActionParameters: Equatable {
    case appPath(String)
    case shortcutUUID(ShortcutUUID)
}

/// Well-formedness rules for an app-launch path. Being well formed is not being approved:
/// the registry still requires exact catalog membership.
struct AppLaunchParameters: Equatable {
    /// Mirrors the wire limit in `DeckRoute.validateParameters`. The boundary enforces it
    /// again so no caller depends on the transport having checked first.
    static let maximumPathBytes = 4096

    let path: String

    /// nil for an absent, empty or overlong path.
    init?(path: String) {
        guard !path.isEmpty, path.utf8.count <= Self.maximumPathBytes else { return nil }
        self.path = path
    }
}

/// Why a dispatch did or did not reach an executor. Failures carry no client-supplied detail.
enum ActionOutcome: Equatable {
    case dispatched // accepted and scheduled — not proof that an application activated
    case unknownAction
    case invalidParameters
    case notAuthorized
    case unavailable
    case busy
}

/// The single server-authoritative path from a caller to an approved macOS action.
/// Authorization lives here rather than in the HTTP route, so a caller that reaches the
/// registry by any route is still authorized against the Mac's own state.
struct ActionRegistry {
    /// Server-authored table of approved actions. A client may name an id; it cannot add,
    /// rename or re-describe one, and there is no registration entry point.
    private static let descriptors: [ActionID: ActionDescriptor] = [
        .appLaunch: ActionDescriptor(id: .appLaunch, displayName: "Launch app", kind: .launchApplication),
        .shortcutRun: ActionDescriptor(id: .shortcutRun, displayName: "Run Shortcut", kind: .runShortcut),
    ]

    private let isApprovedAppPath: (String) -> Bool
    private let launchApp: (String) -> Void
    private let shortcuts: ShortcutService?

    /// Production wiring: the Mac's own approved application catalog and the existing
    /// main-queue launch. This is the only registry that can reach NSWorkspace, so automated
    /// tests must build one through the injecting initializer below instead — a test that
    /// holds the real executor could open an application if an authorization gate regressed.
    init(shortcuts: ShortcutService? = nil) {
        self.init(approvedAppPath: Apps.isKnown, launchApp: { AppLaunchExecutor.schedule($0) }, shortcuts: shortcuts)
    }

    /// Injecting initializer: the authorization policy and the execution callback are
    /// supplied by the caller, which is what makes the boundary testable without touching
    /// NSWorkspace. Production passes `Apps.isKnown` and `AppLaunchExecutor.schedule`.
    init(approvedAppPath: @escaping (String) -> Bool, launchApp: @escaping (String) -> Void,
         shortcuts: ShortcutService? = nil) {
        self.shortcuts = shortcuts
        self.isApprovedAppPath = approvedAppPath
        self.launchApp = launchApp
    }

    /// Server-authored metadata for a registered action, or nil. Metadata never authorizes.
    func descriptor(for id: ActionID) -> ActionDescriptor? { Self.descriptors[id] }

    /// Authorizes, then dispatches. Every rejection returns before the executor is reached.
    func dispatch(_ id: ActionID, parameters: ActionParameters, runID: String? = nil) -> ActionOutcome {
        guard let descriptor = Self.descriptors[id] else { return .unknownAction }
        switch (descriptor.kind, parameters) {
        case (.launchApplication, .appPath(let candidate)):
            guard let validated = AppLaunchParameters(path: candidate) else { return .invalidParameters }
            // Exact membership in the catalog the server itself produced. A ".app" suffix, a
            // plausible directory or a matching display name proves nothing.
            guard isApprovedAppPath(validated.path) else { return .notAuthorized }
            launchApp(validated.path)
            return .dispatched
        case (.runShortcut, .shortcutUUID(let uuid)):
            guard let shortcuts, let runID else { return .notAuthorized }
            return shortcuts.start(uuid, runID: runID)
        default: return .invalidParameters
        }
    }
}

/// Controlled execution interface for `app.launch`, and the only caller of `Apps.launch`.
/// It receives a path the registry has already authorized and adds no policy of its own.
enum AppLaunchExecutor {
    /// Schedules the launch on the main queue and returns immediately, exactly as the
    /// pre-M2.3 route did: the acknowledgement means "accepted and dispatched", never
    /// "the application activated". `launch` is injectable so tests never reach NSWorkspace.
    static func schedule(_ path: String, launch: @escaping (String) -> Void = Apps.launch) {
        DispatchQueue.main.async { launch(path) }
    }
}

/// Thin `POST /launch` adapter. The transport decodes parameters and reports the existing
/// response shape; it never names an executor and cannot reach `Apps.launch`.
enum AppLaunchAdapter {
    /// `nil` = accepted (`200 ok`); every rejection keeps the historical `404 unknown app`,
    /// because rejection reasons are deliberately not distinguished on the wire.
    static func handle(_ params: [String: String], registry: ActionRegistry) -> HTTPFailure? {
        // The server names the action, so no client-supplied identifier is decoded here and
        // a different identifier cannot select different behaviour.
        let outcome = registry.dispatch(.appLaunch, parameters: .appPath(params["path"] ?? ""))
        guard outcome == .dispatched else { return HTTPFailure(status: 404, message: "unknown app") }
        return nil
    }
}

/// The one `POST /launch` handler, shared by the production route switch and the integration
/// tests, so a test cannot pass against wiring production does not use.
enum AppLaunchRoute {
    /// Runs the M2.1 parameter check, asks the registry to authorize and dispatch, and
    /// answers with the historical response shape. Callers reach this only after
    /// `DeckRoute.admit`; nothing else about the route is assumed.
    static func handle(_ request: HTTPRequest, registry: ActionRegistry, on connection: HTTPConnection) {
        // Validation is repeated here rather than trusted to the route switch's generic pass:
        // no caller may reach the adapter without it. `DeckRoute.validateParameters` is pure,
        // so running it twice for this route changes nothing but cost.
        if let failure = DeckRoute.validateParameters(request) {
            return connection.respond(failure.status, text: failure.message)
        }
        if let failure = AppLaunchAdapter.handle(request.params, registry: registry) {
            return connection.respond(failure.status, text: failure.message)
        }
        connection.respond(text: "ok")
    }
}
