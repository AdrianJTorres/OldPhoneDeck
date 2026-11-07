import Foundation

/// The shared `/launcher` handler, extracted from `main.swift` so integration tests can exercise
/// production wiring without starting a server. Follows the `AppLaunchRoute.handle` pattern from
/// M2.3: one entry point, validation re-run inside the handler, and no caller can reach the store
/// without the parameter checks.
///
/// **S1b: unwired to ConfigurationStore.** This slice extracts the handler structure and implements
/// the `n`/`paths`/`expected` validation, but the actual storage cutover (reading and writing
/// through `ConfigurationStore`) is S2/S3 work. Until then, the handler delegates to `Launcher`
/// for reads and writes, preserving the pre-M2.5 response shape.
enum LauncherRoute {
    /// The parsed selection from `n`/`paths`, or a refusal token.
    enum SelectionResult: Equatable {
        case success([String])
        case invalidCount
        case countMismatch
        case entryTooLong
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

    /// The production handler for GET and POST `/launcher`. Re-runs `DeckRoute.validateParameters`
    /// so no caller can reach the store without the check, then delegates to the injected loader
    /// and saver.
    ///
    /// **S1b: the loader and saver are the legacy `Launcher` methods.** The ConfigurationStore
    /// integration is S2/S3 work. The handler structure is what matters here: one entry point,
    /// validation inside, and a response shape that includes `selected` and `all`.
    static func handle(
        _ request: HTTPRequest,
        loader: @escaping () -> [String]?,
        saver: @escaping ([String]) throws -> Int,
        on connection: HTTPConnection,
        catalog: @escaping () -> [[String: String]] = Apps.list
    ) {
        // Validation is repeated here rather than trusted to the route switch's generic pass.
        if let failure = DeckRoute.validateParameters(request) {
            return connection.respond(failure.status, text: failure.message)
        }

        let params = request.params

        switch request.method {
        case "GET":
            let selected: Any = loader() ?? NSNull()
            connection.respondJSON(["selected": selected, "all": catalog()])

        case "POST":
            // S1b: validate n/paths, but delegate to the legacy saver. The `expected` parameter
            // is parsed but not yet enforced (that's S2/S3 work with ConfigurationStore).
            switch parseSelection(params) {
            case .success(let paths):
                do {
                    let saved = try saver(paths)
                    // POST returns the same shape as GET, plus `saved`. Until S2/S3, the response
                    // does not include `configuration`, `writable`, or `revision` (those come from
                    // ConfigurationStore). The client tolerates their absence.
                    let selected: Any = loader() ?? NSNull()
                    connection.respondJSON(["selected": selected, "all": catalog(), "saved": saved])
                } catch {
                    connection.respond(500, text: "write-failed")
                }
            case .invalidCount:
                connection.respond(400, text: "invalid-count")
            case .countMismatch:
                connection.respond(400, text: "count-mismatch")
            case .entryTooLong:
                connection.respond(400, text: "entry-too-long")
            }

        default:
            connection.respond(405, text: "method not allowed")
        }
    }
}
