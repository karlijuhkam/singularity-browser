import Foundation
import Testing
@testable import SingularityCore

@Suite struct PluginSurfaceTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: the tab kind

    @Test func pluginKindCodesBothWays() throws {
        let tab = BrowserTab.plugin(pluginID: "assistant", title: "Assistant")
        let again = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
        #expect(again == tab)
        #expect(again.pluginID == "assistant")
        #expect(again.isPlugin && !again.isTerminal && !again.isArtifact)
        #expect(again.url == nil && again.workingDirectory == nil && again.artifactPath == nil)
        #expect(again.projectID == nil)
        #expect(again.displayTitle == "Assistant")
        #expect(BrowserTab.plugin(pluginID: "assistant").displayTitle == "assistant")
    }

    @Test func oldFilesStillLoad() throws {
        let web = try decode(BrowserTab.self, #"{"id":"10000000-0000-0000-0000-000000000001","kind":{"web":{"url":"https://a.test/"}}}"#)
        #expect(web.url?.host() == "a.test" && !web.isPlugin)
        let terminal = try decode(BrowserTab.self, #"{"id":"10000000-0000-0000-0000-000000000002","kind":{"terminal":{"workingDirectory":"~"}}}"#)
        #expect(terminal.isTerminal)
        let artifact = try decode(BrowserTab.self, #"{"id":"10000000-0000-0000-0000-000000000003","kind":{"artifact":{"path":"a/index.html"}}}"#)
        #expect(artifact.isArtifact)
    }

    // MARK: settings

    @Test func panelSettings() throws {
        let none = try decode(AppSettings.self, "{}")
        #expect(none.pluginPanel == nil && none.pluginPanelWidth == PluginPanelLayout.defaultWidth)
        let wrong = try decode(AppSettings.self, #"{"pluginPanel": 5, "pluginPanelWidth": "wide"}"#)
        #expect(wrong.pluginPanel == nil && wrong.pluginPanelWidth == 380)
        let set = try decode(AppSettings.self, #"{"pluginPanel": "assistant", "pluginPanelWidth": 500}"#)
        #expect(set.pluginPanel == "assistant" && set.pluginPanelWidth == 500)
        #expect(try decode(AppSettings.self, #"{"pluginPanelWidth": 10}"#).pluginPanelWidth == 300)
        #expect(try decode(AppSettings.self, #"{"pluginPanelWidth": 5000}"#).pluginPanelWidth == 720)
        #expect(PluginPanelLayout.clamp(.nan) == 380)
        var settings = AppSettings()
        settings.pluginPanel = "assistant"
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.pluginPanel == "assistant")
    }

    // MARK: where the page is

    private func space(_ name: String, _ tabs: [BrowserTab]) -> Space {
        var s = Space(name: name, slug: name, colorHex: "#000000")
        s.tabs = tabs
        return s
    }

    @Test func placeOfAPage() {
        let tab = BrowserTab.plugin(pluginID: "assistant")
        let other = BrowserTab.plugin(pluginID: "other")
        let a = space("a", [.web(URL(string: "https://a.test/")!)])
        let b = space("b", [other, tab])
        #expect(PluginSurface.place(of: "assistant", panel: nil, spaces: [a, b]) == .tab(space: b.id, tab: tab.id))
        #expect(PluginSurface.place(of: "assistant", panel: nil, spaces: [a]) == .hidden)
        #expect(PluginSurface.place(of: "assistant", panel: "assistant", spaces: [a]) == .panel)
        #expect(PluginSurface.place(of: "assistant", panel: "other", spaces: [a]) == .hidden)
        // A tab wins over the panel.
        #expect(PluginSurface.place(of: "assistant", panel: "assistant", spaces: [a, b]) == .tab(space: b.id, tab: tab.id))
        // Two tabs: the first in Space order.
        let second = BrowserTab.plugin(pluginID: "assistant")
        let c = space("c", [second])
        #expect(PluginSurface.place(of: "assistant", panel: nil, spaces: [b, c]) == .tab(space: b.id, tab: tab.id))
    }

    @Test func tabsToRemove() {
        let one = BrowserTab.plugin(pluginID: "assistant")
        let two = BrowserTab.plugin(pluginID: "assistant")
        let other = BrowserTab.plugin(pluginID: "other")
        let s = space("a", [one, other, .web(URL(string: "https://a.test/")!), two])
        #expect(PluginSurface.tabsToRemove(for: "assistant", in: s) == [one.id, two.id])
        #expect(PluginSurface.tabsToRemove(for: "none", in: s).isEmpty)
    }

    // MARK: import map

    private func map(_ packages: [String: String]) -> [String: String] {
        PluginImportMap.make(dependencies: packages.keys.sorted()) { packages[$0]?.data(using: .utf8) }
    }

    @Test func preactShapedPackage() {
        let result = map(["preact": """
        {"name":"preact","main":"dist/preact.js","module":"dist/preact.module.js","exports":{
          ".":{"types":"./src/index.d.ts","browser":"./dist/preact.module.js","umd":"./dist/preact.umd.js","import":"./dist/preact.mjs","require":"./dist/preact.js"},
          "./hooks":{"types":"./hooks/src/index.d.ts","browser":"./hooks/dist/hooks.module.js","import":"./hooks/dist/hooks.mjs"},
          "./jsx-runtime":{"import":"./jsx-runtime/dist/jsxRuntime.mjs","require":"./jsx-runtime/dist/jsxRuntime.js"},
          "./package.json":"./package.json",
          "./compat/*":"./compat/*.js"}}
        """])
        #expect(result == [
            "preact": "/node_modules/preact/dist/preact.module.js",
            "preact/hooks": "/node_modules/preact/hooks/dist/hooks.module.js",
            "preact/jsx-runtime": "/node_modules/preact/jsx-runtime/dist/jsxRuntime.mjs",
        ])
    }

    @Test func nestedConditionsAndFallbacks() {
        let result = map([
            "nested": #"{"exports":{".":{"node":"./n.js","import":{"types":"./t.d.ts","default":"./esm.mjs"}}}}"#,
            "mainonly": #"{"main":"lib/index.js"}"#,
            "modulefirst": #"{"main":"a.js","module":"./b.js"}"#,
            "missing-json": "not json",
        ])
        #expect(result["nested"] == "/node_modules/nested/esm.mjs")
        #expect(result["mainonly"] == "/node_modules/mainonly/lib/index.js")
        #expect(result["modulefirst"] == "/node_modules/modulefirst/b.js")
        #expect(result["missing-json"] == nil)
        #expect(PluginImportMap.make(dependencies: ["gone"]) { _ in nil }.isEmpty)
    }

    @Test func hostileTargetsAndPatternsAreLeftOut() {
        let result = map(["evil": """
        {"exports":{".":"../../x.js","./a":"./ok/../../y.js","./b":"/abs.js","./c":"x.js","./d/*":"./d/*.js","./e":"./e.js"}}
        """])
        #expect(result == ["evil/e": "/node_modules/evil/e.js"])
    }
}
