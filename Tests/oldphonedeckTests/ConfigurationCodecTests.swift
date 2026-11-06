import Foundation
import Testing
@testable import oldphonedeck

// MARK: Fixtures

/// A V1 document holding `controls`, as wire text.
private func document(_ controls: String) -> String { "{\"version\":1,\"controls\":[\(controls)]}" }

/// One control, as wire text. `parameters` and `presentation` are inserted verbatim so a test states
/// the exact JSON it means rather than building a dictionary and hoping about it.
private func control(id: String = "a", action: String = "app.launch",
                     parameters: String? = "{\"path\":\"/Applications/Safari.app\"}",
                     presentation: String? = nil) -> String {
    var text = "{\"id\":\"\(id)\",\"action\":\"\(action)\""
    if let parameters { text += ",\"parameters\":\(parameters)" }
    if let presentation { text += ",\"presentation\":\(presentation)" }
    return text + "}"
}

private func decode(_ json: String) -> ConfigurationState { ConfigurationDecoder.decode(.data(Data(json.utf8))) }

/// The configuration a document decoded to, recording an issue if it decoded to anything else.
private func configuration(_ json: String,
                           sourceLocation: SourceLocation = #_sourceLocation) -> DeckConfigurationV1? {
    let state = decode(json)
    guard case .v1(let decoded) = state else {
        Issue.record("Expected a V1 document, got \(state)", sourceLocation: sourceLocation)
        return nil
    }
    return decoded
}

private func appControl(id: String = "a", path: String = "/Applications/Safari.app",
                        title: String? = nil) -> DeckControl {
    DeckControl(id: ControlID(rawValue: id)!, action: .appLaunch, parameters: .appPath(path),
                presentation: ControlPresentation(title: title))
}

private func unmodeledControl(id: String = "b", action: String = "app.quit",
                              parameters: [String: String] = [:]) -> DeckControl {
    DeckControl(id: ControlID(rawValue: id)!, action: ActionID(rawValue: action)!,
                parameters: .unmodeled(parameters), presentation: ControlPresentation(title: nil))
}

/// An application-path-shaped string of exactly `bytes` UTF-8 bytes.
private func path(ofBytes bytes: Int) -> String { "/" + String(repeating: "a", count: bytes - 5) + ".app" }

/// Asserts that encoding throws one specific `ConfigurationError`, in the do/catch style the rest of
/// this suite uses.
private func expectEncodingFailure(_ expected: ConfigurationError, of value: DeckConfigurationV1,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try ConfigurationEncoder.encode(value)
        Issue.record("Expected the encoder to reject the configuration", sourceLocation: sourceLocation)
    } catch let error as ConfigurationError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected a ConfigurationError, got \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: A. Absent, unreadable and legacy inputs

struct ConfigurationInputStateTests {
    @Test func absentInputIsAbsent() {
        #expect(ConfigurationDecoder.decode(.absent) == .absent)
    }

    @Test func unreadableInputIsDistinctFromAbsent() {
        // Absence may be answered by creating a configuration; unreadability may not be answered by
        // overwriting one. Collapsing the two is how a recoverable file becomes a lost one, which is
        // the failure mode ADR-007 exists to remove.
        #expect(ConfigurationDecoder.decode(.unreadable) == .unreadable)
        #expect(ConfigurationDecoder.decode(.unreadable) != .absent)
        #expect(ConfigurationDecoder.decode(.absent) != .unreadable)
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func emptyAndWhitespaceOnlyDataIsMalformedNotAbsent(_ json: String) {
        #expect(decode(json) == .malformed(.notJSON))
        #expect(decode(json) != .absent)
        #expect(decode(json) != .unreadable)
    }
}

struct LegacyDecodeTests {
    @Test func bareArrayOfStringsIsLegacyInOrder() {
        #expect(decode(#"["/b.app","/a.app","/c.app"]"#) == .legacy(["/b.app", "/a.app", "/c.app"]))
    }

    @Test func emptyArrayIsLegacyAndDistinctFromAbsent() {
        // An intentionally empty deck is a configuration, not the absence of one.
        #expect(decode("[]") == .legacy([]))
        #expect(decode("[]") != .absent)
        #expect(decode("[]") != .malformed(.notJSON))
    }

    @Test func emptyStringEntriesArePreserved() {
        #expect(decode(#"["","/a.app",""]"#) == .legacy(["", "/a.app", ""]))
    }

    @Test func duplicatesArePreserved() {
        #expect(decode(#"["/a.app","/a.app","/b.app","/a.app"]"#)
            == .legacy(["/a.app", "/a.app", "/b.app", "/a.app"]))
    }

    @Test func legacyOrderIsNeverSorted() {
        #expect(decode(#"["/z.app","/m.app","/a.app"]"#) == .legacy(["/z.app", "/m.app", "/a.app"]))
    }

    @Test(arguments: [#"["/a.app",1]"#, #"[[1]]"#, "[null]", "[true]", #"[{"/a.app":1}]"#, #"["/a.app",[]]"#])
    func aNonStringEntryIsMalformed(_ json: String) {
        #expect(decode(json) == .malformed(.legacyEntryNotString))
    }

    @Test func aLegacyArrayIsNotMistakenForV1() {
        #expect(decode(#"["/a.app"]"#) != .v1(DeckConfigurationV1(controls: [])))
    }
}

// MARK: B. Valid V1 documents

struct V1DecodeTests {
    @Test func minimalDocumentDecodes() {
        #expect(decode(document("")) == .v1(DeckConfigurationV1(controls: [])))
    }

    @Test func singleAppControlDecodes() {
        let expected = DeckConfigurationV1(controls: [appControl(id: "app-1")])
        #expect(decode(document(control(id: "app-1"))) == .v1(expected))
    }

    @Test func aTitleDecodes() {
        let expected = DeckConfigurationV1(controls: [appControl(title: "Build")])
        #expect(decode(document(control(presentation: "{\"title\":\"Build\"}"))) == .v1(expected))
    }

    @Test func anEmptyPresentationObjectDecodes() {
        let expected = DeckConfigurationV1(controls: [appControl()])
        #expect(decode(document(control(presentation: "{}"))) == .v1(expected))
    }

    @Test func aNonASCIITitleDecodes() {
        let expected = DeckConfigurationV1(controls: [appControl(title: "Café · 终端")])
        #expect(decode(document(control(presentation: "{\"title\":\"Café · 终端\"}"))) == .v1(expected))
    }

    @Test func anUnregisteredActionDecodesAsUnmodeled() {
        let decoded = configuration(document(control(action: "media.next", parameters: "{\"name\":\"x\"}")))
        #expect(decoded?.controls.first?.parameters == .unmodeled(["name": "x"]))
    }

    @Test func anUnregisteredActionMayOmitParameters() {
        let decoded = configuration(document(control(action: "media.next", parameters: nil)))
        #expect(decoded?.controls.first?.parameters == .unmodeled([:]))
    }

    @Test func unmodeledParametersArePreservedVerbatim() {
        let json = control(action: "app.quit", parameters: "{\"a\":\"1\",\"b\":\"2\",\"c\":\"\"}")
        let decoded = configuration(document(json))
        #expect(decoded?.controls.first?.parameters == .unmodeled(["a": "1", "b": "2", "c": ""]))
    }

    @Test func keyOrderIsIrrelevant() {
        let permuted = #"{"controls":[{"parameters":{"path":"/Applications/Safari.app"},"action":"app.launch","id":"a"}],"version":1}"#
        #expect(decode(document(control())) == decode(permuted))
    }

    @Test func anIntegralFloatVersionIsAccepted() {
        // JSON has one number type, so refusing an exactly integral value would be surprising.
        #expect(decode(#"{"version":1.0,"controls":[]}"#) == .v1(DeckConfigurationV1(controls: [])))
    }

    @Test func anEmptyControlListIsDistinctFromAbsentAndFromLegacy() {
        #expect(decode(document("")) != .absent)
        #expect(decode(document("")) != .legacy([]))
    }

    @Test func multipleControlsKeepTheirOrder() {
        let json = [control(id: "a"), control(id: "b")].joined(separator: ",")
        #expect(configuration(document(json))?.controls.map(\.id.rawValue) == ["a", "b"])
    }
}

// MARK: C. Version handling

struct VersionHandlingTests {
    @Test(arguments: [2, 3, 99, 1000])
    func aNewerVersionIsUnsupportedNotMalformed(_ version: Int) {
        let json = "{\"version\":\(version),\"controls\":[]}"
        #expect(decode(json) == .unsupportedVersion(found: version))
        #expect(decode(json) != .malformed(.invalidVersion))
    }

    @Test func aFutureVersionIsIdentifiedBeforeUnknownKeyChecks() {
        // A V2 document will legitimately carry keys V1 has never heard of. Reporting "unknown key"
        // would tell the user their file is corrupt when the truth is that it is newer.
        let json = #"{"version":2,"layout":{"rows":3},"unexpected":true,"controls":[]}"#
        #expect(decode(json) == .unsupportedVersion(found: 2))
    }

    @Test func aFutureVersionIsIdentifiedBeforeStructuralChecks() {
        #expect(decode(#"{"version":7}"#) == .unsupportedVersion(found: 7))
        #expect(decode(#"{"version":7,"controls":"not-an-array"}"#) == .unsupportedVersion(found: 7))
    }

    @Test(arguments: [0, -1, -99])
    func aVersionBelowOneIsMalformedNotFuture(_ version: Int) {
        // No version below 1 ever existed: a legacy document is a bare array with no version at all.
        // Reporting -3 as "from the future" would tell the user to upgrade a corrupt file.
        #expect(decode("{\"version\":\(version),\"controls\":[]}") == .malformed(.invalidVersion))
    }

    @Test func aMissingVersionIsMalformed() {
        #expect(decode(#"{"controls":[]}"#) == .malformed(.missingVersion))
        #expect(decode("{}") == .malformed(.missingVersion))
    }

    @Test(arguments: [#"{"version":"1","controls":[]}"#, #"{"version":true,"controls":[]}"#,
                      #"{"version":false,"controls":[]}"#, #"{"version":1.5,"controls":[]}"#,
                      #"{"version":null,"controls":[]}"#, #"{"version":[1],"controls":[]}"#,
                      #"{"version":{},"controls":[]}"#, #"{"version":-0.5,"controls":[]}"#])
    func aNonIntegerVersionIsMalformed(_ json: String) {
        // `JSONSerialization` bridges booleans to `NSNumber`, so `true` must not read as version 1.
        #expect(decode(json) == .malformed(.invalidVersion))
    }

    @Test func aVersionBeyondIntIsMalformed() {
        #expect(decode(#"{"version":1e30,"controls":[]}"#) == .malformed(.invalidVersion))
    }
}

// MARK: D. Document strictness and bounds

struct DocumentStrictnessTests {
    @Test func anUnknownTopLevelKeyIsMalformed() {
        #expect(decode(#"{"version":1,"controls":[],"layout":{}}"#) == .malformed(.unknownKey))
    }

    @Test func anUnknownControlKeyIsMalformed() {
        let json = "{\"id\":\"a\",\"action\":\"app.launch\",\"parameters\":{\"path\":\"/a.app\"},\"enabled\":true}"
        #expect(decode(document(json)) == .malformed(.unknownKey))
    }

    @Test func anUnknownPresentationKeyIsMalformed() {
        let json = document(control(presentation: "{\"title\":\"x\",\"colour\":\"red\"}"))
        #expect(decode(json) == .malformed(.unknownKey))
    }

    @Test func missingControlsIsMalformed() {
        #expect(decode(#"{"version":1}"#) == .malformed(.missingControls))
    }

    @Test(arguments: [#"{"version":1,"controls":{}}"#, #"{"version":1,"controls":"x"}"#,
                      #"{"version":1,"controls":null}"#, #"{"version":1,"controls":0}"#,
                      #"{"version":1,"controls":true}"#])
    func controlsMustBeAnArray(_ json: String) {
        #expect(decode(json) == .malformed(.controlsNotArray))
    }

    @Test(arguments: [#"{"version":1,"controls":[1]}"#, #"{"version":1,"controls":[[]]}"#,
                      #"{"version":1,"controls":[null]}"#, #"{"version":1,"controls":["a"]}"#,
                      #"{"version":1,"controls":[true]}"#])
    func aControlMustBeAnObject(_ json: String) {
        #expect(decode(json) == .malformed(.controlNotObject))
    }

    @Test(arguments: ["{", "null", "3", "\"x\"", "true", "[1,2", "{}extra", "{version:1}"])
    func nonJSONAndTopLevelFragmentsAreMalformed(_ json: String) {
        #expect(decode(json) == .malformed(.notJSON))
    }

    @Test func aDocumentLargerThanTheCapIsMalformed() {
        let oversized = Data(repeating: 0x78, count: ConfigurationDecoder.maximumDocumentBytes + 1)
        #expect(ConfigurationDecoder.decode(.data(oversized)) == .malformed(.documentTooLarge))
    }

    @Test func aDocumentExactlyAtTheCapStillDecodes() {
        var bytes = Data(document("").utf8)
        bytes.append(Data(repeating: 0x20, count: ConfigurationDecoder.maximumDocumentBytes - bytes.count))
        #expect(bytes.count == ConfigurationDecoder.maximumDocumentBytes)
        #expect(ConfigurationDecoder.decode(.data(bytes)) == .v1(DeckConfigurationV1(controls: [])))
    }

    @Test func moreControlsThanTheCapIsMalformed() {
        let count = ConfigurationDecoder.maximumControlCount + 1
        let controls = (1...count).map { control(id: "a\($0)") }.joined(separator: ",")
        #expect(decode(document(controls)) == .malformed(.tooManyControls))
    }

    @Test func aControlCountExactlyAtTheCapDecodes() {
        let count = ConfigurationDecoder.maximumControlCount
        let controls = (1...count).map { control(id: "a\($0)") }.joined(separator: ",")
        guard case .v1(let decoded) = decode(document(controls)) else {
            Issue.record("Expected a V1 document at the control cap")
            return
        }
        #expect(decoded.controls.count == count)
    }
}

// MARK: E. Control identity

struct ControlIDTests {
    @Test(arguments: ["", "A", "KEY", "key 1", "key_1", "key.1", "-key", "key-", "key\n", "kéy",
                      "/bin/sh", "app-1 ", String(repeating: "a", count: ControlID.maximumLength + 1)])
    func aMalformedIDCannotBeConstructed(_ raw: String) {
        #expect(ControlID(rawValue: raw) == nil)
    }

    @Test(arguments: ["a", "0", "app-1", "a1", "build-terminal", "a--b",
                      String(repeating: "a", count: ControlID.maximumLength)])
    func aWellFormedIDIsAccepted(_ raw: String) {
        #expect(ControlID(rawValue: raw)?.rawValue == raw)
    }

    @Test func duplicateIDsInOneDocumentAreMalformed() {
        let adjacent = document([control(id: "a"), control(id: "a")].joined(separator: ","))
        let distant = document([control(id: "a"), control(id: "b"), control(id: "a")].joined(separator: ","))
        #expect(decode(adjacent) == .malformed(.duplicateControlID))
        #expect(decode(distant) == .malformed(.duplicateControlID))
    }

    @Test func theSamePathUnderTwoIDsIsValid() {
        // Identity is the id, not the target: two keys may launch the same application.
        let json = [control(id: "a"), control(id: "b")].joined(separator: ",")
        #expect(configuration(document(json))?.controls.count == 2)
    }

    @Test func aMissingIDIsMalformed() {
        #expect(decode(document(#"{"action":"app.launch","parameters":{"path":"/a.app"}}"#))
            == .malformed(.missingControlID))
    }

    @Test(arguments: [#"{"id":1,"action":"app.launch"}"#, #"{"id":null,"action":"app.launch"}"#,
                      #"{"id":true,"action":"app.launch"}"#, #"{"id":[],"action":"app.launch"}"#])
    func aNonStringIDIsMalformed(_ json: String) {
        #expect(decode(document(json)) == .malformed(.invalidControlID))
    }

    @Test func aMalformedIDInADocumentIsMalformed() {
        #expect(decode(document(control(id: "Not Valid"))) == .malformed(.invalidControlID))
    }
}

// MARK: F. Configured actions

struct ConfiguredActionTests {
    @Test(arguments: ["App.Launch", "APP.LAUNCH", "app..launch", ".app.launch", "app.launch.",
                      "/bin/sh", "app.launch;rm", "app.launch ", "", "app launch",
                      String(repeating: "a", count: ActionID.maximumLength + 1)])
    func aMalformedActionIDIsRejected(_ raw: String) {
        // Identifier syntax is `ActionID`'s rule, reused rather than restated, so the document
        // format and the action boundary cannot drift apart about what an identifier looks like.
        #expect(decode(document(control(action: raw))) == .malformed(.invalidActionID))
    }

    @Test func aMissingActionIsMalformed() {
        #expect(decode(document(#"{"id":"a","parameters":{"path":"/a.app"}}"#)) == .malformed(.missingAction))
    }

    @Test(arguments: [#"{"id":"a","action":1}"#, #"{"id":"a","action":null}"#, #"{"id":"a","action":true}"#])
    func aNonStringActionIsMalformed(_ json: String) {
        #expect(decode(document(json)) == .malformed(.invalidActionID))
    }

    @Test(arguments: ["app.quit", "shell.exec", "media.next", "shortcut.run", "admin.everything",
                      "app.relaunch", "git.push", "system.shutdown"])
    func anUnregisteredActionDecodesButIsNotExecutable(_ raw: String) {
        // Validity and executability are different questions. A document naming an action this build
        // does not model still decodes, so removing an action from the code cannot invalidate a
        // user's whole deck — but nothing about it becomes runnable.
        let decoded = configuration(document(control(action: raw, parameters: "{\"name\":\"x\"}")))
        let parameters = decoded?.controls.first?.parameters
        #expect(parameters == .unmodeled(["name": "x"]))
        #expect(parameters?.actionParameters == nil)
    }

    @Test func configurationDoesNotRegisterAnAction() {
        // The registry's descriptor table is the only thing that makes an action executable, and a
        // document is not an input to it. Uses the injecting initializer from
        // `ActionRegistryTests.swift`; no test may construct the production `ActionRegistry()`.
        let registry = testRegistry(recorder: LaunchRecorder())
        #expect(registry.descriptor(for: .appLaunch) != nil)
        for raw in ["app.quit", "shell.exec", "media.next", "shortcut.run"] {
            guard let id = ActionID(rawValue: raw) else {
                Issue.record("\(raw) should be syntactically valid")
                continue
            }
            #expect(registry.descriptor(for: id) == nil)
            #expect(id != .appLaunch)
        }
    }
}

// MARK: G. Parameters

struct ParameterTests {
    @Test func appLaunchRequiresExactlyOnePathKey() {
        #expect(decode(document(control(parameters: "{}"))) == .malformed(.invalidParameters))
        #expect(decode(document(control(parameters: #"{"path":"/a.app","extra":"x"}"#)))
            == .malformed(.invalidParameters))
        #expect(decode(document(control(parameters: #"{"Path":"/a.app"}"#))) == .malformed(.invalidParameters))
        #expect(decode(document(control(parameters: #"{"appPath":"/a.app"}"#))) == .malformed(.invalidParameters))
    }

    @Test(arguments: [#"{"path":1}"#, #"{"path":null}"#, #"{"path":["/a.app"]}"#, #"{"path":{}}"#,
                      #"{"path":true}"#])
    func anAppLaunchPathMustBeAString(_ parameters: String) {
        #expect(decode(document(control(parameters: parameters))) == .malformed(.invalidParameters))
    }

    @Test func anEmptyPathIsPreservedNotRejected() {
        // `Launcher.save` cannot store "", but a hand-edited legacy file can, and dropping it would
        // shift every later key. Well-formedness belongs to `AppLaunchParameters` at dispatch, which
        // rejects it exactly as `POST /launch` does today.
        let expected = DeckConfigurationV1(controls: [appControl(path: "")])
        #expect(decode(document(control(parameters: #"{"path":""}"#))) == .v1(expected))
    }

    @Test func aPathLongerThanTheCapIsMalformed() {
        let long = path(ofBytes: ControlParameters.maximumPathBytes + 1)
        #expect(decode(document(control(parameters: "{\"path\":\"\(long)\"}")))
            == .malformed(.invalidParameters))
    }

    @Test func aPathExactlyAtTheCapDecodes() {
        let exact = path(ofBytes: ControlParameters.maximumPathBytes)
        #expect(exact.utf8.count == ControlParameters.maximumPathBytes)
        let expected = DeckConfigurationV1(controls: [appControl(path: exact)])
        #expect(decode(document(control(parameters: "{\"path\":\"\(exact)\"}"))) == .v1(expected))
    }

    @Test func missingParametersForAppLaunchIsMalformed() {
        #expect(decode(document(control(parameters: nil))) == .malformed(.invalidParameters))
    }

    @Test(arguments: [#"{"a":{"b":"c"}}"#, #"{"a":["b"]}"#, #"{"a":1}"#, #"{"a":null}"#, #"{"a":true}"#])
    func nestedOrNonStringParametersAreMalformed(_ parameters: String) {
        // Values are flat strings, the shape the existing wire protocol already uses. Flatness is
        // also what makes `.unmodeled` `Equatable`, and therefore what makes round trips exact.
        #expect(decode(document(control(action: "app.quit", parameters: parameters)))
            == .malformed(.invalidParameters))
    }

    @Test func tooManyUnmodeledParametersIsMalformed() {
        let entries = (1...ControlParameters.maximumUnmodeledEntries + 1)
            .map { "\"k\($0)\":\"v\"" }.joined(separator: ",")
        #expect(decode(document(control(action: "app.quit", parameters: "{\(entries)}")))
            == .malformed(.invalidParameters))
    }

    @Test func unmodeledParametersExactlyAtTheCapDecode() {
        let entries = (1...ControlParameters.maximumUnmodeledEntries)
            .map { "\"k\($0)\":\"v\"" }.joined(separator: ",")
        var expected: [String: String] = [:]
        for index in 1...ControlParameters.maximumUnmodeledEntries { expected["k\(index)"] = "v" }
        let decoded = configuration(document(control(action: "app.quit", parameters: "{\(entries)}")))
        #expect(decoded?.controls.first?.parameters == .unmodeled(expected))
    }

    @Test func anOverlongUnmodeledKeyIsMalformed() {
        let key = String(repeating: "k", count: ControlParameters.maximumUnmodeledKeyBytes + 1)
        #expect(decode(document(control(action: "app.quit", parameters: "{\"\(key)\":\"v\"}")))
            == .malformed(.invalidParameters))
    }

    @Test func anOverlongUnmodeledValueIsMalformed() {
        let value = String(repeating: "v", count: ControlParameters.maximumUnmodeledValueBytes + 1)
        #expect(decode(document(control(action: "app.quit", parameters: "{\"k\":\"\(value)\"}")))
            == .malformed(.invalidParameters))
    }

    @Test func parametersMayNotBeANonObject() {
        #expect(decode(document(control(parameters: "\"/a.app\""))) == .malformed(.invalidParameters))
        #expect(decode(document(control(parameters: "[]"))) == .malformed(.invalidParameters))
    }
}

// MARK: H. Presentation

struct PresentationTests {
    @Test func aTitleExactlyAtTheCapDecodes() {
        let title = String(repeating: "t", count: ControlPresentation.maximumTitleBytes)
        let expected = DeckConfigurationV1(controls: [appControl(title: title)])
        #expect(decode(document(control(presentation: "{\"title\":\"\(title)\"}"))) == .v1(expected))
    }

    @Test func aTitleOverTheCapIsMalformed() {
        let title = String(repeating: "t", count: ControlPresentation.maximumTitleBytes + 1)
        #expect(decode(document(control(presentation: "{\"title\":\"\(title)\"}")))
            == .malformed(.invalidPresentation))
    }

    @Test func anEmptyTitleIsMalformed() {
        #expect(decode(document(control(presentation: "{\"title\":\"\"}"))) == .malformed(.invalidPresentation))
    }

    @Test(arguments: ["\\u0000", "\\u001f", "\\u007f", "\\u0080", "\\u0085", "\\u009f", "a\\u0007b"])
    func anInvisibleFormattingCharacterInATitleIsMalformed(_ escape: String) {
        #expect(decode(document(control(presentation: "{\"title\":\"\(escape)\"}")))
            == .malformed(.invalidPresentation))
    }

    @Test(arguments: ["\"x\"", "1", "null", "true", "[]"])
    func aNonObjectPresentationIsMalformed(_ presentation: String) {
        #expect(decode(document(control(presentation: presentation))) == .malformed(.invalidPresentation))
    }

    @Test(arguments: ["{\"title\":1}", "{\"title\":null}", "{\"title\":true}", "{\"title\":{}}"])
    func aNonStringTitleIsMalformed(_ presentation: String) {
        #expect(decode(document(control(presentation: presentation))) == .malformed(.invalidPresentation))
    }

    @Test func titleValidityIsCheckedDirectly() {
        #expect(ControlPresentation.isValidTitle("Build"))
        #expect(!ControlPresentation.isValidTitle(""))
        #expect(!ControlPresentation.isValidTitle("a\nb"))
    }
}

// MARK: I. Encoder strictness

struct EncoderTests {
    @Test func encodingIsByteDeterministic() throws {
        let controls = [control(id: "a"),
                        control(id: "b", action: "app.quit", parameters: "{\"z\":\"1\",\"a\":\"2\"}",
                                presentation: "{\"title\":\"T\"}")].joined(separator: ",")
        let decoded = try #require(configuration(document(controls)))
        let first = try ConfigurationEncoder.encode(decoded)
        let second = try ConfigurationEncoder.encode(decoded)
        #expect(first == second)
    }

    @Test func encodingIsIdempotent() throws {
        let original = try #require(configuration(document(control(presentation: "{\"title\":\"Build\"}"))))
        let first = try ConfigurationEncoder.encode(original)
        let reread = try #require(configuration(String(decoding: first, as: UTF8.self)))
        #expect(try ConfigurationEncoder.encode(reread) == first)
    }

    @Test func anEmptyControlListIsEncodedNotOmitted() throws {
        let text = String(decoding: try ConfigurationEncoder.encode(DeckConfigurationV1(controls: [])), as: UTF8.self)
        #expect(text.contains("\"controls\""))
        #expect(text.contains("\"version\""))
    }

    @Test func aTitleIsOmittedWhenThereIsNone() throws {
        let text = String(decoding: try ConfigurationEncoder.encode(DeckConfigurationV1(controls: [appControl()])),
                          as: UTF8.self)
        #expect(!text.contains("presentation"))
        #expect(!text.contains("null"))
    }

    @Test func theEncoderRejectsDuplicateIDs() {
        expectEncodingFailure(.duplicateControlID,
                              of: DeckConfigurationV1(controls: [appControl(id: "a"), appControl(id: "a")]))
    }

    @Test func theEncoderRejectsAnOverlongPath() {
        let long = appControl(path: path(ofBytes: ControlParameters.maximumPathBytes + 1))
        expectEncodingFailure(.invalidParameters, of: DeckConfigurationV1(controls: [long]))
    }

    @Test func theEncoderRejectsAnOverlongTitle() {
        let title = String(repeating: "t", count: ControlPresentation.maximumTitleBytes + 1)
        expectEncodingFailure(.invalidPresentation, of: DeckConfigurationV1(controls: [appControl(title: title)]))
    }

    @Test func theEncoderRejectsAnInvalidTitle() {
        expectEncodingFailure(.invalidPresentation, of: DeckConfigurationV1(controls: [appControl(title: "")]))
        expectEncodingFailure(.invalidPresentation, of: DeckConfigurationV1(controls: [appControl(title: "a\nb")]))
    }

    @Test func theEncoderRejectsAnOverlongUnmodeledValue() {
        let value = String(repeating: "v", count: ControlParameters.maximumUnmodeledValueBytes + 1)
        expectEncodingFailure(.invalidParameters,
                              of: DeckConfigurationV1(controls: [unmodeledControl(parameters: ["k": value])]))
    }

    @Test func theEncoderRejectsTooManyUnmodeledEntries() {
        var parameters: [String: String] = [:]
        for index in 1...ControlParameters.maximumUnmodeledEntries + 1 { parameters["k\(index)"] = "v" }
        expectEncodingFailure(.invalidParameters,
                              of: DeckConfigurationV1(controls: [unmodeledControl(parameters: parameters)]))
    }

    @Test func theEncoderRejectsAppLaunchWithUnmodeledParameters() {
        // The decoder never produces this pairing. The encoder must refuse to persist it, because a
        // document claiming `app.launch` with unmodeled parameters would read back as something
        // else — and `.appPath` is the only shape that can reach `ActionParameters`.
        let empty = DeckControl(id: ControlID(rawValue: "a")!, action: .appLaunch, parameters: .unmodeled([:]),
                                presentation: ControlPresentation(title: nil))
        expectEncodingFailure(.invalidParameters, of: DeckConfigurationV1(controls: [empty]))

        // An `.unmodeled` dictionary that happens to hold exactly `{"path": …}` serializes to bytes
        // the decoder reads back as `.appPath`, so the parameter rule passes and the round-trip
        // guard is what rejects it. Both routes are pinned because they fail for different reasons.
        let pathShaped = DeckControl(id: ControlID(rawValue: "a")!, action: .appLaunch,
                                     parameters: .unmodeled(["path": "/Applications/Safari.app"]),
                                     presentation: ControlPresentation(title: nil))
        expectEncodingFailure(.encoderRoundTripMismatch, of: DeckConfigurationV1(controls: [pathShaped]))
    }

    @Test func theEncoderRejectsAModelPairingTheDecoderWouldNotProduce() {
        // `.appPath` under an unregistered action reads back as `.unmodeled`, so the round trip does
        // not return the value that was encoded.
        let broken = DeckControl(id: ControlID(rawValue: "a")!, action: ActionID(rawValue: "app.quit")!,
                                 parameters: .appPath("/Applications/Safari.app"),
                                 presentation: ControlPresentation(title: nil))
        expectEncodingFailure(.encoderRoundTripMismatch, of: DeckConfigurationV1(controls: [broken]))
    }

    @Test func theEncoderRejectsTooManyControls() {
        let controls = (1...ConfigurationDecoder.maximumControlCount + 1).map { appControl(id: "a\($0)") }
        expectEncodingFailure(.tooManyControls, of: DeckConfigurationV1(controls: controls))
    }

    @Test func theEncoderRejectsAnOversizedDocument() {
        let controls = (1...4000).map { appControl(id: "a\($0)", path: path(ofBytes: 300)) }
        expectEncodingFailure(.documentTooLarge, of: DeckConfigurationV1(controls: controls))
    }
}

// MARK: J. Round trips

struct RoundTripTests {
    @Test(arguments: [
        #"{"version":1,"controls":[]}"#,
        #"{"version":1,"controls":[{"id":"app-1","action":"app.launch","parameters":{"path":"/Applications/Safari.app"}}]}"#,
        #"{"version":1,"controls":[{"id":"a","action":"app.launch","parameters":{"path":""}}]}"#,
        #"{"version":1,"controls":[{"id":"a","action":"app.launch","parameters":{"path":"/a.app"},"presentation":{"title":"Build"}}]}"#,
        #"{"version":1,"controls":[{"id":"a","action":"app.launch","parameters":{"path":"/a.app"}},{"id":"b","action":"app.launch","parameters":{"path":"/a.app"}}]}"#,
        #"{"version":1,"controls":[{"id":"a","action":"media.next","parameters":{"z":"1","a":"2"}}]}"#,
        #"{"version":1,"controls":[{"id":"a","action":"media.next"}]}"#,
        #"{"version":1,"controls":[{"id":"a","action":"app.quit","parameters":{}}]}"#,
        #"{"controls":[{"action":"app.launch","parameters":{"path":"/a.app"},"id":"a"}],"version":1}"#,
    ])
    func everyValidDocumentSurvivesARoundTrip(_ json: String) throws {
        let original = try #require(configuration(json))
        let bytes = try ConfigurationEncoder.encode(original)
        #expect(ConfigurationDecoder.decode(.data(bytes)) == .v1(original))
    }

    @Test func unmodeledParametersSurviveARoundTripVerbatim() throws {
        let original = DeckConfigurationV1(controls: [unmodeledControl(parameters: ["b": "2", "a": "1", "c": ""])])
        let text = String(decoding: try ConfigurationEncoder.encode(original), as: UTF8.self)
        #expect(try #require(configuration(text)) == original)
    }
}

// MARK: K. Legacy migration

struct MigrationTests {
    @Test func anEmptySelectionMigratesToAnEmptyDocument() {
        // An intentionally empty deck is preserved as an empty deck, not as a failure and not as
        // "never configured".
        #expect(ConfigurationMigrator.migrateToV1([]) == .success(DeckConfigurationV1(controls: [])))
    }

    @Test func orderIsPreserved() {
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(["/z.app", "/m.app", "/a.app"]) else {
            Issue.record("Expected migration to succeed")
            return
        }
        #expect(migrated.controls.map(\.parameters) == [.appPath("/z.app"), .appPath("/m.app"), .appPath("/a.app")])
    }

    @Test func duplicatesArePreserved() {
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(["/a.app", "/a.app"]) else {
            Issue.record("Expected migration to succeed")
            return
        }
        #expect(migrated.controls.count == 2)
        #expect(migrated.controls.map(\.id.rawValue) == ["app-1", "app-2"])
    }

    @Test func emptyStringEntriesArePreserved() {
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(["", "/a.app", ""]) else {
            Issue.record("Expected migration to succeed")
            return
        }
        #expect(migrated.controls.map(\.id.rawValue) == ["app-1", "app-2", "app-3"])
        // Compared as a whole list rather than by subscript, so a migration that dropped an entry
        // fails this expectation instead of trapping on an out-of-range index.
        #expect(migrated.controls.map(\.parameters) == [.appPath(""), .appPath("/a.app"), .appPath("")])
    }

    @Test func idsArePositionalAndOneBased() {
        let legacy = (1...9).map { "/Applications/A\($0).app" }
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(legacy) else {
            Issue.record("Expected migration to succeed")
            return
        }
        #expect(migrated.controls.map(\.id.rawValue) == (1...9).map { "app-\($0)" })
    }

    @Test func everyMigratedControlIsAppLaunchWithPathAndNoTitle() {
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(["/a.app", "/b.app"]) else {
            Issue.record("Expected migration to succeed")
            return
        }
        for control in migrated.controls {
            #expect(control.action == .appLaunch)
            #expect(control.presentation == ControlPresentation(title: nil))
            #expect(control.parameters.actionParameters != nil)
        }
    }

    @Test func migrationDoesNotConsultTheFilesystem() {
        // A path that cannot exist still migrates: the codec holds no `Apps`, no `FileManager` and no
        // `URL`, so an uninstalled application is preserved rather than dropped. Dropping it would
        // shift every later key and change what the phone renders.
        let impossible = "/nonexistent/Impossible.app"
        #expect(ConfigurationMigrator.migrateToV1([impossible])
            == .success(DeckConfigurationV1(controls: [appControl(id: "app-1", path: impossible)])))
    }

    @Test func migrationDoesNotFilterUnapprovedPaths() {
        // Authorization is `ActionRegistry.dispatch`'s job, at dispatch, exactly as it is for
        // `POST /launch` today. A migration that pre-filtered would be a second, divergent policy.
        #expect(ConfigurationMigrator.migrateToV1(["/etc/passwd", "/bin/sh"])
            == .success(DeckConfigurationV1(controls: [appControl(id: "app-1", path: "/etc/passwd"),
                                                       appControl(id: "app-2", path: "/bin/sh")])))
    }

    @Test func anOverlongPathFailsRatherThanTruncating() {
        let long = path(ofBytes: ControlParameters.maximumPathBytes + 1)
        #expect(ConfigurationMigrator.migrateToV1(["/a.app", long]) == .failure(.invalidParameters))
    }

    @Test func tooManyEntriesFailsRatherThanTruncating() {
        let legacy = (1...ConfigurationDecoder.maximumControlCount + 1).map { "/Applications/A\($0).app" }
        #expect(ConfigurationMigrator.migrateToV1(legacy) == .failure(.tooManyControls))
    }

    @Test func anOversizedDocumentFailsRatherThanTruncating() {
        let legacy = (1...4000).map { _ in path(ofBytes: 300) }
        #expect(ConfigurationMigrator.migrateToV1(legacy) == .failure(.documentTooLarge))
    }

    @Test(arguments: [[], ["/a.app"], ["/b.app", "/a.app"], ["/a.app", "/a.app"], ["", "/a.app", ""],
                      ["/z.app", "/m.app", "/a.app"], ["/nonexistent/Impossible.app"]])
    func migrationIsReversible(_ legacy: [String]) {
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(legacy) else {
            Issue.record("Expected migration to succeed")
            return
        }
        #expect(ConfigurationMigrator.legacySelection(migrated) == legacy)
    }

    @Test func migrationOfARealLegacyDocumentIsLossless() {
        // The shape of the file actually on this Mac: a bare array of `.app` paths.
        guard case .legacy(let legacy) = decode(#"["/Applications/Safari.app","/System/Applications/Calculator.app"]"#) else {
            Issue.record("Expected a legacy document")
            return
        }
        guard case .success(let migrated) = ConfigurationMigrator.migrateToV1(legacy) else {
            Issue.record("Expected migration to succeed")
            return
        }
        #expect(ConfigurationMigrator.legacySelection(migrated) == legacy)
        #expect(migrated.controls.map(\.id.rawValue) == ["app-1", "app-2"])
    }
}

// MARK: L. Reverse conversion rejects lossy representations

struct LegacySelectionTests {
    @Test func anEmptyDocumentYieldsAnEmptySelectionNotNil() {
        // A deliberately empty deck is representable, and is not the same as an unrepresentable one.
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [])) == [])
    }

    @Test func anUnmodeledControlMakesTheWholeConversionFail() {
        // Serving a subset would silently drop a key the user configured, which is the same class of
        // loss ADR-007 was written to prevent.
        let mixed = DeckConfigurationV1(controls: [appControl(id: "a"), unmodeledControl(id: "b")])
        #expect(ConfigurationMigrator.legacySelection(mixed) == nil)
    }

    @Test func anAppPathUnderAnUnregisteredActionIsStillLossy() {
        // `.appPath` parameters alone do not make a control legacy-representable: the legacy format
        // is a list of paths for one implicit action and carries no action identifier at all.
        let lossy = DeckControl(id: ControlID(rawValue: "a")!, action: ActionID(rawValue: "app.quit")!,
                                parameters: .appPath("/Applications/Safari.app"),
                                presentation: ControlPresentation(title: nil))
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [lossy])) == nil)
    }

    @Test func aTitleDoesNotMakeAConversionLossy() {
        // Presentation metadata has no legacy representation and needs none: the legacy format never
        // carried a label, and `GET /launcher` still serves names from the application catalog.
        let titled = DeckConfigurationV1(controls: [appControl(id: "a", title: "Build")])
        #expect(ConfigurationMigrator.legacySelection(titled) == ["/Applications/Safari.app"])
    }
}

// MARK: M. Security invariants

struct SecurityInvariantTests {
    @Test func appPathIsTheOnlyConvertibleParameterShape() {
        #expect(ControlParameters.appPath("/a.app").actionParameters == .appPath("/a.app"))
        #expect(ControlParameters.unmodeled([:]).actionParameters == nil)
        // A flat `path` key does not smuggle an unmodeled action onto the boundary, however exactly
        // it matches the shape `app.launch` uses.
        #expect(ControlParameters.unmodeled(["path": "/Applications/Safari.app"]).actionParameters == nil)
    }

    @Test func aConfiguredPathIsStillUnauthorizedUntilTheRegistrySaysOtherwise() throws {
        // Decoding produces data, never authority. A path read out of a document still has to pass
        // `ActionRegistry.dispatch`, which is where `Apps.isKnown` lives, so a configuration cannot
        // approve its own target.
        let catalog = FakeAppCatalog()
        let recorder = LaunchRecorder()
        let registry = testRegistry(catalog: catalog, recorder: recorder)

        let unapproved = try #require(configuration(document(control(parameters: "{\"path\":\"/tmp/evil.app\"}"))))
            .controls[0].parameters.actionParameters
        #expect(unapproved == .appPath("/tmp/evil.app"))
        #expect(registry.dispatch(.appLaunch, parameters: try #require(unapproved)) == .notAuthorized)
        #expect(catalog.consulted == ["/tmp/evil.app"])
        #expect(recorder.count == 0)

        let approvedPath = FakeAppCatalog.approved[0]
        let approved = try #require(configuration(document(control(parameters: "{\"path\":\"\(approvedPath)\"}"))))
            .controls[0].parameters.actionParameters
        #expect(registry.dispatch(.appLaunch, parameters: try #require(approved)) == .dispatched)
        #expect(recorder.paths == [approvedPath])
    }

    @Test func rejectedStatesCarryNoConfiguration() {
        let states = [decode("{"), decode(#"{"version":9,"controls":[]}"#), decode(#"{"version":1,"x":1}"#),
                      ConfigurationDecoder.decode(.unreadable), ConfigurationDecoder.decode(.absent),
                      decode(#"["/a.app",1]"#)]
        for state in states {
            guard case .v1 = state else { continue }
            Issue.record("A rejected document yielded a configuration: \(state)")
        }
    }

    @Test func thereIsNoDefaultConfigurationToFallBackTo() {
        // Every state that is not a usable document is distinguishable from every other, so no
        // consumer can mistake a corrupt or newer file for a fresh installation.
        let distinct: [ConfigurationState] = [.absent, .unreadable, .legacy([]),
                                              .v1(DeckConfigurationV1(controls: [])),
                                              .malformed(.notJSON), .unsupportedVersion(found: 2)]
        for (index, state) in distinct.enumerated() {
            for (other, otherState) in distinct.enumerated() where other != index {
                #expect(state != otherState)
            }
        }
    }

    @Test func anUnknownKeyNameNeverReachesTheError() {
        // Error cases carry no payload from the document, so a document cannot smuggle content into a
        // log line or an HTTP response by naming a key after it.
        let state = decode(#"{"version":1,"controls":[],"SECRET-KEY":1}"#)
        #expect(state == .malformed(.unknownKey))
        #expect(!String(describing: state).contains("SECRET-KEY"))
    }

    @Test func aDocumentValueNeverReachesTheError() {
        let longPath = "/" + String(repeating: "S", count: ControlParameters.maximumPathBytes) + "ENTINEL.app"
        let state = decode(document(control(parameters: "{\"path\":\"\(longPath)\"}")))
        #expect(state == .malformed(.invalidParameters))
        #expect(!String(describing: state).contains("SENTINEL"))
        #expect(!String(describing: state).contains(longPath))
    }

    @Test func aTitleNeverReachesTheError() {
        let longTitle = String(repeating: "T", count: ControlPresentation.maximumTitleBytes) + "SENTINEL"
        let state = decode(document(control(presentation: "{\"title\":\"\(longTitle)\"}")))
        #expect(state == .malformed(.invalidPresentation))
        #expect(!String(describing: state).contains("SENTINEL"))
    }

    @Test func aControlIDNeverReachesTheError() {
        let state = decode(document(control(id: "SENTINEL ID")))
        #expect(state == .malformed(.invalidControlID))
        #expect(!String(describing: state).contains("SENTINEL"))
    }
}
