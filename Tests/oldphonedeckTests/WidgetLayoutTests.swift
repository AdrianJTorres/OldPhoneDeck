import Testing

/// Exercises the shipped descriptor-based placement without a browser or Mac actions.
@Suite struct WidgetLayoutTests {
    @Test func descriptorAdditionUsesTheExistingRowAndColumn() throws {
        let client = try LauncherClientHarness()
        try client.run("""
        function px(el, props) { for (var k in props) el.style[k] = props[k] + 'px'; }
        WIDGET_CARDS.push({id:'future', preference:'future'});
        var row = layoutWidgetCards({left:16, top:500, width:328, height:104});
        var column = layoutWidgetCards({left:336, top:52, width:128, height:252, vertical:true});
        """)
        #expect(try client.run("row.future.left + row.future.width").toDouble() == 344)
        #expect(try client.run("row.net.width === row.bat.width && row.bat.width === row.future.width").toBool())
        #expect(try client.run("column.net.height").toDouble() == 104)
        #expect(try client.run("column.bat.height").toDouble() == 64)
        #expect(try client.run("column.future.top + column.future.height").toDouble() == 304)
        #expect(try client.run("requests.length").toInt32() == 0)
    }

    @Test func hiddenWidgetsKeepTheirGeometryAndUseTheSameDescriptors() throws {
        let client = try LauncherClientHarness()
        try client.run("""
        function px(el, props) { for (var k in props) el.style[k] = props[k] + 'px'; }
        var region = {left:16, top:500, width:328, height:104};
        var before = JSON.stringify(layoutWidgetCards(region));
        launcher.widgets = {internet:false, batteries:true}; applyWidgets();
        var after = JSON.stringify(layoutWidgetCards(region));
        """)
        #expect(try client.run("before === after").toBool())
        #expect(try client.run("$('net').style.display").toString() == "none")
        #expect(try client.run("$('bat').style.display").toString() == "")
    }
}
