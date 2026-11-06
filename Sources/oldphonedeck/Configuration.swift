import Foundation

/// Configuration V1: a versioned, ordered description of the deck's controls.
///
/// This file is a **pure codec**. It converts between bytes and values; it never opens a file,
/// never consults `Apps`, never holds an `ActionRegistry` and never reaches an executor. Storage
/// integration and the read-path migration ADR-007 describes belong to M2.5, which supplies the
/// bytes and decides what, if anything, to persist.
///
/// Decoding a configuration confers no authority. An action named here is executable only if
/// `ActionRegistry` independently resolves it and authorizes its parameters against the Mac's own
/// state, exactly as `POST /launch` does today. Configuration says what the user configured;
/// the registry says what may run.

// MARK: Identity

/// Stable, opaque identifier of one configured control. An id survives reordering and is not
/// derived from the action or its parameters, so changing what a key does never changes which key
/// it is. The syntax mirrors `ActionID`'s: a value that is not a lowercase name cannot be
/// constructed at all, so no later check has to re-validate it.
struct ControlID: Hashable, RawRepresentable {
    static let maximumLength = 64

    let rawValue: String

    /// nil for anything that is not a lowercase dashed name — including `"Key"`, `"KEY"`,
    /// `"key 1"`, `"key_1"`, `"key.1"`, `""`, `"-key"`, `"key-"` and a 65-byte string. An
    /// interior dash is ordinary (`"app-1"`, `"build-terminal"`).
    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= Self.maximumLength,
              !rawValue.hasPrefix("-"), !rawValue.hasSuffix("-"),
              rawValue.utf8.allSatisfy(Self.isNameByte) else { return nil }
        self.rawValue = rawValue
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 // a-z, 0-9, "-"
    }
}

// MARK: Document

/// Server-side display metadata for one control. It describes a key and never authorizes one, the
/// same distinction `ActionDescriptor` draws for an action.
struct ControlPresentation: Equatable {
    static let maximumTitleBytes = 128

    /// nil = the server supplies the label, which today means the application's own name.
    let title: String?

    /// A title is rendered through `textContent`, so it needs no escaping — but it is bounded and
    /// stripped of invisible formatting characters, because a newline or a C1 control inside a key
    /// label is corruption rather than expression.
    static func isValidTitle(_ title: String) -> Bool {
        guard !title.isEmpty, title.utf8.count <= maximumTitleBytes else { return false }
        return title.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value >= 0x20 && value != 0x7F && !(0x80...0x9F).contains(value)
        }
    }
}

/// Typed parameters of one configured control.
///
/// Values are always flat strings, which is the shape the existing wire protocol already uses:
/// `HTTPRequest.params` is `[String: String]`, `AppLaunchAdapter.handle` takes `[String: String]`,
/// and `POST /launch` carries `path=`. A nested parameter would have to be flattened at that
/// boundary anyway, so the document format does not pretend to be richer than the protocol.
enum ControlParameters: Equatable {
    /// The application path of an `app.launch` control. May be empty: well-formedness is decided
    /// where it already lives, by `AppLaunchParameters` at dispatch, so a migration never has to
    /// drop an entry to keep the document valid.
    case appPath(String)

    /// Parameters of an action this build does not model. Preserved verbatim so a document written
    /// by a newer PhoneDeck is not silently truncated — and inert, because `actionParameters` has
    /// no case for them.
    case unmodeled([String: String])

    /// Mirrors `AppLaunchParameters.maximumPathBytes` and the `/launch` wire limit, so a configured
    /// path is never longer than a dispatchable one.
    static let maximumPathBytes = 4096
    static let maximumUnmodeledEntries = 8
    static let maximumUnmodeledKeyBytes = 64
    static let maximumUnmodeledValueBytes = 4096

    /// The one route from configuration to `ActionParameters`. `.unmodeled` deliberately has no
    /// mapping, so no document can make an unregistered action executable: there is no value of
    /// this type that carries an unmodeled action's parameters onto the boundary. What it returns
    /// is still only data — `ActionRegistry.dispatch` re-validates it and re-authorizes against
    /// `Apps.isKnown` regardless of what the document claimed.
    var actionParameters: ActionParameters? {
        switch self {
        case .appPath(let path): return .appPath(path)
        case .unmodeled: return nil
        }
    }
}

/// One configured key: its identity, the action it names, that action's parameters, and how it is
/// labelled.
///
/// `action == .appLaunch` implies `.appPath` parameters. Both directions of the codec enforce that
/// pairing, so a value that violates it can be constructed in memory but cannot be encoded.
struct DeckControl: Equatable {
    let id: ControlID
    let action: ActionID
    let parameters: ControlParameters
    let presentation: ControlPresentation
}

/// A versioned deck configuration.
///
/// There is deliberately no `init()`, no `static let empty` and no accessor that collapses
/// `ConfigurationState` into an optional configuration. There is no default configuration to fall
/// back to, so a malformed or unsupported document cannot degrade into "never configured" by
/// accident — which is the failure mode ADR-007 exists to remove.
struct DeckConfigurationV1: Equatable {
    static let version = 1

    /// Ordered. Order is significant and is never sorted, deduplicated or truncated.
    var controls: [DeckControl]
}

// MARK: Failure model

/// Why a document was rejected.
///
/// Cases carry no payload from the document — not even an offending key name — so configuration
/// content can never reach a log line or an HTTP response by way of an error. That matches
/// `ActionOutcome`'s rule that failures carry no client-supplied detail. The cost is coarser
/// diagnostics: the file is on the Mac's own disk and can be read.
enum ConfigurationError: Error, Equatable {
    case notJSON
    /// The value model produced something `JSONSerialization` will not write. Unreachable for a V1
    /// value, whose members are strings, one integer, arrays and dictionaries; it exists so
    /// `verifiedData` stays total rather than trapping.
    case notSerializable
    case documentTooLarge
    case legacyEntryNotString
    case missingVersion
    case invalidVersion
    case unknownKey
    case missingControls
    case controlsNotArray
    case tooManyControls
    case controlNotObject
    case missingControlID
    case invalidControlID
    case duplicateControlID
    case missingAction
    case invalidActionID
    case invalidParameters
    case invalidPresentation
    /// The encoder's output decoded to a different value than the one it encoded — for example a
    /// control pairing a non-`app.launch` action with `.appPath` parameters, which reads back as
    /// `.unmodeled`. It also covers adding a field to the document without teaching the serializer
    /// about it, which would otherwise drop the field on every write.
    case encoderRoundTripMismatch
}

/// The bytes a codec call was given. Absence and unreadability are storage facts, and they are kept
/// apart because they demand opposite responses: an absent document may be created, while an
/// unreadable one must never be overwritten.
enum ConfigurationInput: Equatable {
    case absent
    case unreadable
    case data(Data)
}

/// Every outcome of reading a configuration, with no two collapsed into one. This is the type that
/// replaces `Launcher.selected()`'s single `nil`, which today means "absent", "unreadable" and
/// "unparseable" at once.
enum ConfigurationState: Equatable {
    case absent
    case unreadable
    case legacy([String])
    case v1(DeckConfigurationV1)
    case malformed(ConfigurationError)
    /// A versioned document from a newer PhoneDeck. Distinct from `.malformed` so the user can be
    /// told to upgrade rather than told their file is broken.
    case unsupportedVersion(found: Int)
}

// MARK: Decoder

/// Pure decoder: bytes to states. Its only input is `ConfigurationInput`, which is also why the
/// test suite needs no home-directory isolation — `NSHomeDirectory()` cannot be redirected with
/// `$HOME` on this macOS build, so any codec that took a path would have been untestable here.
enum ConfigurationDecoder {
    /// Corruption guards, not product policy. Both are far above anything `POST /launcher` can
    /// produce: its body limit is 64 KiB and `Launcher.save` filters to installed application
    /// paths. The 7-slot product limit stays in the client's `APP_SLOTS` today and becomes a
    /// writer-side rule in M2.5; the codec does not encode it.
    static let maximumDocumentBytes = 1024 * 1024
    static let maximumControlCount = 4096

    private static let documentKeys: Set<String> = ["version", "controls"]
    private static let controlKeys: Set<String> = ["id", "action", "parameters", "presentation"]

    static func decode(_ input: ConfigurationInput) -> ConfigurationState {
        switch input {
        case .absent: return .absent
        case .unreadable: return .unreadable
        case .data(let data): return decode(data: data)
        }
    }

    private static func decode(data: Data) -> ConfigurationState {
        // Checked on the bytes, before parsing, so an oversized document is never deserialized.
        guard data.count <= maximumDocumentBytes else { return .malformed(.documentTooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .malformed(.notJSON) }

        // A JSON array is a legacy launcher document; a JSON object is a versioned one. The root
        // type alone discriminates, so no sentinel key or probing is needed.
        if let array = object as? [Any] { return decode(legacyArray: array) }
        // Without `.fragmentsAllowed`, `jsonObject` yields only arrays and dictionaries, so this
        // guard satisfies the compiler rather than catching a runtime case.
        guard let root = object as? [String: Any] else { return .malformed(.notJSON) }

        // The version is identified before any V1 structural or unknown-key check. A document from
        // a newer PhoneDeck will legitimately carry keys V1 has never heard of, and reporting
        // "unknown key" would describe a newer file as a corrupt one.
        guard let versionValue = root["version"] else { return .malformed(.missingVersion) }
        guard let version = integerValue(versionValue) else { return .malformed(.invalidVersion) }
        guard version <= DeckConfigurationV1.version else { return .unsupportedVersion(found: version) }
        // No version below 1 ever existed: a legacy document is a bare array with no version at
        // all. So 0 and -3 are corrupt, not "from the future".
        guard version == DeckConfigurationV1.version else { return .malformed(.invalidVersion) }

        guard root.keys.allSatisfy({ documentKeys.contains($0) }) else { return .malformed(.unknownKey) }
        guard let controlsValue = root["controls"] else { return .malformed(.missingControls) }
        guard let controlArray = controlsValue as? [Any] else { return .malformed(.controlsNotArray) }
        guard controlArray.count <= maximumControlCount else { return .malformed(.tooManyControls) }

        switch controls(controlArray) {
        case .success(let controls): return .v1(DeckConfigurationV1(controls: controls))
        case .failure(let error): return .malformed(error)
        }
    }

    private static func decode(legacyArray array: [Any]) -> ConfigurationState {
        guard array.count <= maximumControlCount else { return .malformed(.tooManyControls) }
        var paths: [String] = []
        paths.reserveCapacity(array.count)
        for element in array {
            guard let path = element as? String else { return .malformed(.legacyEntryNotString) }
            paths.append(path)
        }
        // Order, duplicates, empty entries and an intentionally empty array are all preserved
        // exactly: this is the value `Launcher.selected()` returns today and `GET /launcher`
        // serves, so a migration that filtered or reordered it would move the user's keys.
        return .legacy(paths)
    }

    private static func controls(_ array: [Any]) -> Result<[DeckControl], ConfigurationError> {
        var controls: [DeckControl] = []
        controls.reserveCapacity(array.count)
        var ids = Set<ControlID>()
        for element in array {
            guard let object = element as? [String: Any] else { return .failure(.controlNotObject) }
            switch control(object) {
            case .failure(let error): return .failure(error)
            case .success(let decoded):
                // Uniqueness is a document-level property, so it is checked here rather than by
                // `ControlID`, which can only speak for one value.
                guard ids.insert(decoded.id).inserted else { return .failure(.duplicateControlID) }
                controls.append(decoded)
            }
        }
        return .success(controls)
    }

    private static func control(_ object: [String: Any]) -> Result<DeckControl, ConfigurationError> {
        guard object.keys.allSatisfy({ controlKeys.contains($0) }) else { return .failure(.unknownKey) }
        guard let idValue = object["id"] else { return .failure(.missingControlID) }
        guard let idText = idValue as? String, let id = ControlID(rawValue: idText) else {
            return .failure(.invalidControlID)
        }
        guard let actionValue = object["action"] else { return .failure(.missingAction) }
        // `ActionID` owns identifier syntax and is reused rather than restated, so the document
        // format and the action boundary cannot drift apart about what an identifier looks like.
        guard let actionText = actionValue as? String, let action = ActionID(rawValue: actionText) else {
            return .failure(.invalidActionID)
        }
        switch parameters(object["parameters"], action: action) {
        case .failure(let error): return .failure(error)
        case .success(let parameters):
            switch presentation(object["presentation"]) {
            case .failure(let error): return .failure(error)
            case .success(let presentation):
                return .success(DeckControl(id: id, action: action, parameters: parameters,
                                            presentation: presentation))
            }
        }
    }

    private static func parameters(_ value: Any?, action: ActionID) -> Result<ControlParameters, ConfigurationError> {
        if action == .appLaunch {
            // Exactly one key, and the same name the `/launch` wire parameter already uses.
            guard let object = value as? [String: Any], object.count == 1,
                  let path = object["path"] as? String else { return .failure(.invalidParameters) }
            guard path.utf8.count <= ControlParameters.maximumPathBytes else { return .failure(.invalidParameters) }
            return .success(.appPath(path))
        }
        // Any other syntactically valid identifier: parameters are optional and preserved as flat
        // string data. Being preserved is not being executable — see `actionParameters`.
        guard let value else { return .success(.unmodeled([:])) }
        guard let object = value as? [String: Any] else { return .failure(.invalidParameters) }
        guard object.count <= ControlParameters.maximumUnmodeledEntries else { return .failure(.invalidParameters) }
        var flat: [String: String] = [:]
        for (key, element) in object {
            guard key.utf8.count <= ControlParameters.maximumUnmodeledKeyBytes,
                  let text = element as? String,
                  text.utf8.count <= ControlParameters.maximumUnmodeledValueBytes else {
                return .failure(.invalidParameters)
            }
            flat[key] = text
        }
        return .success(.unmodeled(flat))
    }

    private static func presentation(_ value: Any?) -> Result<ControlPresentation, ConfigurationError> {
        guard let value else { return .success(ControlPresentation(title: nil)) }
        guard let object = value as? [String: Any] else { return .failure(.invalidPresentation) }
        guard object.keys.allSatisfy({ $0 == "title" }) else { return .failure(.unknownKey) }
        guard let titleValue = object["title"] else { return .success(ControlPresentation(title: nil)) }
        guard let title = titleValue as? String, ControlPresentation.isValidTitle(title) else {
            return .failure(.invalidPresentation)
        }
        return .success(ControlPresentation(title: title))
    }

    /// A JSON number that is exactly an integer, and is not a JSON boolean.
    ///
    /// `JSONSerialization` bridges both to `NSNumber` — `__NSCFBoolean` is a subclass — so `as? Int`
    /// accepts `true` and `1.0` alike and `is Bool` is ambiguous for `1`. The CF type identifies the
    /// boolean; exactness against the widened `Double` rejects `1.5` and anything outside `Int`.
    /// `1.0` is accepted as `1`, because JSON has one number type and refusing an exactly integral
    /// value would be surprising.
    private static func integerValue(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let widened = number.doubleValue
        guard let exact = Int(exactly: widened), Double(exact) == widened else { return nil }
        return exact
    }
}

// MARK: Encoder

/// Pure encoder, and exactly as strict as the decoder because it does not restate the decoder's
/// rules: it serializes, then requires its own output to decode back to the value it was given. The
/// two directions therefore cannot drift apart, and an in-memory configuration that could not be
/// read back is rejected here rather than persisted and discovered on the next launch.
enum ConfigurationEncoder {
    static func encode(_ configuration: DeckConfigurationV1) throws -> Data {
        switch verifiedData(configuration) {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    /// Non-throwing form, so migration can hold its result to the same bounds without producing a
    /// document that a later read would reject.
    static func verifiedData(_ configuration: DeckConfigurationV1) -> Result<Data, ConfigurationError> {
        // `.sortedKeys` makes the bytes deterministic, so idempotence is observable; `.prettyPrinted`
        // matches the house style `Launcher.save` already writes.
        guard let data = try? JSONSerialization.data(withJSONObject: documentObject(configuration),
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.notSerializable)
        }
        switch ConfigurationDecoder.decode(.data(data)) {
        case .v1(let decoded) where decoded == configuration: return .success(data)
        case .malformed(let error): return .failure(error)
        default: return .failure(.encoderRoundTripMismatch)
        }
    }

    private static func documentObject(_ configuration: DeckConfigurationV1) -> [String: Any] {
        ["version": DeckConfigurationV1.version,
         "controls": configuration.controls.map { controlObject($0) }]
    }

    private static func controlObject(_ control: DeckControl) -> [String: Any] {
        var object: [String: Any] = [
            "id": control.id.rawValue,
            "action": control.action.rawValue,
            "parameters": parametersObject(control.parameters),
        ]
        // Omitted rather than written as null, so a control with no label round-trips as a control
        // with no `presentation` key.
        if let title = control.presentation.title { object["presentation"] = ["title": title] }
        return object
    }

    private static func parametersObject(_ parameters: ControlParameters) -> [String: String] {
        switch parameters {
        case .appPath(let path): return ["path": path]
        case .unmodeled(let values): return values
        }
    }
}

// MARK: Migration

/// In-memory migration between configuration generations. Nothing here reads or writes a file:
/// ADR-007's "migration runs on read" is realized by the M2.5 storage layer, which supplies the
/// bytes and decides what to persist. `launcher.json` is left on disk untouched.
enum ConfigurationMigrator {
    /// A legacy launcher selection — a bare ordered array of application paths — as a V1 document.
    ///
    /// Purely syntactic: no `Apps.list()`, no `Apps.isKnown`, no normalization, no sorting, no
    /// deduplication and no truncation. Dropping an entry would shift every later key and change
    /// what the phone renders, so an entry that cannot be represented fails the whole migration
    /// loudly instead of vanishing from it. The legacy file on disk is untouched either way.
    ///
    /// Ids are positional (`app-1`, `app-2`, …) because a legacy array may legitimately hold the
    /// same path twice and a path-derived id would collide, turning a valid legacy document into an
    /// invalid V1 one. They are stable from here on: the document, not the position, carries them.
    static func migrateToV1(_ legacy: [String]) -> Result<DeckConfigurationV1, ConfigurationError> {
        guard legacy.count <= ConfigurationDecoder.maximumControlCount else { return .failure(.tooManyControls) }
        var controls: [DeckControl] = []
        controls.reserveCapacity(legacy.count)
        for (index, path) in legacy.enumerated() {
            guard path.utf8.count <= ControlParameters.maximumPathBytes else { return .failure(.invalidParameters) }
            // At most `maximumControlCount` digits, so this is always a valid id.
            guard let id = ControlID(rawValue: "app-\(index + 1)") else { return .failure(.invalidControlID) }
            controls.append(DeckControl(id: id, action: .appLaunch, parameters: .appPath(path),
                                        presentation: ControlPresentation(title: nil)))
        }
        let configuration = DeckConfigurationV1(controls: controls)
        // Success means the result is encodable. A migration that produced a document the encoder
        // would reject — one whose paths together exceed the document cap — would otherwise fail
        // only later, at write time.
        switch ConfigurationEncoder.verifiedData(configuration) {
        case .success: return .success(configuration)
        case .failure(let error): return .failure(error)
        }
    }

    /// The exact inverse of `migrateToV1`, and the shape `GET /launcher` has always served.
    ///
    /// `nil` when the document holds anything the legacy format cannot express. A lossy conversion
    /// is rejected rather than performed, so no caller can silently serve a subset of the user's
    /// deck and report it as the whole thing. An empty document yields `[]`, not `nil`: a
    /// deliberately empty deck is representable, and is not the same as an unrepresentable one.
    static func legacySelection(_ configuration: DeckConfigurationV1) -> [String]? {
        var paths: [String] = []
        paths.reserveCapacity(configuration.controls.count)
        for control in configuration.controls {
            guard control.action == .appLaunch, case .appPath(let path) = control.parameters else { return nil }
            paths.append(path)
        }
        return paths
    }
}
