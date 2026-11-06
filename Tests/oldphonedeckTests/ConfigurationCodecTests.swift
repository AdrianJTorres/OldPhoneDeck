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
        // `true` and `false` are literals of their own, not numbers, so neither reads as version 1.
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

// MARK: L. Reverse conversion is lossless, not a projection

struct LegacySelectionTests {
    /// A configuration produced by migration. A broken fixture should stop the run rather than
    /// quietly weaken a test, so this traps instead of returning a stand-in.
    private func migrated(_ legacy: [String]) -> DeckConfigurationV1 {
        guard case .success(let configuration) = ConfigurationMigrator.migrateToV1(legacy) else {
            preconditionFailure("fixture did not migrate: \(legacy)")
        }
        return configuration
    }

    @Test func anEmptyDocumentYieldsAnEmptySelectionNotNil() {
        // A deliberately empty deck round-trips, and is not the same as an unrepresentable one.
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [])) == [])
    }

    @Test func anUnmodeledControlMakesTheWholeConversionFail() {
        // Serving a subset would silently drop a key the user configured, which is the same class of
        // loss ADR-007 was written to prevent.
        let mixed = DeckConfigurationV1(controls: [appControl(id: "app-1"), unmodeledControl(id: "app-2")])
        #expect(ConfigurationMigrator.legacySelection(mixed) == nil)
    }

    @Test func anAppPathUnderAnUnregisteredActionIsStillLossy() {
        // `.appPath` parameters alone do not make a control legacy-representable: the legacy format
        // is a list of paths for one implicit action and carries no action identifier at all.
        let lossy = DeckControl(id: ControlID(rawValue: "app-1")!, action: ActionID(rawValue: "app.quit")!,
                                parameters: .appPath("/Applications/Safari.app"),
                                presentation: ControlPresentation(title: nil))
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [lossy])) == nil)
    }

    @Test func aTitleMakesTheConversionLossy() {
        // Migration synthesizes no title, so a label cannot be reproduced from a bare path list.
        // Returning the path anyway would discard the user's label while reporting a complete deck.
        // The id is positional here, which isolates the title as the only lossy element.
        let titled = DeckConfigurationV1(controls: [appControl(id: "app-1", title: "Build")])
        #expect(ConfigurationMigrator.legacySelection(titled) == nil)
    }

    @Test func aCustomIDMakesTheConversionLossy() {
        // Migration synthesizes `app-1`, `app-2`, … positionally. A meaningful id is information the
        // legacy format cannot carry, so this is not the document migration would reproduce.
        let custom = DeckConfigurationV1(controls: [appControl(id: "build-terminal")])
        #expect(ConfigurationMigrator.legacySelection(custom) == nil)
    }

    @Test func reorderedControlsAreNotReconstructible() {
        // The paths are still in document order, but the ids no longer match the positions
        // migration would assign, so this reordering is not something a path list can express.
        let reordered = DeckConfigurationV1(controls: [appControl(id: "app-2", path: "/a.app"),
                                                      appControl(id: "app-1", path: "/b.app")])
        #expect(ConfigurationMigrator.legacySelection(reordered) == nil)
    }

    @Test func aGapInTheIDSequenceIsNotReconstructible() {
        let gapped = DeckConfigurationV1(controls: [appControl(id: "app-1"), appControl(id: "app-3")])
        #expect(ConfigurationMigrator.legacySelection(gapped) == nil)
    }

    @Test func anIDThatIsNotPositionalIsNotReconstructible() {
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [appControl(id: "app-0")])) == nil)
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [appControl(id: "key-1")])) == nil)
        #expect(ConfigurationMigrator.legacySelection(DeckConfigurationV1(controls: [appControl(id: "app-2")])) == nil)
    }

    @Test func aMigratedSelectionIsPreservedWithOrderDuplicatesAndEmptyPaths() {
        // The positive half of the correction: the new rejection rules must not swallow anything
        // migration actually produced, including the awkward legacy cases.
        for legacy in [[], ["/a.app"], ["/a.app", "/a.app"], ["", "/a.app", ""],
                       ["/z.app", "/m.app", "/a.app"], ["/nonexistent/Impossible.app"]] {
            #expect(ConfigurationMigrator.legacySelection(migrated(legacy)) == legacy)
        }
    }

    @Test func everyAcceptedReverseConversionMigratesBackIdentically() {
        // The approved invariant, stated as a test rather than as a comment: whenever
        // `legacySelection` returns a selection, migrating that selection reproduces the document
        // exactly — ids, order, duplicates, empty paths and metadata included.
        let documents = [
            // Accepted: everything here is what migration produces.
            DeckConfigurationV1(controls: []),
            DeckConfigurationV1(controls: [appControl(id: "app-1")]),
            DeckConfigurationV1(controls: [appControl(id: "app-1", path: "")]),
            DeckConfigurationV1(controls: [appControl(id: "app-1", path: "/a.app"),
                                           appControl(id: "app-2", path: "/a.app")]),
            migrated(["/z.app", "", "/z.app", "/a.app"]),
            migrated((1...9).map { "/Applications/A\($0).app" }),
            // Rejected: each one carries something a bare path list cannot hold.
            DeckConfigurationV1(controls: [appControl(id: "app-1", title: "Build")]),
            DeckConfigurationV1(controls: [appControl(id: "build-terminal")]),
            DeckConfigurationV1(controls: [appControl(id: "app-2", path: "/a.app"),
                                           appControl(id: "app-1", path: "/b.app")]),
            DeckConfigurationV1(controls: [appControl(id: "app-1"), appControl(id: "app-3")]),
            DeckConfigurationV1(controls: [appControl(id: "app-1"), unmodeledControl(id: "app-2")]),
            DeckConfigurationV1(controls: [unmodeledControl(id: "app-1", action: "media.next")]),
        ]
        var accepted = 0
        for document in documents {
            guard let selection = ConfigurationMigrator.legacySelection(document) else { continue }
            accepted += 1
            guard case .success(let reconstructed) = ConfigurationMigrator.migrateToV1(selection) else {
                Issue.record("A returned selection did not migrate back")
                continue
            }
            #expect(reconstructed == document)
        }
        // Without this the invariant above would pass vacuously if every document were rejected.
        #expect(accepted == 6)
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

// MARK: N. Strict JSON syntax

/// Regression suite for the review finding that configuration was read through
/// `JSONSerialization`, which is lenient about syntax RFC 8259 forbids. The divergences below each
/// assert *both* halves: that the lenient reader still accepts the input, and that the codec does
/// not. Removing the scanner therefore turns this suite red rather than quietly widening the
/// format, and the assertion about `JSONSerialization` is what keeps the finding itself pinned.
struct StrictJSONSyntaxTests {
    /// A comma promises another element or member; nothing may follow it.
    @Test(arguments: [#"{"version":1,"controls":[],}"#, #"{"version":1,"controls":[{},],}"#,
                      #"["/a.app",]"#, #"[1,]"#])
    func aTrailingCommaTheLenientReaderAcceptedIsMalformed(_ json: String) {
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
        #expect(decode(json) == .malformed(.notJSON))
    }

    @Test(arguments: [#"{"version":1,"controls":[,]}"#, #"{"version":1,"controls":[{},,{}]}"#,
                      #"[,]"#, #"[1,,2]"#, #"{"version":1,,"controls":[]}"#])
    func aCommaMustBeFollowedByAValueOrName(_ json: String) {
        #expect(decode(json) == .malformed(.notJSON))
    }

    /// With one ordered parser there is no first-wins or last-wins rule to fall back on. The
    /// lenient reader collapsed the pair into a dictionary and silently kept one of the two
    /// versions, so which version a document had depended on the reader rather than on the bytes.
    @Test func aDuplicateVersionIsRejectedRatherThanResolved() {
        let json = #"{"version":2,"version":1,"controls":[]}"#
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
        #expect(decode(json) == .malformed(.duplicateKey))
        // Names are scanned before versions are interpreted, so ambiguity outranks "from the
        // future": guessing 2 here would be exactly the nondeterminism being removed.
        #expect(decode(json) != .unsupportedVersion(found: 2))
        #expect(decode(json) != .v1(DeckConfigurationV1(controls: [])))
    }

    @Test func aDuplicateNameIsRejectedAtEveryLevel() {
        #expect(decode(#"{"version":1,"version":1,"controls":[]}"#) == .malformed(.duplicateKey))
        #expect(decode(document(#"{"id":"a","id":"a","action":"app.quit"}"#))
                == .malformed(.duplicateKey))
        #expect(decode(document(control(action: "app.quit", parameters: #"{"k":"v","k":"w"}"#)))
                == .malformed(.duplicateKey))
        #expect(decode(document(control(action: "app.quit",
                                        presentation: #"{"title":"a","title":"b"}"#)))
                == .malformed(.duplicateKey))
        #expect(decode(#"["/a.app","/a.app"]"#) == .legacy(["/a.app", "/a.app"]),
                "Duplicated array elements are data, not ambiguous names")
    }

    /// Number syntax the grammar pins down. Each of these is a token a hand-edited file could
    /// contain, and each is corruption rather than a value.
    @Test(arguments: [#"{"version":01,"controls":[]}"#, #"{"version":+1,"controls":[]}"#,
                      #"{"version":1.,"controls":[]}"#, #"{"version":.5,"controls":[]}"#,
                      #"{"version":1e,"controls":[]}"#, #"{"version":1e+,"controls":[]}"#,
                      #"{"version":0x10,"controls":[]}"#, #"{"version":NaN,"controls":[]}"#,
                      #"{"version":Infinity,"controls":[]}"#, #"{"version":-Infinity,"controls":[]}"#,
                      #"{"version":-.5,"controls":[]}"#, "{\"version\":-,\"controls\":[]}"])
    func aNumberThatIsNotAJONumberIsMalformed(_ json: String) {
        #expect(decode(json) == .malformed(.notJSON))
    }

    @Test(arguments: [#"{"a":"\x"}"#, #"{"a":"\'"}"#, #"{"a":"\0"}"#, #"{"a":"\u00"}"#,
                      #"{"a":"\u12"}"#, #"{"a":"\ }"#, "{\"a\":\"\\\u{0A}\"}"])
    func anEscapeTheGrammarDoesNotDefineIsMalformed(_ json: String) {
        #expect(decode(json) == .malformed(.notJSON))
    }

    @Test func aCommentIsNotWhitespace() {
        #expect(decode("// configuration\n{\"version\":1,\"controls\":[]}") == .malformed(.notJSON))
        #expect(decode(#"{"version":1,"controls":[]}/* trailing */"#) == .malformed(.notJSON))
    }

    @Test func contentAfterACompleteDocumentIsMalformed() {
        let complete = #"{"version":1,"controls":[]}"#
        for trailing in ["x", "{}", "]", #""a""#] {
            #expect(decode(complete + trailing) == .malformed(.notJSON))
        }
        // Whitespace after the value is insignificant, and the encoder's own output ends with a
        // newline, so this must stay accepted.
        #expect(decode(complete + " \n\t") == .v1(DeckConfigurationV1(controls: [])))
    }

    @Test(arguments: [UInt8(0x00), 0x01, 0x07, 0x09, 0x0A, 0x0D, 0x1F])
    func aRawControlCharacterInsideAStringIsMalformed(_ byte: UInt8) {
        // RFC 8259 requires a control character to be escaped. Deciding this in the scanner rather
        // than in `isValidTitle` is what makes it a syntax fact: the same byte in a path, which
        // has no character rule at all, is rejected too.
        for body in [#"{"id":"a","action":"app.quit","presentation":{"title":"a"#,
                     #"{"id":"a","action":"app.launch","parameters":{"path":"a"#] {
            var bytes = Data(#"{"version":1,"controls":["#.utf8)
            bytes.append(Data(body.utf8))
            bytes.append(byte)
            bytes.append(Data(#"b"}}]}"#.utf8))
            #expect(ConfigurationDecoder.decode(.data(bytes)) == .malformed(.notJSON))
        }
    }

    @Test func illFormedUTF8IsRejectedRatherThanReplaced() {
        // A reader that substituted U+FFFD would turn a corrupt file into a valid-looking one
        // holding a character the user never wrote.
        var bytes = Data(#"{"version":1,"controls":[{"id":"a","action":"app.quit","presentation":{"title":"a"#.utf8)
        bytes.append(contentsOf: [0xC3, 0x28])
        bytes.append(Data(#""}}]}"#.utf8))
        #expect(ConfigurationDecoder.decode(.data(bytes)) == .malformed(.notJSON))
    }

    @Test func aLoneSurrogateIsMalformedButAPairDecodes() {
        #expect(decode(#"{"version":1,"controls":[],"k":"\ud800"}"#) == .malformed(.notJSON))
        #expect(decode(#"{"version":1,"controls":[],"k":"\udc00"}"#) == .malformed(.notJSON))
        // A high surrogate must be followed by a low one, or the pair is not a character.
        #expect(decode(#"{"version":1,"controls":[],"k":"\ud800a"}"#) == .malformed(.notJSON))
        #expect(decode(#"{"version":1,"controls":[],"k":"\ud800\ud800"}"#) == .malformed(.notJSON))
    }

    @Test func nestingDeeperThanTheBoundIsRejectedRatherThanRiskingTheStack() {
        let depth = ConfigurationJSONScanner.maximumNestingDepth + 1
        let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        // The lenient reader parses this depth happily, so the bound is the codec's own safety
        // property when reading untrusted bytes, not something inherited from the framework.
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
        #expect(decode(json) == .malformed(.tooDeeplyNested))
    }

    @Test func nestingAtTheBoundIsNotADepthError() {
        let depth = ConfigurationJSONScanner.maximumNestingDepth
        let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        // The outermost array is a legacy document, so the failure is about the entry's type. That
        // is what shows the bound itself did not fire one level early.
        #expect(decode(json) == .malformed(.legacyEntryNotString))
    }

    @Test func everyEscapeTheGrammarDefinesDecodesToTheRightBytes() {
        // A hand-written scanner has to earn the escapes it accepts; `\b` and `\f` in particular
        // are easy to forget, and a surrogate pair has to become one code point rather than two.
        let json = #"{"version":1,"controls":[{"id":"a","action":"app.launch","parameters":{"path":"\"\\\/\b\f\n\r\t\u0041\u00e9\ud83d\ude00"}}]}"#
        guard case .v1(let configuration) = decode(json), let control = configuration.controls.first,
              case .appPath(let path) = control.parameters else {
            Issue.record("Expected the escapes to decode, got \(decode(json))")
            return
        }
        #expect(path == "\"\\/\u{08}\u{0C}\n\r\tAé\u{1F600}")
    }

    @Test func insignificantWhitespaceIsStillInsignificant() {
        #expect(decode("{\n\t\"version\" : 1 ,\n\t\"controls\" : [ ]\n}\n")
                == .v1(DeckConfigurationV1(controls: [])))
    }
}

// MARK: O. Exact version parsing

/// Regression suite for the review finding that the version reached the codec as a `Double`. A
/// widened number has already lost the digits that decide whether a document is this build's, from
/// the future, or corrupt, and no later check can recover them.
struct ExactVersionParsingTests {
    /// Each of these widens to exactly `1.0`, so a floating-point reader accepted the document as
    /// version 1. Their exact mathematical values are not integers.
    @Test(arguments: ["1.0000000000000001", "0.99999999999999999", "1.00000000000000000000001",
                      "0.9999999999999999999999", "1.0000000000000002"])
    func aVersionThatOnlyLooksIntegralAfterRoundingIsMalformed(_ literal: String) {
        #expect(decode("{\"version\":\(literal),\"controls\":[]}") == .malformed(.invalidVersion))
        #expect(decode("{\"version\":\(literal),\"controls\":[]}") != .v1(DeckConfigurationV1(controls: [])))
    }

    @Test func twoVersionsThatWidenToTheSameDoubleAreDistinguished() {
        // Both widen to 9007199254740992.0. Reporting the widened value would tell the user their
        // file claimed a version it never did, and would make two different documents identical.
        let odd = decode(#"{"version":9007199254740993,"controls":[]}"#)
        let even = decode(#"{"version":9007199254740992,"controls":[]}"#)
        #expect(odd == .unsupportedVersion(found: 9_007_199_254_740_993))
        #expect(even == .unsupportedVersion(found: 9_007_199_254_740_992))
        #expect(odd != even)
    }

    @Test func aVersionAtIntMaxIsReportedExactlyRatherThanAsCorrupt() {
        // `Double(Int.max)` is 9223372036854775808, which is not representable as an `Int`, so a
        // widened reader called a legitimate future version malformed and told the user to repair
        // a file that was merely newer.
        #expect(decode(#"{"version":9223372036854775807,"controls":[]}"#)
                == .unsupportedVersion(found: 9_223_372_036_854_775_807))
    }

    @Test func aVersionPastIntMaxIsMalformed() {
        #expect(decode(#"{"version":9223372036854775808,"controls":[]}"#) == .malformed(.invalidVersion))
        #expect(decode(#"{"version":99999999999999999999,"controls":[]}"#) == .malformed(.invalidVersion))
        #expect(decode(#"{"version":-9223372036854775809,"controls":[]}"#) == .malformed(.invalidVersion))
    }

    @Test func aVersionAtIntMinIsMalformedNotFuture() {
        #expect(decode(#"{"version":-9223372036854775808,"controls":[]}"#) == .malformed(.invalidVersion))
    }

    /// JSON has one number type, so an exactly integral value in any spelling is that integer.
    @Test func anExactlyIntegralVersionInAnySpellingIsAccepted() {
        for literal in ["1", "1.0", "1.000", "1e0", "1E0", "1.0e0", "0.1e1", "10e-1", "1e+0"] {
            #expect(decode("{\"version\":\(literal),\"controls\":[]}") == .v1(DeckConfigurationV1(controls: [])),
                    "\(literal) is exactly 1")
        }
    }

    @Test func anExactlyIntegralValueInANonIntegralSpellingIsStillAVersionNumber() {
        // 1.5e1 is exactly 15, so it is a real version and the honest diagnosis is "upgrade".
        #expect(decode(#"{"version":1.5e1,"controls":[]}"#) == .unsupportedVersion(found: 15))
        #expect(decode(#"{"version":1.50e001,"controls":[]}"#) == .unsupportedVersion(found: 15))
    }

    @Test(arguments: ["1.5", "0.5", "1e-1", "2.5", "0.0000001", "1.0000000000000000000001"])
    func aFractionalVersionIsMalformed(_ literal: String) {
        #expect(decode("{\"version\":\(literal),\"controls\":[]}") == .malformed(.invalidVersion))
    }

    @Test func negativeZeroIsVersionZeroAndThereforeMalformed() {
        // Negative zero is the integer 0, and no version below 1 ever existed.
        for literal in ["-0", "-0.0", "-0e0"] {
            #expect(decode("{\"version\":\(literal),\"controls\":[]}") == .malformed(.invalidVersion))
        }
    }

    @Test func anAbsurdExponentIsRejectedWithoutExpandingIt() {
        // The literal is a few bytes long. A reader that materialized the value would try to
        // allocate a billion digits, so a short corrupt file becomes a way to exhaust memory.
        // Exactness is decided on the digits, with the length bounded before any zeros are added.
        for literal in ["1e999999999", "-1e999999999", "1.5e999999999", "1e99999999999999999999"] {
            #expect(decode("{\"version\":\(literal),\"controls\":[]}") == .malformed(.invalidVersion),
                    "\(literal) cannot be an Int")
        }
    }
}

// MARK: P. Canonical size invariant

/// Regression suite for the review finding that the two directions disagreed about size. The byte
/// cap was measured on the document as read, while the encoder wrote a pretty-printed form that is
/// always larger, so a configuration could be valid on disk and impossible to save unchanged.
struct CanonicalSizeInvariantTests {
    /// The document below fits the cap as read and overflows it once written. Both premises are
    /// asserted, so the test cannot pass by having drifted out of the interesting range.
    @Test func aDocumentOnlyItsCanonicalFormOverflowsIsMalformed() {
        let count = ConfigurationDecoder.maximumControlCount
        let value = String(repeating: "a", count: 186)
        var compact = #"{"version":1,"controls":["#
        var controls: [DeckControl] = []
        controls.reserveCapacity(count)
        for index in 1...count {
            let id = String(format: "a%04d", index)
            compact += "{\"id\":\"\(id)\",\"action\":\"app.quit\",\"parameters\":{\"k\":\"\(value)\"}}"
            if index < count { compact += "," }
            controls.append(unmodeledControl(id: id, action: "app.quit", parameters: ["k": value]))
        }
        compact += "]}"
        let bytes = Data(compact.utf8)

        let cap = ConfigurationDecoder.maximumDocumentBytes
        #expect(bytes.count <= cap, "the document as read must fit, or this proves nothing")
        guard let canonical = ConfigurationCanonicalForm.data(DeckConfigurationV1(controls: controls)) else {
            Issue.record("Expected the canonical form to serialize")
            return
        }
        #expect(canonical.count > cap, "the form the codec would write must overflow")

        // Matched by case rather than by whole-state equality, so a failure names what happened
        // instead of printing all 4096 controls the document decoded to.
        guard case .malformed(let error) = ConfigurationDecoder.decode(.data(bytes)) else {
            Issue.record("Expected a document only its canonical form overflows to be rejected")
            return
        }
        #expect(error == .documentTooLarge)
        // The same content just under the boundary still reads, so the check is about the cap and
        // not a blanket rejection of dense documents.
        #expect(decode(document(control(action: "app.quit", parameters: "{\"k\":\"\(value)\"}")))
                != .malformed(.documentTooLarge))
    }

    /// The other half of the invariant: nothing the decoder accepts is unsaveable.
    @Test func everyAcceptedDocumentCanBeWrittenBackInsideTheCap() {
        let widest = String(repeating: "a", count: ControlParameters.maximumUnmodeledValueBytes)
        let accepted = [
            document(""),
            document(control()),
            document(control(presentation: "{\"title\":\"Safari\"}")),
            document(control(action: "app.quit", parameters: "{\"k\":\"\(widest)\"}")),
            document((1...ConfigurationDecoder.maximumControlCount)
                .map { control(id: "a\($0)") }.joined(separator: ",")),
        ]
        for json in accepted {
            guard case .v1(let configuration) = decode(json) else {
                Issue.record("Expected an accepted document, got \(decode(json))")
                continue
            }
            switch ConfigurationEncoder.verifiedData(configuration) {
            case .success(let data):
                #expect(data.count <= ConfigurationDecoder.maximumDocumentBytes)
            case .failure(let error):
                Issue.record("An accepted document could not be written back: \(error)")
            }
        }
    }

    /// The decoder's size check has to measure the bytes the encoder actually writes. If the two
    /// ever used different forms, "fits when read" and "fits when written" would come apart again.
    @Test func theEncoderWritesExactlyTheFormTheDecoderMeasures() {
        let configuration = DeckConfigurationV1(controls: [appControl(title: "Safari"),
                                                           unmodeledControl(parameters: ["k": "v"])])
        guard let canonical = ConfigurationCanonicalForm.data(configuration),
              case .success(let encoded) = ConfigurationEncoder.verifiedData(configuration) else {
            Issue.record("Expected both directions to produce bytes")
            return
        }
        #expect(canonical == encoded)
        #expect(ConfigurationDecoder.decode(.data(canonical)) == .v1(configuration))
    }

    /// Migration is held to the same canonical bound, so a legacy selection can never migrate into
    /// a document that a later read would reject. It fails loudly instead of truncating.
    @Test func migrationIsHeldToTheCanonicalBoundToo() {
        let widest = path(ofBytes: ControlParameters.maximumPathBytes)
        let selection = Array(repeating: widest, count: ConfigurationDecoder.maximumControlCount)
        // Every entry is individually legal and the count is at, not over, its cap, so the only
        // thing wrong with the result is the size of the document it would make.
        #expect(widest.utf8.count <= ControlParameters.maximumPathBytes)
        #expect(selection.count <= ConfigurationDecoder.maximumControlCount)
        #expect(ConfigurationMigrator.migrateToV1(selection) == .failure(.documentTooLarge))
    }
}
