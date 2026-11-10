import Foundation
import JavaScriptCore
import Testing
@testable import oldphonedeck

/// Executes the shipped keys/editor JavaScript, with only the browser surfaces replaced.
/// No application startup, real configuration, app executor or external JS dependency is used.
final class LauncherClientHarness {
    let context: JSContext

    init(token: String = "test-token") throws {
        context = try #require(JSContext())
        context.setObject(token, forKeyedSubscript: "testToken" as NSString)
        let root = try #require(Bundle.module.url(forResource: "web", withExtension: nil))
        let html = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        let start = try #require(html.range(of: "  // ---------- keys ----------"))
        let end = try #require(html.range(of: "  // ---------- Ask Claude ----------"))
        // Minimal DOM, event registration and queued XHR responses. Production rendering and
        // save callbacks run unchanged; a reply may be supplied from a real loopback HTTP call.
        try run(#"""
        var elements = {}, requests = [], notices = [], sheets = [], APP_SLOTS = 7;
        var timers = {}, timerID = 0;
        function setTimeout(fn, delay) { timers[++timerID] = {fn:fn, delay:delay}; return timerID; }
        function clearTimeout(id) { delete timers[id]; }
        function Element() {
          this.style = {}; this.children = []; this.attributes = {}; this.listeners = {};
          this.className = ''; this.textContent = ''; this.value = '';
        }
        Object.defineProperty(Element.prototype, 'innerHTML', {
          get: function () { return this.html || ''; },
          set: function (text) {
            this.html = text; this.children = [];
            if (text) {
              var count = text.indexOf('class="cap"') >= 0 ? 2 : (text.indexOf('class="up"') >= 0 ? 4 : 3);
              for (var i = 0; i < count; i++) this.children.push(new Element());
            }
          }
        });
        Object.defineProperty(Element.prototype, 'lastChild', {
          get: function () { return this.children[this.children.length - 1]; }
        });
        Element.prototype.appendChild = function (child) { this.children.push(child); };
        Element.prototype.addEventListener = function (event, fn) { this.listeners[event] = fn; };
        Element.prototype.setAttribute = function (key, value) { this.attributes[key] = value; };
        var document = { createElement: function () { return new Element(); } };
        function $(id) { return elements[id] || (elements[id] = new Element()); }
        function tap(el, fn, hold) { el.tap = fn; el.hold = hold; }
        function toast(text) { notices.push(text); }
        function sheet(id, open) { sheets.push([id, open]); }
        function url(path, extra) { return path + '?k=' + testToken + (extra ? '&' + extra : ''); }
        function xhr(method, path, body, callback) {
          var request = { method: method, path: path, body: body, callback: callback, aborted:false };
          requests.push(request);
          return { abort:function(){request.aborted=true;} };
        }
        function openClaude() {}
        """#)
        try run(String(html[start.lowerBound..<end.lowerBound]))
    }

    @discardableResult func run(_ script: String) throws -> JSValue {
        context.exception = nil
        let value = try #require(context.evaluateScript(script))
        try #require(context.exception == nil, "JavaScript exception: \(context.exception?.toString() ?? "")")
        return value
    }

    func reply(_ body: String, status: Int = 200) throws {
        context.setObject(body, forKeyedSubscript: "responseBody" as NSString)
        try run("requests.shift().callback(\(status), responseBody)")
    }
}

@Suite struct LauncherClientTests {
    private let ready = #"{"selected":["/A.app"],"all":[{"name":"A","path":"/A.app"}],"configuration":"v2","widgets":{"internet":true,"batteries":true},"writable":true,"revision":"revision-a"}"#

    @Test func configureTapAndHoldOpenTheExistingEditorWithoutDispatchingActions() throws {
        let client = try LauncherClientHarness()
        let controls = (1...7).map { i in
            ["id": "stable-\(i)", "action": "app.launch", "parameters": ["path": "/App\(i).app"],
             "presentation": ["title": "Key \(i)"]] as [String: Any]
        }
        let response: [String: Any] = ["selected": (1...7).map { "/App\($0).app" },
            "all": (1...7).map { ["name": "App\($0)", "path": "/App\($0).app"] },
            "controls": controls, "controlsWritable": true, "shortcuts": [], "configuration": "v2",
            "widgets": ["internet": true, "batteries": true], "writable": true, "revision": "configure-revision"]
        let ready = try #require(String(data: JSONSerialization.data(withJSONObject: response), encoding: .utf8))
        try client.run("loadKeys()")
        try client.reply(ready)
        try client.run("var originalControls = JSON.stringify(launcher.controls); $('keys').children[7].tap()")
        #expect(try client.run("$('keys').children.length").toInt32() == 8)
        #expect(try client.run("$('keys').children[7].lastChild.textContent").toString() == "Configure")
        #expect(try client.run("JSON.stringify(draft) === originalControls && sheets[sheets.length-1][0] === 'edit'").toBool())
        #expect(try client.run("requests.length").toInt32() == 0)
        try client.run("$('editInternet').checked = false; $('editCancel').tap(); $('keys').children[7].hold()")
        #expect(try client.run("$('editInternet').checked && $('editBatteries').checked").toBool())
        #expect(try client.run("requests.length").toInt32() == 0)
        #expect(try client.run("JSON.stringify(draft) === originalControls && JSON.stringify(launcher.controls) === originalControls").toBool())
        try client.run("$('editSave').tap()")
        #expect(try client.run("requests.length === 1 && requests[0].method === 'POST' && requests[0].path.indexOf('/launcher?') === 0").toBool())
        #expect(try client.run("JSON.parse(decodeURIComponent(requests[0].body.split('&')[0].slice(9))).map(function(c){return c.id;}).join(',')").toString() == "stable-1,stable-2,stable-3,stable-4,stable-5,stable-6,stable-7")
        try client.reply(ready)
        #expect(try client.run("JSON.stringify(launcher.controls) === originalControls && $('keys').children.length === 8").toBool())
    }

    @Test func widgetDraftCancelAndSaveUseTheAuthoritativeResponse() throws {
        let client = try LauncherClientHarness()
        try client.run("loadKeys()")
        try client.reply(ready)
        try client.run("openEditor(); $('editInternet').checked = false; $('editBatteries').checked = false; $('editCancel').tap()")
        #expect(try client.run("$('net').style.display").toString() == "")
        #expect(try client.run("$('bat').style.display").toString() == "")
        #expect(try client.run("requests.length").toInt32() == 0)
        try client.run("openEditor()")
        #expect(try client.run("$('editInternet').checked && $('editBatteries').checked").toBool())
        try client.run("$('editInternet').checked = false; $('editSave').tap()")
        #expect(try client.run("requests[0].body.indexOf('&internet=0&batteries=1') >= 0").toBool())
        #expect(try client.run("$('net').style.display").toString() == "")
        try client.reply(ready.replacingOccurrences(of: #""internet":true"#, with: #""internet":false"#))
        #expect(try client.run("$('net').style.display").toString() == "none")
        #expect(try client.run("$('bat').style.display").toString() == "")
        #expect(try client.run("$('keys').children.length").toInt32() == 8)
    }

    @Test func oldServerWithoutWidgetSupportCannotReceiveAnAccidentalSave() throws {
        let client = try LauncherClientHarness()
        try client.run("loadKeys()")
        try client.reply(#"{"selected":["/A.app"],"all":[],"writable":true,"revision":"old"}"#)
        try client.run("openEditor(); $('editSave').tap()")
        #expect(try client.run("requests.length").toInt32() == 0)
        #expect(try client.run("$('editInternet').disabled && $('editBatteries').disabled").toBool())
    }

    @Test func startsReadOnlyUntilAConfigurationArrives() throws {
        let client = try LauncherClientHarness()
        #expect(try client.run("cfg.writable").toBool() == false)
        #expect(try client.run("$('cfgWarn').style.display").toString() == "block")
        try client.run("$('editSave').tap()")
        #expect(try client.run("requests.length").toInt32() == 0)
    }

    @Test func getRendersTheCatalogAndPreservesLaunchAndEditorControls() throws {
        let client = try LauncherClientHarness()
        try client.run("loadKeys()")
        try client.reply(ready)
        #expect(try client.run("$('keys').children.length").toInt32() == 8)
        #expect(try client.run("$('keys').children[0].lastChild.textContent").toString() == "A")
        #expect(try client.run("$('cfgWarn').style.display").toString() == "none")
        try client.run("$('keys').children[0].tap()")
        #expect(try client.run("requests[0].path").toString() == "/launch?k=test-token")
        #expect(try client.run("requests[0].body").toString() == "path=%2FA.app")
        try client.run("$('keys').children[0].hold()")
        #expect(try client.run("JSON.stringify(draft)").toString() == #"["/A.app"]"#)
        #expect(try client.run("$('editList').children[0].children[2].textContent").toString() == "A")
    }

    @Test func everyReadOnlyStateBlocksSavingWithoutChangingTheFullSelection() throws {
        let client = try LauncherClientHarness()
        for state in ["malformed", "unsupported-version", "unreadable", "wrong-format",
                      "unrepresentable", "too-many-controls", "legacy-readonly", "corrupt",
                      "migrating", "unreachable", "future-state"] {
            let json: [String: Any] = ["selected": (1...8).map { "/App\($0).app" }, "all": [],
                                       "configuration": state, "writable": false]
            let body = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            try client.run("loadKeys()")
            try client.reply(body)
            try client.run("openEditor(); $('editSave').tap()")
            #expect(try client.run("requests.length").toInt32() == 0)
            #expect(try client.run("launcher.selected.length").toInt32() == 8)
            #expect(try client.run("$('editSave').attributes['aria-disabled']").toString() == "true")
            #expect(try client.run("$('cfgWarn').textContent.length > 0").toBool())
        }
        try client.run("loadKeys()")
        try client.reply(#"{"selected":null,"all":[],"configuration":"unrepresentable","writable":false}"#)
        try client.run("openEditor(); $('editSave').tap()")
        #expect(try client.run("launcher.selected === null && requests.length === 0").toBool())
    }

    @Test func unavailableOrMalformedGetFailsClosedAndRetainsTheLastDeck() throws {
        let client = try LauncherClientHarness()
        try client.run("loadKeys()")
        try client.reply(ready)
        for (status, body) in [(0, ""), (503, "busy"), (200, "{"), (200, "{}"), (200, "null"), (200, "[]")] {
            try client.run("loadKeys()")
            try client.reply(body, status: status)
            #expect(try client.run("cfg.state").toString() == "unreachable")
            #expect(try client.run("launcher.selected[0]").toString() == "/A.app")
            try client.run("$('editSave').tap()")
            #expect(try client.run("requests.length").toInt32() == 0)
        }
    }

    @Test func failedSavesKeepTheDraftAndRevisionAndExplainTheRefusal() throws {
        let client = try LauncherClientHarness()
        try client.run("loadKeys()")
        try client.reply(ready)
        for (status, body, message) in [
            (409, "stale", "reload"), (400, "missing-revision", "reload"),
            (503, "busy", "busy"), (409, "too-many-controls", "7 keys"),
            (500, "write-failed", "write the file"), (500, "recovery-failed", "write the file"),
            (500, "migration-failed", "write the file"), (0, "", "cannot reach"),
            (409, "malformed", "read-only"), (500, "", "Save failed")
        ] {
            try client.run("draft = ['/B.app']; $('editSave').tap()")
            try client.reply(body, status: status)
            #expect(try client.run("JSON.stringify(draft)").toString() == #"["/B.app"]"#)
            #expect(try client.run("cfg.revision").toString() == "revision-a")
            #expect(try client.run("launcher.selected[0]").toString() == "/A.app")
            #expect(try client.run("notices[notices.length - 1]").toString().contains(message))
            #expect(try client.run("sheets.length").toInt32() == 0)
        }
    }

    @Test func malformedSuccessfulSaveDoesNotClaimSuccessOrPermitAnotherWrite() throws {
        let client = try LauncherClientHarness()
        try client.run("loadKeys()")
        try client.reply(ready)
        try client.run("draft = ['/B.app']; $('editSave').tap()")
        try client.reply("{}")
        #expect(try client.run("cfg.writable").toBool() == false)
        #expect(try client.run("launcher.selected[0]").toString() == "/A.app")
        #expect(try client.run("sheets.length").toInt32() == 0)
        try client.run("$('editSave').tap()")
        #expect(try client.run("requests.length").toInt32() == 0)
    }
}
