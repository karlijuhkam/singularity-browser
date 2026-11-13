import Foundation
import Testing
@testable import SingularityCore

@Suite struct PluginReachTests {
    /// A plugin folder named `t` with the given `plugin.json` pieces.
    private func load(permissions: String, page: Bool = false, panel: Bool = false) throws -> PluginManifest {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sing-reach-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "t", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        try Data("// stub".utf8).write(to: dir.appending(path: "page.ts"))
        try Data("<p>hi</p>".utf8).write(to: dir.appending(path: "panel.html"))
        var json = #"{"id":"t","name":"T","version":"1","description":"d","author":"a","background":"background.ts","permissions":\#(permissions)"#
        if page { json += #","page":{"script":"page.ts","sites":["https://example.com/*"]}"# }
        if panel { json += #","panel":{"page":"panel.html","title":"Assistant"}"# }
        json += "}"
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
        return try PluginManifest.load(from: dir)
    }

    // MARK: manifest

    @Test func theNewPermissionsDecode() throws {
        let m = try load(permissions: #"{"frontTab":true,"browser":true,"programs":["x"]}"#)
        #expect(m.permissions.frontTab && m.permissions.browser)
        let plain = try load(permissions: "{}")
        #expect(!plain.permissions.frontTab && !plain.permissions.browser)
    }

    @Test func browserNeedsAProgram() {
        #expect(throws: PluginError.browserNeedsProgram) { _ = try load(permissions: #"{"browser":true}"#) }
        #expect(PluginError.browserNeedsProgram.userMessage
                == "it asks to use the browser but keeps no program running")
    }

    @Test func unknownPermissionStillFails() {
        #expect(throws: PluginError.unknownPermission("cookies")) {
            _ = try load(permissions: #"{"frontTab":true,"cookies":[]}"#)
        }
    }

    @Test func wideningNeedsApproval() {
        let none = PluginManifest.Permissions()
        #expect(PluginManifest.Permissions(frontTab: true).widens(none))
        #expect(PluginManifest.Permissions(programs: ["x"], browser: true).widens(.init(programs: ["x"])))
        #expect(!none.widens(.init(frontTab: true, browser: true)))
        #expect(!PluginManifest.Permissions(frontTab: true).widens(.init(frontTab: true)))
    }

    @Test func spaceSwitchesShowFollowThePowers() throws {
        #expect(try load(permissions: #"{"pageAdditions":["<all_urls>"]}"#, page: true).showsSpaceSwitches)
        let panelOnly = try load(permissions: "{}", panel: true)
        #expect(!panelOnly.showsSpaceSwitches && !panelOnly.reachesSpaces)
        let withFront = try load(permissions: #"{"frontTab":true}"#, panel: true)
        #expect(withFront.showsSpaceSwitches && withFront.reachesSpaces)
    }

    @Test func descriptionsSayWhatThePowersAre() {
        let lines = PermissionDescriptions.lines(for: .init(programs: ["x"], frontTab: true, browser: true),
                                                 commandPaths: [:])
        #expect(lines.contains("Know which tab is in front (its Space, title and address), in Spaces where it is switched on"))
        #expect(lines.contains("Use the browser like an agent, in Spaces where it is switched on: read pages, "
                               + "and open, click and type under each Space's agent policy"))
        let none = PermissionDescriptions.lines(for: .init(), commandPaths: [:])
        #expect(!none.contains { $0.hasPrefix("Know which tab") || $0.hasPrefix("Use the browser") })
    }

    // MARK: rules

    private func approval(_ spaces: Set<UUID>, permissions: PluginManifest.Permissions = .init()) -> PluginApproval {
        PluginApproval(fingerprint: "f", permissions: permissions, commandPaths: [:], enabledSpaces: spaces,
                       developmentMode: false, approvedAt: Date(timeIntervalSince1970: 0))
    }

    private func space(_ tabs: [BrowserTab], selected: BrowserTab?, sites: [String: SiteSettings] = [:]) -> Space {
        Space(name: "Work", slug: "work", colorHex: "#000000", tabs: tabs, selectedTabID: selected?.id,
              siteSettings: sites)
    }

    @Test func spaceIsOpenNeedsApprovalAndTheSwitch() {
        let s = space([], selected: nil)
        #expect(PluginReach.spaceIsOpen(s, approval: approval([s.id]), status: .approved))
        #expect(!PluginReach.spaceIsOpen(s, approval: approval([]), status: .approved))
        #expect(!PluginReach.spaceIsOpen(s, approval: approval([s.id]), status: .changed))
        #expect(!PluginReach.spaceIsOpen(s, approval: nil, status: .approved))
    }

    @Test func siteIsOffReadsTheSiteSettings() {
        let url = URL(string: "https://example.com/a?b=1")!
        let off = space([], selected: nil, sites: ["https://example.com": SiteSettings(disabledPlugins: ["t"])])
        #expect(PluginReach.siteIsOff(off, pluginID: "t", url: url))
        #expect(!PluginReach.siteIsOff(off, pluginID: "other", url: url))
        #expect(!PluginReach.siteIsOff(off, pluginID: "t", url: URL(string: "https://other.com/")!))
        #expect(!PluginReach.siteIsOff(off, pluginID: "t", url: nil))
    }

    @Test func listedForSiteNeedsTheSpaceAndAReason() throws {
        let url = URL(string: "https://example.com/x")!
        let s = space([], selected: nil)
        // Reaches Spaces: listed everywhere the Space is on.
        let reaching = try load(permissions: #"{"frontTab":true}"#)
        let reachApproval = approval([s.id], permissions: reaching.permissions)
        #expect(PluginReach.listedForSite(manifest: reaching, approval: reachApproval, space: s, url: url))
        #expect(!PluginReach.listedForSite(manifest: reaching, approval: approval([], permissions: reaching.permissions),
                                           space: s, url: url))
        // Page script: only where it runs.
        let scripted = try load(permissions: #"{"pageAdditions":["https://example.com/*"]}"#, page: true)
        let scriptApproval = approval([s.id], permissions: scripted.permissions)
        #expect(PluginReach.listedForSite(manifest: scripted, approval: scriptApproval, space: s, url: url))
        #expect(!PluginReach.listedForSite(manifest: scripted, approval: scriptApproval, space: s,
                                           url: URL(string: "https://elsewhere.org/")!))
        // Neither.
        let plain = try load(permissions: "{}", panel: true)
        #expect(!PluginReach.listedForSite(manifest: plain, approval: approval([s.id]), space: s, url: url))
    }

    // MARK: front

    private func front(_ s: Space?, open: Bool = true, welcome: Bool = false, other: UUID? = nil) -> PluginReach.Front {
        PluginReach.front(pluginID: "t", space: s, spaceIsOpen: open, welcomeCoversWindow: welcome, lastOtherPane: other)
    }

    @Test func aWebTabIsCutToLength() {
        let long = "https://example.com/" + String(repeating: "a", count: 3000)
        let tab = BrowserTab.web(URL(string: long)!, title: String(repeating: "t", count: 500))
        guard case .tab(let f) = front(space([tab], selected: tab)) else { Issue.record("no tab"); return }
        #expect(f.space == .init(slug: "work", name: "Work"))
        #expect(f.tab.id == tab.id.uuidString.lowercased())
        #expect(f.tab.kind == "web")
        #expect(f.tab.title?.count == 300)
        #expect(f.tab.url?.count == 2000)
    }

    @Test func anArtifactReportsItsPath() {
        let tab = BrowserTab.artifact(path: "report/index.html")
        guard case .tab(let f) = front(space([tab], selected: tab)) else { Issue.record("no tab"); return }
        #expect(f.tab.kind == "artifact")
        #expect(f.tab.url == "report/index.html")
        #expect(f.tab.title == "index.html")
    }

    @Test func aTerminalHasNoTitleOrAddress() {
        let tab = BrowserTab.terminal(workingDirectory: "~/secret")
        guard case .tab(let f) = front(space([tab], selected: tab)) else { Issue.record("no tab"); return }
        #expect(f.tab.kind == "terminal")
        #expect(f.tab.title == nil && f.tab.url == nil)
    }

    @Test func aPluginTabLooksAtTheLastOtherPane() {
        let plugin = BrowserTab.plugin(pluginID: "t")
        let web = BrowserTab.web(URL(string: "https://example.com/")!, title: "Ex")
        let otherPlugin = BrowserTab.plugin(pluginID: "u")
        let s = space([plugin, web, otherPlugin], selected: plugin)
        #expect(front(s, other: nil) == .hidden(.nothing))
        guard case .tab(let f) = front(s, other: web.id) else { Issue.record("no tab"); return }
        #expect(f.tab.id == web.id.uuidString.lowercased())
        #expect(front(s, other: otherPlugin.id) == .hidden(.nothing))
        #expect(front(s, other: UUID()) == .hidden(.nothing))
    }

    @Test func anArtifactTabsLivePageCountsWhereItIs() {
        let tab = BrowserTab.artifact(path: "report/index.html")
        let server = URL(string: "http://127.0.0.1:50123/")!
        let off = space([tab], selected: tab, sites: ["https://off.example": SiteSettings(disabledPlugins: ["t"])])
        func front(live: URL?) -> PluginReach.Front {
            PluginReach.front(pluginID: "t", space: off, spaceIsOpen: true, welcomeCoversWindow: false, lastOtherPane: nil,
                              liveURL: { $0 == tab.id ? live : nil }, artifactOrigin: server)
        }
        // Its live page on a switched-off site: hidden.
        #expect(front(live: URL(string: "https://off.example/x")!) == .hidden(.siteOff))
        // On another site: reported as that web page, with the live address, never as the artifact.
        guard case .tab(let elsewhere) = front(live: URL(string: "https://other.example/y")!) else { Issue.record("no tab"); return }
        #expect(elsewhere.tab.kind == "web" && elsewhere.tab.url == "https://other.example/y")
        // Still on the artifact server: the artifact, as before.
        guard case .tab(let home) = front(live: URL(string: "http://127.0.0.1:50123/report/index.html")!) else { Issue.record("no tab"); return }
        #expect(home.tab.kind == "artifact" && home.tab.url == "report/index.html")
        // No live page: as before.
        guard case .tab(let none) = front(live: nil) else { Issue.record("no tab"); return }
        #expect(none.tab.kind == "artifact" && none.tab.url == "report/index.html")
    }

    @Test func aWebTabsLiveAddressIsChecked() {
        let tab = BrowserTab.web(URL(string: "https://fine.example/")!)
        let off = space([tab], selected: tab, sites: ["https://off.example": SiteSettings(disabledPlugins: ["t"])])
        let live = PluginReach.front(pluginID: "t", space: off, spaceIsOpen: true, welcomeCoversWindow: false,
                                     lastOtherPane: nil, liveURL: { _ in URL(string: "https://off.example/z") })
        #expect(live == .hidden(.siteOff))
    }

    /// While the tab's live page is loading another address, its stored title may still be the
    /// previous page's: the title is left out (the address's host stands in for it).
    @Test func aTitleThatIsNotCurrentIsLeftOut() {
        let tab = BrowserTab.web(URL(string: "https://fine.example/next")!, title: "Old page's title")
        let s = space([tab], selected: tab)
        func title(current: Bool) -> String? {
            guard case .tab(let f) = PluginReach.front(pluginID: "t", space: s, spaceIsOpen: true, welcomeCoversWindow: false,
                                                       lastOtherPane: nil, titleIsCurrent: { _ in current }) else { return nil }
            return f.tab.title
        }
        #expect(title(current: true) == "Old page's title")
        #expect(title(current: false) == "fine.example")
        #expect(tab.untitledDisplayTitle == "fine.example")
    }

    @Test func hiddenReasons() {
        let tab = BrowserTab.web(URL(string: "https://example.com/")!)
        let s = space([tab], selected: tab)
        #expect(front(s, open: false) == .hidden(.spaceOff))
        #expect(front(s, welcome: true) == .hidden(.nothing))
        #expect(front(nil) == .hidden(.nothing))
        #expect(front(space([], selected: nil)) == .hidden(.nothing))
        // A Space not open to the plugin is "off" with or without a tab (the strip offers it).
        #expect(front(space([], selected: nil), open: false) == .hidden(.spaceOff))
        #expect(front(space([tab], selected: nil), open: false) == .hidden(.spaceOff))
        // The welcome flow and no Space stay "nothing", also for a closed Space.
        #expect(front(s, open: false, welcome: true) == .hidden(.nothing))
        #expect(front(nil, open: false) == .hidden(.nothing))
        let off = space([tab], selected: tab, sites: ["https://example.com": SiteSettings(disabledPlugins: ["t"])])
        #expect(front(off) == .hidden(.siteOff))
        // A site switch is about web pages: a terminal is unaffected.
        let term = BrowserTab.terminal(workingDirectory: "~")
        #expect(front(space([term], selected: term, sites: off.siteSettings)) != .hidden(.siteOff))
    }

    @Test func inboxEntriesHaveNoPluginByDefault() {
        let e = InboxEntry(kind: .done, spaceID: UUID(), tabID: nil, agent: "x", message: nil, arrived: Date())
        #expect(e.pluginID == nil)
        #expect(InboxEntry(kind: .done, spaceID: UUID(), tabID: nil, agent: "x", message: nil, arrived: Date(),
                           pluginID: "t").pluginID == "t")
    }
}
