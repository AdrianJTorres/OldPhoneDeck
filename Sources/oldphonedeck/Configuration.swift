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
    /// The document nests deeper than any V1 value can, so the scanner stops rather than risking
    /// the stack. A depth bound is a safety property of reading untrusted bytes, not a schema cap.
    case tooDeeplyNested
    /// RFC 8259 says names within an object SHOULD be unique. With one ordered parser there is no
    /// first-wins/last-wins rule to fall back on, and an ambiguous `version` would reintroduce
    /// exactly the nondeterminism exact-number parsing removes.
    case duplicateKey
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

// MARK: Strict JSON

/// One parsed JSON value.
///
/// Numbers are kept as their **exact literal text**. That is the only form that has not already
/// been rounded: `JSONSerialization` returns an `NSNumber` whose `Double` has lost the difference
/// between `1` and `1.0000000000000001`, and between `9007199254740993` and `9007199254740992`.
/// Recovering precision after that point is impossible, so the literal is what travels forward.
enum ConfigurationJSONValue {
    /// Ordered name/value pairs. A dictionary would collapse duplicate names silently and make
    /// which `version` wins depend on hash ordering.
    case object([(String, ConfigurationJSONValue)])
    case array([ConfigurationJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var objectMembers: [(String, ConfigurationJSONValue)]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// Value of a member by name. Names are unique — the scanner rejects duplicates — so there is
    /// no first-wins/last-wins ambiguity to guess about.
    func member(_ name: String) -> ConfigurationJSONValue? {
        objectMembers?.first { $0.0 == name }?.1
    }
}

/// A strict RFC 8259 scanner over the document's own bytes.
///
/// `JSONSerialization` is deliberately not used for reading configuration: it accepts trailing
/// commas, and it converts numbers before any caller sees the original token. Both of those are
/// review findings that cannot be fixed on top of it, and adding `Decimal` after the fact would
/// only re-derive a value that has already been rounded. One scanner decides syntax and retains
/// the numeric text, which is also why there are not two parsers here free to disagree.
struct ConfigurationJSONScanner {
    /// No V1 value nests deeper than four levels (document, controls, control, parameters). The
    /// bound exists so a deeply nested document cannot exhaust the stack while parsing; exceeding
    /// it is a rejection rather than a crash.
    static let maximumNestingDepth = 64

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    /// Parses exactly one complete JSON value and requires the whole input to be consumed, so a
    /// document cannot smuggle trailing content past the parser.
    mutating func scanDocument() -> Result<ConfigurationJSONValue, ConfigurationError> {
        do {
            let value = try scanValue()
            skipWhitespace()
            guard index == bytes.count else { throw ScanError.syntax }
            return .success(value)
        } catch let error as ScanError {
            switch error {
            case .syntax: return .failure(.notJSON)
            case .tooDeep: return .failure(.tooDeeplyNested)
            case .duplicateKey: return .failure(.duplicateKey)
            }
        } catch {
            // `ScanError` is the only type thrown above; this arm exists because Swift's `throws`
            // is untyped, not because another error is expected.
            return .failure(.notJSON)
        }
    }

    private enum ScanError: Error { case syntax, tooDeep, duplicateKey }

    private func current() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = current(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maximumNestingDepth else { throw ScanError.tooDeep }
    }

    private mutating func scanValue() throws -> ConfigurationJSONValue {
        skipWhitespace()
        guard let byte = current() else { throw ScanError.syntax }
        switch byte {
        case 0x7B: return try scanObject()                                        // {
        case 0x5B: return try scanArray()                                         // [
        case 0x22: return .string(try scanString())                               // "
        case 0x74: return try scanLiteral("true", .bool(true))
        case 0x66: return try scanLiteral("false", .bool(false))
        case 0x6E: return try scanLiteral("null", .null)
        case 0x2D, 0x30...0x39: return try scanNumber()                           // - 0...9
        default: throw ScanError.syntax
        }
    }

    private mutating func scanLiteral(_ text: String, _ value: ConfigurationJSONValue)
        throws -> ConfigurationJSONValue {
        let literal = [UInt8](text.utf8)
        guard index + literal.count <= bytes.count,
              bytes[index..<(index + literal.count)] == ArraySlice(literal) else { throw ScanError.syntax }
        index += literal.count
        return value
    }

    private mutating func scanObject() throws -> ConfigurationJSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var members: [(String, ConfigurationJSONValue)] = []
        // Names seen in *this* object only. Uniqueness is a property of one object, so a
        // scanner-wide set would falsely reject the same name in two sibling objects — every
        // control repeats `id`, `action` and `parameters`. A set rather than a scan over
        // `members` because the scanner sees every name before any schema rule bounds how many
        // there are, and a linear search per name made a wide object quadratic.
        var names = Set<String>()
        skipWhitespace()
        if current() == 0x7D { index += 1; return .object(members) }               // }
        while true {
            // A name must start every member, so `,}` fails here rather than being waved through.
            skipWhitespace()
            guard current() == 0x22 else { throw ScanError.syntax }
            let name = try scanString()
            guard names.insert(name).inserted else { throw ScanError.duplicateKey }
            skipWhitespace()
            guard current() == 0x3A else { throw ScanError.syntax }                // :
            index += 1
            members.append((name, try scanValue()))
            skipWhitespace()
            switch current() {
            case 0x2C: index += 1                                                  // ,
            case 0x7D: index += 1; return .object(members)
            default: throw ScanError.syntax
            }
        }
    }

    private mutating func scanArray() throws -> ConfigurationJSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var elements: [ConfigurationJSONValue] = []
        skipWhitespace()
        if current() == 0x5D { index += 1; return .array(elements) }               // ]
        while true {
            // A value must follow every comma, so `,]` and `,,` fail inside `scanValue`.
            elements.append(try scanValue())
            skipWhitespace()
            switch current() {
            case 0x2C: index += 1
            case 0x5D: index += 1; return .array(elements)
            default: throw ScanError.syntax
            }
        }
    }

    private mutating func scanString() throws -> String {
        guard current() == 0x22 else { throw ScanError.syntax }
        index += 1
        var utf8: [UInt8] = []
        while true {
            guard let byte = current() else { throw ScanError.syntax }
            if byte == 0x22 { index += 1; break }
            if byte == 0x5C {                                                      // \
                index += 1
                guard let escape = current() else { throw ScanError.syntax }
                index += 1
                switch escape {
                case 0x22: utf8.append(0x22)                                       // "
                case 0x5C: utf8.append(0x5C)                                       // \
                case 0x2F: utf8.append(0x2F)                                       // /
                case 0x62: utf8.append(0x08)                                       // b
                case 0x66: utf8.append(0x0C)                                       // f
                case 0x6E: utf8.append(0x0A)                                       // n
                case 0x72: utf8.append(0x0D)                                       // r
                case 0x74: utf8.append(0x09)                                       // t
                case 0x75: try scanUnicodeEscape(into: &utf8)                      // u
                default: throw ScanError.syntax                                    // \x, \', \0 …
                }
                continue
            }
            // RFC 8259 forbids a raw control character inside a string; it must be escaped.
            guard byte >= 0x20 else { throw ScanError.syntax }
            utf8.append(byte)
            index += 1
        }
        // `String(bytes:encoding:)` returns nil for ill-formed UTF-8 rather than substituting
        // U+FFFD, so invalid byte sequences are a syntax error instead of silent replacement.
        guard let text = String(bytes: utf8, encoding: .utf8) else { throw ScanError.syntax }
        return text
    }

    private mutating func scanUnicodeEscape(into utf8: inout [UInt8]) throws {
        let high = try scanHex4()
        if (0xDC00...0xDFFF).contains(high) { throw ScanError.syntax }             // lone low surrogate
        guard (0xD800...0xDBFF).contains(high) else {
            Self.appendUTF8(UInt32(high), to: &utf8)
            return
        }
        // A high surrogate must be followed by a low one, or the pair is not a character.
        guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
            throw ScanError.syntax
        }
        index += 2
        let low = try scanHex4()
        guard (0xDC00...0xDFFF).contains(low) else { throw ScanError.syntax }
        Self.appendUTF8(UInt32(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)), to: &utf8)
    }

    /// Appends the UTF-8 encoding of a code point.
    ///
    /// Written directly rather than through `Unicode.Scalar`, whose non-failable initializer traps
    /// on a surrogate: this parser reads untrusted bytes, so an invalid value has to be a syntax
    /// error and never a crash. Callers have already rejected D800…DFFF, and a decoded pair cannot
    /// exceed U+10FFFF, so every code point reaching here is encodable. The finished string is
    /// still validated as a whole by `String(bytes:encoding:)`.
    private static func appendUTF8(_ codePoint: UInt32, to utf8: inout [UInt8]) {
        switch codePoint {
        case ..<0x80:
            utf8.append(UInt8(codePoint))
        case ..<0x800:
            utf8.append(0xC0 | UInt8(codePoint >> 6))
            utf8.append(0x80 | UInt8(codePoint & 0x3F))
        case ..<0x10000:
            utf8.append(0xE0 | UInt8(codePoint >> 12))
            utf8.append(0x80 | UInt8((codePoint >> 6) & 0x3F))
            utf8.append(0x80 | UInt8(codePoint & 0x3F))
        default:
            utf8.append(0xF0 | UInt8(codePoint >> 18))
            utf8.append(0x80 | UInt8((codePoint >> 12) & 0x3F))
            utf8.append(0x80 | UInt8((codePoint >> 6) & 0x3F))
            utf8.append(0x80 | UInt8(codePoint & 0x3F))
        }
    }

    private mutating func scanHex4() throws -> Int {
        guard index + 3 < bytes.count else { throw ScanError.syntax }
        var value = 0
        for offset in 0..<4 {
            let byte = bytes[index + offset]
            switch byte {
            case 0x30...0x39: value = value * 16 + Int(byte - 0x30)
            case 0x41...0x46: value = value * 16 + Int(byte - 0x37)                // A...F
            case 0x61...0x66: value = value * 16 + Int(byte - 0x57)                // a...f
            default: throw ScanError.syntax
            }
        }
        index += 4
        return value
    }

    private mutating func scanNumber() throws -> ConfigurationJSONValue {
        let start = index
        if current() == 0x2D { index += 1 }                                        // -
        guard let first = current(), (0x30...0x39).contains(first) else { throw ScanError.syntax }
        if first == 0x30 {
            index += 1
            // `01` is not JSON: a leading zero may only be the whole integer part.
            if let next = current(), (0x30...0x39).contains(next) { throw ScanError.syntax }
        } else {
            while let byte = current(), (0x30...0x39).contains(byte) { index += 1 }
        }
        if current() == 0x2E {                                                     // .
            index += 1
            let fractionStart = index
            while let byte = current(), (0x30...0x39).contains(byte) { index += 1 }
            guard index > fractionStart else { throw ScanError.syntax }
        }
        if let exponent = current(), exponent == 0x65 || exponent == 0x45 {        // e E
            index += 1
            if let sign = current(), sign == 0x2B || sign == 0x2D { index += 1 }    // + -
            let exponentStart = index
            while let byte = current(), (0x30...0x39).contains(byte) { index += 1 }
            guard index > exponentStart else { throw ScanError.syntax }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }
}

/// Exact interpretation of a JSON number's literal text, with no floating-point step anywhere.
enum ExactJSONNumber {
    /// The exact mathematical value as an `Int`, or nil when the literal is not an integer or does
    /// not fit `Int`. Nothing here widens through `Double` or `NSNumber`, so `1.0000000000000001`
    /// is not `1`, `0.99999999999999999` is not `1`, and `9007199254740993` keeps every digit
    /// instead of arriving as `9007199254740992`.
    ///
    /// A token is integral only when its exact mathematical value is an integer, so `1.0` and
    /// `1e0` and `1.5e1` are integral while `1.5` and `1e-1` are not.
    static func exactInteger(_ literal: String) -> Int? {
        let bytes = [UInt8](literal.utf8)
        var cursor = 0
        var negative = false
        if cursor < bytes.count, bytes[cursor] == 0x2D { negative = true; cursor += 1 }

        var mantissa: [UInt8] = []
        var fractionCount = 0
        while cursor < bytes.count, isDigit(bytes[cursor]) { mantissa.append(bytes[cursor]); cursor += 1 }
        guard !mantissa.isEmpty else { return nil }
        if cursor < bytes.count, bytes[cursor] == 0x2E {
            cursor += 1
            let fractionStart = mantissa.count
            while cursor < bytes.count, isDigit(bytes[cursor]) { mantissa.append(bytes[cursor]); cursor += 1 }
            fractionCount = mantissa.count - fractionStart
            guard fractionCount > 0 else { return nil }
        }
        var exponent = 0
        if cursor < bytes.count, bytes[cursor] == 0x65 || bytes[cursor] == 0x45 {
            cursor += 1
            var exponentNegative = false
            if cursor < bytes.count, bytes[cursor] == 0x2B || bytes[cursor] == 0x2D {
                exponentNegative = bytes[cursor] == 0x2D
                cursor += 1
            }
            var digits = 0
            while cursor < bytes.count, isDigit(bytes[cursor]) {
                // Saturate rather than overflow: an exponent this large cannot produce a value
                // inside `Int`, and saturating still yields the right answer without trapping.
                if exponent < 1_000_000 { exponent = exponent * 10 + Int(bytes[cursor] - 0x30) }
                digits += 1
                cursor += 1
            }
            guard digits > 0 else { return nil }
            if exponentNegative { exponent = -exponent }
        }
        // The scanner already guaranteed the grammar; this keeps the function total on its own.
        guard cursor == bytes.count else { return nil }

        // Exact value = mantissa × 10^(exponent − fractionCount). Move the point inside the digit
        // string; the value is an integer only when nothing significant lands after it.
        let shift = exponent - fractionCount
        let integerDigits: [UInt8]
        if shift >= 0 {
            let whole = dropLeadingZeros(mantissa)
            if whole.isEmpty { return 0 }
            // Length is checked before any zeros are appended, so `1e999999999` cannot allocate.
            guard whole.count + shift <= 19 else { return nil }
            integerDigits = whole + [UInt8](repeating: 0x30, count: shift)
        } else {
            let fractional = -shift
            guard fractional < mantissa.count else {
                // Every significant digit sits after the point: integral only if the value is zero.
                return mantissa.allSatisfy({ $0 == 0x30 }) ? 0 : nil
            }
            guard mantissa.suffix(fractional).allSatisfy({ $0 == 0x30 }) else { return nil }
            integerDigits = [UInt8](mantissa.prefix(mantissa.count - fractional))
        }
        let whole = dropLeadingZeros(integerDigits)
        if whole.isEmpty { return 0 }
        // 19 digits is the widest an `Int` can be; `Int(_:)` then rejects the few 19-digit values
        // that still overflow, returning nil rather than trapping. That is what makes
        // `9223372036854775807` exact and `9223372036854775808` a clean rejection.
        guard whole.count <= 19 else { return nil }
        return Int((negative ? "-" : "") + String(decoding: whole, as: UTF8.self))
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func dropLeadingZeros(_ digits: [UInt8]) -> [UInt8] {
        var start = 0
        while start < digits.count, digits[start] == 0x30 { start += 1 }
        return [UInt8](digits[start...])
    }
}

// MARK: Canonical form

/// The one canonical wire form of a V1 document: pretty-printed with sorted keys, which is also
/// what `Launcher.save` already writes for the legacy file.
///
/// Both directions use it, so "fits when read" and "fits when written" are the same claim about
/// the same bytes. That is what makes the size contract hold: a document the decoder accepts can
/// always be encoded unchanged, instead of being valid on disk one way and unsaveable the other.
enum ConfigurationCanonicalForm {
    static func data(_ configuration: DeckConfigurationV1) -> Data? {
        try? JSONSerialization.data(withJSONObject: documentObject(configuration),
                                    options: [.prettyPrinted, .sortedKeys])
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
        var scanner = ConfigurationJSONScanner(data)
        let root: ConfigurationJSONValue
        switch scanner.scanDocument() {
        case .success(let value): root = value
        case .failure(let error): return .malformed(error)
        }

        // A JSON array is a legacy launcher document; a JSON object is a versioned one. The root
        // type alone discriminates, so no sentinel key or probing is needed. A top-level scalar is
        // valid JSON but is not a configuration document.
        if case .array(let elements) = root { return decode(legacyArray: elements) }
        guard case .object(let members) = root else { return .malformed(.notJSON) }

        // The version is identified before any V1 structural or unknown-key check. A document from
        // a newer PhoneDeck will legitimately carry keys V1 has never heard of, and reporting
        // "unknown key" would describe a newer file as a corrupt one.
        guard let versionValue = root.member("version") else { return .malformed(.missingVersion) }
        // The version comes from the number's own literal text, never from a `Double` or an
        // `NSNumber` that has already been rounded. See `ExactJSONNumber`.
        guard case .number(let literal) = versionValue,
              let version = ExactJSONNumber.exactInteger(literal) else { return .malformed(.invalidVersion) }
        guard version <= DeckConfigurationV1.version else { return .unsupportedVersion(found: version) }
        // No version below 1 ever existed: a legacy document is a bare array with no version at
        // all. So 0 and -3 are corrupt, not "from the future".
        guard version == DeckConfigurationV1.version else { return .malformed(.invalidVersion) }

        guard members.allSatisfy({ documentKeys.contains($0.0) }) else { return .malformed(.unknownKey) }
        guard let controlsValue = root.member("controls") else { return .malformed(.missingControls) }
        guard case .array(let controlArray) = controlsValue else { return .malformed(.controlsNotArray) }
        guard controlArray.count <= maximumControlCount else { return .malformed(.tooManyControls) }

        switch controls(controlArray) {
        case .success(let controls):
            let configuration = DeckConfigurationV1(controls: controls)
            // Canonical size contract: a document is accepted only if the form this codec would
            // write it back in also fits the cap. Pretty-printing expands a compact document, so
            // without this check a configuration can be valid when read and impossible to save
            // unchanged. Uses the shared canonical form rather than calling the encoder, so the
            // two directions do not recurse into each other.
            guard let canonical = ConfigurationCanonicalForm.data(configuration),
                  canonical.count <= maximumDocumentBytes else { return .malformed(.documentTooLarge) }
            return .v1(configuration)
        case .failure(let error): return .malformed(error)
        }
    }

    private static func decode(legacyArray array: [ConfigurationJSONValue]) -> ConfigurationState {
        guard array.count <= maximumControlCount else { return .malformed(.tooManyControls) }
        var paths: [String] = []
        paths.reserveCapacity(array.count)
        for element in array {
            guard case .string(let path) = element else { return .malformed(.legacyEntryNotString) }
            paths.append(path)
        }
        // Order, duplicates, empty entries and an intentionally empty array are all preserved
        // exactly: this is the value `Launcher.selected()` returns today and `GET /launcher`
        // serves, so a migration that filtered or reordered it would move the user's keys.
        return .legacy(paths)
    }

    private static func controls(_ array: [ConfigurationJSONValue]) -> Result<[DeckControl], ConfigurationError> {
        var controls: [DeckControl] = []
        controls.reserveCapacity(array.count)
        var ids = Set<ControlID>()
        for element in array {
            guard case .object(let members) = element else { return .failure(.controlNotObject) }
            switch control(members) {
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

    private static func control(_ members: [(String, ConfigurationJSONValue)])
        -> Result<DeckControl, ConfigurationError> {
        guard members.allSatisfy({ controlKeys.contains($0.0) }) else { return .failure(.unknownKey) }
        guard let idValue = member("id", in: members) else { return .failure(.missingControlID) }
        guard case .string(let idText) = idValue, let id = ControlID(rawValue: idText) else {
            return .failure(.invalidControlID)
        }
        guard let actionValue = member("action", in: members) else { return .failure(.missingAction) }
        // `ActionID` owns identifier syntax and is reused rather than restated, so the document
        // format and the action boundary cannot drift apart about what an identifier looks like.
        guard case .string(let actionText) = actionValue, let action = ActionID(rawValue: actionText) else {
            return .failure(.invalidActionID)
        }
        switch parameters(member("parameters", in: members), action: action) {
        case .failure(let error): return .failure(error)
        case .success(let parameters):
            switch presentation(member("presentation", in: members)) {
            case .failure(let error): return .failure(error)
            case .success(let presentation):
                return .success(DeckControl(id: id, action: action, parameters: parameters,
                                            presentation: presentation))
            }
        }
    }

    private static func member(_ name: String, in members: [(String, ConfigurationJSONValue)])
        -> ConfigurationJSONValue? {
        members.first { $0.0 == name }?.1
    }

    private static func parameters(_ value: ConfigurationJSONValue?, action: ActionID)
        -> Result<ControlParameters, ConfigurationError> {
        if action == .appLaunch {
            // Exactly one member, named the same as the `/launch` wire parameter already uses.
            guard let members = value?.objectMembers, members.count == 1,
                  let (key, pathValue) = members.first, key == "path",
                  case .string(let path) = pathValue else { return .failure(.invalidParameters) }
            guard path.utf8.count <= ControlParameters.maximumPathBytes else { return .failure(.invalidParameters) }
            return .success(.appPath(path))
        }
        // Any other syntactically valid identifier: parameters are optional and preserved as flat
        // string data. Being preserved is not being executable — see `actionParameters`.
        guard let value else { return .success(.unmodeled([:])) }
        guard let members = value.objectMembers else { return .failure(.invalidParameters) }
        guard members.count <= ControlParameters.maximumUnmodeledEntries else { return .failure(.invalidParameters) }
        var flat: [String: String] = [:]
        for (key, element) in members {
            guard key.utf8.count <= ControlParameters.maximumUnmodeledKeyBytes,
                  case .string(let text) = element,
                  text.utf8.count <= ControlParameters.maximumUnmodeledValueBytes else {
                return .failure(.invalidParameters)
            }
            flat[key] = text
        }
        return .success(.unmodeled(flat))
    }

    private static func presentation(_ value: ConfigurationJSONValue?)
        -> Result<ControlPresentation, ConfigurationError> {
        guard let value else { return .success(ControlPresentation(title: nil)) }
        guard let members = value.objectMembers else { return .failure(.invalidPresentation) }
        guard members.allSatisfy({ $0.0 == "title" }) else { return .failure(.unknownKey) }
        guard let titleValue = members.first?.1 else { return .success(ControlPresentation(title: nil)) }
        guard case .string(let title) = titleValue, ControlPresentation.isValidTitle(title) else {
            return .failure(.invalidPresentation)
        }
        return .success(ControlPresentation(title: title))
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
        guard let data = ConfigurationCanonicalForm.data(configuration) else { return .failure(.notSerializable) }
        switch ConfigurationDecoder.decode(.data(data)) {
        case .v1(let decoded) where decoded == configuration: return .success(data)
        case .malformed(let error): return .failure(error)
        default: return .failure(.encoderRoundTripMismatch)
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

    /// The lossless inverse of `migrateToV1`, and the shape `GET /launcher` has always served.
    ///
    /// This is a reverse conversion, not a projection: it returns a selection **only** when
    /// migrating that selection back reproduces `configuration` exactly. So it rejects an unknown
    /// or unregistered action, `.unmodeled` parameters, any presentation title, and any control id
    /// migration would not have synthesized — a custom id, a reordered id, or a gap in the
    /// sequence. All of those carry information a bare path list cannot hold, and returning the
    /// paths anyway would silently discard it while reporting a subset of the user's deck as
    /// though it were the whole thing.
    ///
    /// The invariant holds by construction rather than by restating migration's rules: the
    /// candidate selection is migrated back and compared, exactly as the encoder validates by
    /// decoding its own output. The two directions therefore cannot drift apart. The cost is one
    /// extra pass over the document per call, which is acceptable on a configuration read path.
    ///
    /// An empty document yields `[]`, not `nil`: a deliberately empty deck round-trips, and is not
    /// the same as an unrepresentable one.
    static func legacySelection(_ configuration: DeckConfigurationV1) -> [String]? {
        var paths: [String] = []
        paths.reserveCapacity(configuration.controls.count)
        for control in configuration.controls {
            guard control.action == .appLaunch, case .appPath(let path) = control.parameters else { return nil }
            paths.append(path)
        }
        guard case .success(let reconstructed) = migrateToV1(paths), reconstructed == configuration else {
            return nil
        }
        return paths
    }
}
