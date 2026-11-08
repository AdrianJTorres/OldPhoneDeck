import Foundation

/// The shared `/launcher` handler, extracted from `main.swift` so integration tests can exercise
/// production wiring without starting a server. Follows the `AppLaunchRoute.handle` pattern from
/// M2.3: one entry point, validation re-run inside the handler, and no caller can reach the store
/// without the parameter checks.
///
/// **S3: wired to `ConfigurationStore`.** GET and a successful POST share one response shape
/// (M2.5-DESIGN §4.1): `selected`, `all`, `configuration` and `writable` always; `revision` on
/// every 200 except `migrating`; `version` only for `unsupported-version`; `saved` on POST only.
/// A refusal is one fixed lowercase token from the §4.3 vocabulary — a state refusal reports the
/// state, a concurrency refusal reports the concurrency reason — and no token carries document
/// content. `Launcher.selected()`/`Launcher.save()` are retired and the `Apps.isKnown` save filter
/// is gone (U3): order, empty entries, duplicates and uninstalled paths are stored exactly as
/// posted. Authorization for *executing* an app launch is unchanged and lives in `ActionRegistry`;
/// this route only stores and serves the selection.
enum LauncherRoute {
    /// Absent together means preserve, never reset. Partial pairs and noncanonical values fail
    /// before the store is reached, including when invoked through the shared admission validator.
    static func parseWidgets(_ params: [String: String]) -> Result<WidgetPreferences?, HTTPFailure> {
        let internet = params["internet"], batteries = params["batteries"]
        if internet == nil && batteries == nil { return .success(nil) }
        guard let internet, let batteries,
              (internet == "0" || internet == "1"), (batteries == "0" || batteries == "1") else {
            return .failure(HTTPFailure(status: 400, message: "invalid-widgets"))
        }
        return .success(WidgetPreferences(internet: internet == "1", batteries: batteries == "1"))
    }

    /// The parsed selection from `n`/`paths`, or a refusal token.
    enum SelectionResult: Equatable {
        case success([String])
        case invalidCount
        case countMismatch
        case entryTooLong

        var failure: HTTPFailure? {
            switch self {
            case .success: return nil
            case .invalidCount: return HTTPFailure(status: 400, message: "invalid-count")
            case .countMismatch: return HTTPFailure(status: 400, message: "count-mismatch")
            case .entryTooLong: return HTTPFailure(status: 400, message: "entry-too-long")
            }
        }
    }

    /// Parses `n` and `paths` into a selection array, following the M2.5 wire contract (§4.2).
    ///
    /// The parse is a total function with exactly one branch:
    /// - `n` absent: legacy behavior, split on `\n` omitting empty subsequences (unchanged from
    ///   pre-M2.5 `main.swift:147`).
    /// - `n` present: canonical unsigned decimal, 0...7, must agree with `paths` element count.
    ///
    /// The invariant: for `n >= 1`, splitting without omitting empty subsequences yields exactly
    /// `newlineCount + 1` elements, so `n` and `paths` agree by construction. Only `n == 0` needs
    /// a special rule, because an empty `paths` splits to one element rather than zero.
    static func parseSelection(_ params: [String: String]) -> SelectionResult {
        let paths = params["paths"] ?? ""

        // Legacy branch: no `n` parameter means pre-M2.5 client.
        guard let nText = params["n"] else {
            return .success(paths.split(separator: "\n").map(String.init))
        }

        // Validate `n`: canonical unsigned decimal, no sign, no leading zero, no whitespace.
        guard !nText.isEmpty,
              nText.allSatisfy({ $0.isASCII && $0.isNumber }),
              nText.first != "0" || nText == "0",
              let n = Int(nText),
              n >= 0, n <= ConfigurationStorePolicy.maximumAppControls else {
            return .invalidCount
        }

        // Zero controls: paths must be empty.
        if n == 0 {
            guard paths.isEmpty else { return .countMismatch }
            return .success([])
        }

        // Non-zero controls: split without omitting empty subsequences.
        let elements = paths.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard elements.count == n else { return .countMismatch }
        guard elements.allSatisfy({ $0.utf8.count <= ConfigurationStorePolicy.maximumEntryBytes }) else {
            return .entryTooLong
        }
        return .success(elements)
    }

    /// The one serializer for the §4.1 shape. GET and a successful POST both answer through it,
    /// so a field can never be present in one response and silently missing from the other.
    static func responseJSON(_ read: ConfigurationRead, catalog: [[String: String]],
                             saved: Int? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "selected": read.selected ?? NSNull(),
            "all": catalog,
            "configuration": read.status.rawValue,
            "writable": read.writable,
            "widgets": read.widgets.map { ["internet": $0.internet, "batteries": $0.batteries] } as Any? ?? NSNull(),
        ]
        // The single permitted error-payload field (ADR-015): the integer *is* the diagnosis.
        if let version = read.version { json["version"] = version }
        // Absent exactly when the store withheld it — a contended migration read must not publish
        // a token it cannot honour. Never synthesized here.
        if let revision = read.revision { json["revision"] = revision }
        if let saved { json["saved"] = saved }
        return json
    }

    /// The fixed §4.3 status/token map for a store refusal. `state` carries the store's own
    /// `configuration` token, so the table stays server-authored and shared with GET.
    static func refusal(_ rejection: ConfigurationWriteRejection) -> (status: Int, token: String) {
        switch rejection {
        case .tooManyKeys: return (400, "too-many-keys")
        case .entryTooLong: return (400, "entry-too-long")
        case .missingRevision: return (400, "missing-revision")
        case .state(let token): return (409, token.rawValue)
        case .stale: return (409, "stale")
        case .busy: return (503, "busy")
        case .writeFailed, .recoveredFromFailedCommit: return (500, "write-failed")
        case .migrationFailed: return (500, "migration-failed")
        case .recoveryFailed: return (500, "recovery-failed")
        }
    }

    /// The production handler for GET and POST `/launcher`. Re-runs `DeckRoute.validateParameters`
    /// so no caller can reach the store without the check, then reads or writes through the
    /// injected `ConfigurationStore`.
    static func handle(
        _ request: HTTPRequest,
        store: ConfigurationStore,
        on connection: HTTPConnection,
        catalog: @escaping () -> [[String: String]] = Apps.list
    ) {
        // Validation is repeated here rather than trusted to the route switch's generic pass.
        if let failure = DeckRoute.validateParameters(request) {
            return connection.respond(failure.status, text: failure.message)
        }

        switch request.method {
        case "GET":
            // 200 in every degraded state (§13): an unreachable configuration is a visible
            // read-only state, never an empty deck and never an HTTP error.
            connection.respondJSON(responseJSON(store.load(), catalog: catalog()))

        case "POST":
            let params = request.params
            let widgets: WidgetPreferences?
            switch parseWidgets(params) {
            case .success(let value): widgets = value
            case .failure(let failure): return connection.respond(failure.status, text: failure.message)
            }
            switch parseSelection(params) {
            case .success(let paths):
                let widgetsOnly = widgets != nil && params["n"] == nil && params["paths"] == nil
                switch store.write(paths: widgetsOnly ? nil : paths, expectedRevision: params["expected"], widgets: widgets) {
                case .saved(let read):
                    connection.respondJSON(responseJSON(read, catalog: catalog(), saved: read.selected?.count ?? 0))
                case .rejected(let failure):
                    let refusal = Self.refusal(failure.rejection)
                    connection.respond(refusal.status, text: refusal.token)
                }
            case let rejected:
                if let failure = rejected.failure {
                    connection.respond(failure.status, text: failure.message)
                }
            }

        default:
            connection.respond(405, text: "method not allowed")
        }
    }
}
