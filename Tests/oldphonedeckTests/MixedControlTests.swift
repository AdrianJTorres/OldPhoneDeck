import Foundation
import Testing
@testable import oldphonedeck

private func mixedControls() throws -> [DeckControl] {
    [DeckControl(id: try #require(ControlID(rawValue: "browser-custom")), action: .appLaunch,
                 parameters: .appPath("/Missing.app"), presentation: ControlPresentation(title: "My browser")),
     DeckControl(id: try #require(ControlID(rawValue: "shortcut-custom")), action: .shortcutRun,
                 parameters: .unmodeled(["uuid": "11111111-1111-4111-8111-111111111111"]), presentation: ControlPresentation(title: "Proof")),
     DeckControl(id: try #require(ControlID(rawValue: "future-custom")), action: try #require(ActionID(rawValue: "future.action")),
                 parameters: .unmodeled(["opaque": "do not discard", "arg": "unknown"]), presentation: ControlPresentation(title: "Future"))]
}

@Suite struct MixedControlStoreTests {
    @Test func fullDocumentRoundTripAndLegacyRefusal() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let controls = try mixedControls(), preferences = WidgetPreferences(internet: false, batteries: true)
        let initial = DeckConfigurationV2(controls: controls, widgets: preferences)
        try seedConfiguration(directory, initial)
        let store = ConfigurationStore(directory: directory), read = store.load()
        #expect(read.document == initial)
        #expect(!read.writable) // legacy path-list capability remains closed
        #expect(read.controlsWritable)
        let committed = readBytes(at: store.configurationPath)
        guard case .rejected = store.write(paths: ["/Replacement.app"], expectedRevision: read.revision) else {
            Issue.record("legacy write discarded mixed data"); return
        }
        #expect(readBytes(at: store.configurationPath) == committed)
        let reordered = [controls[2], controls[0], controls[1]]
        guard case .saved(let saved) = store.write(paths: nil, expectedRevision: read.revision, controls: reordered) else {
            Issue.record("complete control save failed"); return
        }
        #expect(saved.document?.controls == reordered)
        #expect(saved.widgets == preferences)
        #expect(saved.controlsWritable)
        #expect(saved.document?.controls[0].parameters.actionParameters == nil)
        #expect(ConfigurationStore(directory: directory).load().document == saved.document)
        let before = readBytes(at: store.configurationPath)
        #expect(store.write(paths: nil, expectedRevision: read.revision, controls: controls) ==
                .rejected(ConfigurationWriteFailure(rejection: .stale, stateAfterFailure: nil)))
        #expect(readBytes(at: store.configurationPath) == before)
    }
    @Test func sevenAppsStayExactUntilSaveAndWidgetsDoNotReconstructControls() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let initial = try appDocument(count: 7)
        try seedConfiguration(directory, initial)
        let store = ConfigurationStore(directory: directory), first = store.load()
        let bytes = readBytes(at: store.configurationPath)
        #expect(first.document?.controls == initial.controls)
        #expect(store.load().selected?.count == 7)
        #expect(readBytes(at: store.configurationPath) == bytes)
        guard case .saved(let saved) = store.write(paths: nil, expectedRevision: first.revision,
                widgets: WidgetPreferences(internet: false, batteries: false), controls: initial.controls) else {
            Issue.record("widget save failed"); return
        }
        #expect(saved.document?.controls == initial.controls)
        #expect(saved.selected == first.selected)
        // A full selection stays seven until an explicit editor Save removes an app.
        var mixed = initial.controls
        mixed[6] = try mixedControls()[1]
        guard case .saved(let result) = store.write(paths: nil, expectedRevision: saved.revision, controls: mixed) else {
            Issue.record("mixed save failed"); return
        }
        #expect(result.document?.controls.count == 7)
        #expect(result.document?.controls.prefix(6) == initial.controls.prefix(6))
        #expect(result.widgets == saved.widgets)
    }
    @Test func concurrentCompleteAndLegacySavesHaveOneWinner() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        try seedConfiguration(directory, appDocument(count: 7))
        let store = ConfigurationStore(directory: directory), first = store.load(), controls = try mixedControls()
        let group = DispatchGroup(), lock = NSLock()
        var winners = 0, refused = 0
        for complete in [true, false] {
            group.enter()
            DispatchQueue.global().async {
                let result = store.write(paths: complete ? nil : ["/Changed.app"], expectedRevision: first.revision,
                                         controls: complete ? controls : nil)
                lock.lock()
                switch result {
                case .saved: winners += 1
                case .rejected: refused += 1
                }
                lock.unlock(); group.leave()
            }
        }
        group.wait()
        #expect(winners == 1 && refused == 1)
        let final = store.load()
        #expect(final.document?.controls == controls || final.selected == ["/Changed.app"])
    }
    @Test func failedMixedWriteRestoresExactCompleteBase() throws {
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let initial = DeckConfigurationV2(controls: try mixedControls(), widgets: WidgetPreferences(internet: false, batteries: false))
        try seedConfiguration(directory, initial)
        let store = ConfigurationStore(directory: directory), first = store.load()
        let bytes = readBytes(at: store.configurationPath)
        let faulty = ConfigurationStore(directory: directory, operations: tornWriteOperations(garbage: Array("broken".utf8)))
        guard case .rejected(let failure) = faulty.write(paths: nil, expectedRevision: first.revision,
                widgets: .visible, controls: Array(initial.controls.reversed())) else {
            Issue.record("torn save claimed success"); return
        }
        #expect(failure.rejection == .writeFailed)
        #expect(readBytes(at: store.configurationPath) == bytes)
        #expect(store.load().document == initial)
    }
    @Test func strictFullControlsWireRejectsAmbiguityAndRetainsMetadata() throws {
        let controls = try mixedControls()
        let data = try ConfigurationEncoder.encode(DeckConfigurationV2(controls: controls))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let array = try JSONSerialization.data(withJSONObject: try #require(object["controls"]))
        let text = String(decoding: array, as: UTF8.self)
        #expect(try LauncherRoute.parseControls(["controls": text]).get() == controls)
        for params in [["controls": text, "paths": ""], ["controls": text, "n": "3"],
                       ["controls": "null"], ["controls": "[{}]"], ["controls": text + ",\"extra\":true"]] {
            guard case .failure = LauncherRoute.parseControls(params) else { Issue.record("ambiguous controls accepted"); continue }
        }
        let tooMany = (1...8).map { i in
            DeckControl(id: ControlID(rawValue: "key-\(i)")!, action: .shortcutRun,
                        parameters: .unmodeled(["uuid": "11111111-1111-4111-8111-111111111111"]), presentation: ControlPresentation(title: nil))
        }
        let directory = try temporaryStoreDirectory()
        defer { removeStoreDirectory(directory) }
        let store = ConfigurationStore(directory: directory)
        #expect(!store.write(paths: nil, expectedRevision: store.load().revision, controls: tooMany).isSaved)
    }
}

private extension ConfigurationWriteOutcome {
    var isSaved: Bool { if case .saved = self { return true }; return false }
}

@Suite struct MixedControlClientTests {
    private func response() throws -> String {
        var json = LauncherRoute.responseJSON(ConfigurationRead(state: .unprojectable(DeckConfigurationV2(controls: try mixedControls())),
            selected: nil, status: .unrepresentable, version: nil, writable: false, revision: "mixed-revision"),
            catalog: [["name": "A", "path": "/A.app"]])
        json["shortcuts"] = [["uuid": "11111111-1111-4111-8111-111111111111", "label": "Test", "availability": "unchecked"]]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
    @Test func missingAndUnknownControlsKeepPositionsAndCancelDoesNotSave() throws {
        let c = try LauncherClientHarness()
        try c.run("loadKeys()")
        try c.reply(response())
        #expect(try c.run("cfg.writable").toBool())
        #expect(try c.run("$('keys').children[0].lastChild.textContent").toString() == "My browser · Unavailable")
        #expect(try c.run("$('keys').children[1].lastChild.textContent").toString() == "Proof")
        #expect(try c.run("$('keys').children[2].lastChild.textContent").toString() == "Future · Unavailable")
        try c.run("openEditor(); draft.splice(0, 1); $('editCancel').tap(); openEditor()")
        #expect(try c.run("draft.length").toInt32() == 3)
        #expect(try c.run("draft[0].id").toString() == "browser-custom")
        #expect(try c.run("requests.length").toInt32() == 0)
        try c.run("$('editSave').tap()")
        #expect(try c.run("requests[0].body.indexOf('controls=') === 0 && requests[0].body.indexOf('&paths=') < 0").toBool())
        #expect(try c.run("JSON.parse(decodeURIComponent(requests[0].body.split('&')[0].slice(9)))[2].parameters.opaque").toString() == "do not discard")
        try c.reply("stale", status: 409)
        #expect(try c.run("cfg.revision").toString() == "mixed-revision")
        #expect(try c.run("draft.length").toInt32() == 3)
    }
    @Test func sevenPositionsRequireRemovalBeforeAdditionAndKeepIDsOnReorder() throws {
        let c = try LauncherClientHarness()
        try c.run("loadKeys()")
        try c.reply(response())
        try c.run("launcher.controls = []; for (var i = 0; i < 7; i++) launcher.controls.push({id:'app-' + (i+1), action:'app.launch', parameters:{path:'/App' + i + '.app'}}); openEditor()")
        try c.run("$('editList').children[8].listeners.click()") // approved Shortcut after seven chosen + app
        #expect(try c.run("draft.length").toInt32() == 7)
        #expect(try c.run("notices[notices.length-1]").toString().contains("remove one first"))
        try c.run("$('editList').children[0].listeners.click()")
        #expect(try c.run("draft.length").toInt32() == 6)
        try c.run("$('editList').children[7].listeners.click()")
        #expect(try c.run("draft.length").toInt32() == 7)
        #expect(try c.run("draft[6].action").toString() == "shortcut.run")
        try c.run("var idBefore = draft[6].id; $('editList').children[6].lastChild.listeners.click({stopPropagation:function(){}})")
        #expect(try c.run("draft[5].id === idBefore").toBool())
    }
    @Test func shortcutFeedbackNeverResubmitsExecution() throws {
        let c = try LauncherClientHarness()
        try c.run("loadKeys()")
        try c.reply(response())
        try c.run("$('keys').children[1].tap()")
        #expect(try c.run("requests[0].path").toString() == "/shortcut?k=test-token")
        try c.reply(#"{"id":"11111111-1111-4111-8111-111111111111","status":"running"}"#)
        #expect(try c.run("requests[0].method").toString() == "GET")
        try c.reply(#"{"status":"timed-out"}"#)
        #expect(try c.run("notices[notices.length-1]").toString() == "Timed out — outcome unknown")
        #expect(try c.run("requests.length").toInt32() == 0)
        try c.run("$('keys').children[1].tap()")
        try c.reply("busy", status: 409)
        #expect(try c.run("notices[notices.length-1]").toString() == "Busy")
    }
}
