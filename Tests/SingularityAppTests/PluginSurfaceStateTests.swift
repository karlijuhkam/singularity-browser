import Foundation
import MCP
import Testing
@testable import Singularity
import SingularityCore

// Bun and the plugin host in the repository (only the test with a running plugin needs them).
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

extension AppTests {
/// A plugin's page in the right-hand panel or a tab, in a real `AppState` on a temporary data folder
/// (no window). The fixture plugin is `PanelWorkspace`'s "panelfix"; it is not approved (so it does
/// not run) except in the one test that needs its page.
@MainActor
@Suite(.serialized) struct PluginSurfaceStateTests {
    private let id = PanelWorkspace.id

    /// A state on the workspace's data folder, past the welcome flow, once the plugin is scanned.
    private func makeState(_ ws: PanelWorkspace, plugins: PluginManager? = nil) async throws -> AppState {
        MainRunLoopGuard.start
        let state = TestAppState.make(root: ws.root, plugins: plugins)
        state.closeWelcome()
        try await waitUntil("the plugin to be scanned") { !state.plugins.panelPlugins().isEmpty }
        return state
    }

    private func pluginTabs(_ state: AppState) -> [BrowserTab] {
        state.spaces.flatMap(\.tabs).filter { $0.pluginID == PanelWorkspace.id }
    }

    @Test func theToggleOpensAndClosesThePanelAndSavesIt() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }

        #expect(state.shownPanelPlugin == nil)
        state.togglePluginPanel()
        #expect(state.settings.pluginPanel == id)
        #expect(state.shownPanelPlugin == id)
        state.flushSaves()
        #expect(SpaceStore(paths: ws.paths).loadSettings().pluginPanel == id)

        state.togglePluginPanel()
        #expect(state.settings.pluginPanel == nil)
        #expect(state.shownPanelPlugin == nil)
        state.flushSaves()
        #expect(SpaceStore(paths: ws.paths).loadSettings().pluginPanel == nil)
        #expect(pluginTabs(state).isEmpty)
    }

    /// Someone who updated never saw the welcome flow's step 4: with no panel plugin installed, the
    /// toggle offers a shipped one ("Show Assistant") and opens Settings → Plugins, which lists it.
    @Test func withNoPanelPluginTheToggleOffersTheShippedOne() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        state.closeWelcome()
        try await waitUntil("the first scan") { state.plugins.firstScanDone }
        #expect(state.plugins.panelPlugins().isEmpty)
        let folder = URL(fileURLWithPath: "/nonexistent")
        let onePassword = BundledPlugin(id: "1password", name: "1Password", summary: "", folder: folder)
        let assistant = BundledPlugin(id: "assistant", name: "Assistant", summary: "", folder: folder, panelTitle: "Assistant")

        // A bare debug binary ships nothing: the generic item, off.
        state.bundledPlugins = []
        #expect(state.pluginPanelCommandTitle == "Show Plugin Panel")
        #expect(!state.pluginPanelCommandEnabled)
        // Shipped plugins, none with a panel: the same.
        state.bundledPlugins = [onePassword]
        #expect(state.pluginPanelCommandTitle == "Show Plugin Panel")
        #expect(!state.pluginPanelCommandEnabled)

        // The Assistant is shipped: "Show Assistant", on, and it opens Settings → Plugins.
        state.bundledPlugins = [onePassword, assistant]
        #expect(state.bundledPanelOffer == "Assistant")
        #expect(state.pluginPanelCommandTitle == "Show Assistant")
        #expect(state.pluginPanelCommandEnabled)
        state.settingsTab = .general
        state.togglePluginPanel()
        #expect(state.settingsTab == .plugins)
        #expect(state.settings.pluginPanel == nil)
        // Settings → Plugins offers both, as nothing is installed.
        #expect(BundledPlugins.notInstalled(state.bundledPlugins, installedIDs: Set(state.plugins.plugins.map(\.id)))
                    .map(\.id) == ["1password", "assistant"])
        // Not while the welcome flow covers the window.
        state.showWelcome()
        #expect(!state.pluginPanelCommandEnabled)
    }

    /// With a panel plugin installed, the toggle is about that one, whatever the app ships.
    @Test func anInstalledPanelPluginWinsOverTheOffer() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }
        state.bundledPlugins = [BundledPlugin(id: "assistant", name: "Assistant", summary: "",
                                              folder: URL(fileURLWithPath: "/nonexistent"), panelTitle: "Assistant")]
        #expect(state.bundledPanelOffer == nil)
        #expect(state.pluginPanelCommandTitle == "Show Fixture Panel")
        state.togglePluginPanel()
        #expect(state.pluginPanelCommandTitle == "Hide Fixture Panel")
        #expect(state.settings.pluginPanel == id)
    }

    @Test func openAsTabMakesOneTabAndClosesThePanel() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }

        state.togglePluginPanel()
        state.openPluginPageAsTab(id)
        let tabs = pluginTabs(state)
        #expect(tabs.count == 1)
        #expect(tabs.first?.title == "Fixture Panel")
        #expect(state.selectedTab?.id == tabs.first?.id)
        #expect(state.settings.pluginPanel == nil)
        #expect(state.shownPanelPlugin == nil)

        // Again, also from another Space: still exactly one tab, now in the selected Space.
        let other = state.createSpace(name: "Other", colorHex: SpaceColors.presets[1], workingDirectory: "~")
        state.openPluginPageAsTab(id)
        #expect(pluginTabs(state).count == 1)
        #expect(state.space(other.id)?.tabs.map(\.pluginID) == [id])
        #expect(state.selectedTab?.pluginID == id)
    }

    @Test func moveToSidePanelRemovesTheTab() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }

        state.openPluginPageAsTab(id)
        #expect(pluginTabs(state).count == 1)
        state.movePluginPageToPanel(id)
        #expect(pluginTabs(state).isEmpty)
        #expect(state.settings.pluginPanel == id)
        #expect(state.shownPanelPlugin == id)
    }

    @Test func theToggleSelectsThePageWhenItIsATab() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }

        let first = try #require(state.selectedSpaceID)
        state.openPluginPageAsTab(id)
        let tab = try #require(pluginTabs(state).first)
        // The owner goes elsewhere; the toggle takes him back to the tab and opens no panel.
        _ = state.createSpace(name: "Other", colorHex: SpaceColors.presets[1], workingDirectory: "~")
        #expect(state.selectedSpaceID != first)
        state.togglePluginPanel()
        #expect(state.selectedSpaceID == first)
        #expect(state.selectedTab?.id == tab.id)
        #expect(state.settings.pluginPanel == nil)
        #expect(pluginTabs(state).count == 1)
    }

    @Test func theToggleDoesNothingWhileTheWelcomeFlowCoversTheWindow() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }

        state.showWelcome()
        #expect(state.welcomeCoversWindow)
        state.togglePluginPanel()
        #expect(state.settings.pluginPanel == nil)
        #expect(state.welcomeCoversWindow)

        // An open panel is hidden by the flow, and the toggle doesn't close it behind it either.
        state.closeWelcome()
        state.togglePluginPanel()
        state.showWelcome()
        #expect(state.shownPanelPlugin == nil)
        state.togglePluginPanel()
        #expect(state.settings.pluginPanel == id)
        state.closeWelcome()
        #expect(state.shownPanelPlugin == id)
    }

    /// Review Focus 5: a saved tab of a plugin that is gone loads, and shows the native page.
    @Test func aTabOfAnUnknownPluginLoadsAndSaysSo() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = BrowserTab.plugin(pluginID: "ghost", title: "Ghost")
        let space = Space(name: "Work", slug: "work", colorHex: SpaceColors.presets[0], tabs: [tab], selectedTabID: tab.id)
        let store = SpaceStore(paths: Paths(root: root))
        try store.save(space)
        try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))

        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        #expect(state.loadErrors.isEmpty)
        #expect(state.selectedTab?.kind == .plugin(pluginID: "ghost"))
        state.loadSelectedTab()
        // Before the plugins folder was read, it may just not be known yet: "starting", not "isn't installed".
        #expect(!state.plugins.firstScanDone)
        guard case .starting(let starting) = state.pluginPageContent("ghost", fallbackTitle: tab.title) else {
            Issue.record("expected the starting page")
            return
        }
        #expect(starting == "Ghost is starting")
        try await waitUntil("the first scan") { state.plugins.firstScanDone }
        guard case .notRunning(let title, let reason) = state.pluginPageContent("ghost", fallbackTitle: tab.title) else {
            Issue.record("expected the native page")
            return
        }
        #expect(title == "Ghost isn't running")
        #expect(reason == "This plugin isn't installed.")
    }

    @Test func agentToolsLeavePluginTabsAlone() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        let state = try await makeState(ws)
        defer { TestAppState.shutDown(state) }

        let spaceID = try #require(state.selectedSpaceID)
        state.setAgentsEnabled(true, spaceID: spaceID)
        state.openPluginPageAsTab(id)
        let tab = try #require(pluginTabs(state).first)
        let slug = try #require(state.space(spaceID)?.slug)
        let toolbox = AgentToolbox(state: state)

        let list = await toolbox.call("\(slug).list_tabs", arguments: [:], client: "test")
        #expect(list.isError != true)
        #expect(!text(list).contains(tab.id.uuidString.lowercased()))

        for tool in ["read_page", "screenshot", "close", "read_console"] {
            let result = await toolbox.call("\(slug).\(tool)", arguments: ["tab_id": .string(tab.id.uuidString.lowercased())],
                                            client: "test")
            #expect(result.isError == true, "\(tool)")
            #expect(text(result).contains("not a web page"), "\(tool): \(text(result))")
        }
        #expect(pluginTabs(state).count == 1)
    }

    /// The page area follows the plugin: its page while it runs, the native page once it stops.
    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"), .timeLimit(.minutes(1)))
    func thePageAreaFollowsThePlugin() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        try ws.approve()
        let manager = PluginManager(paths: ws.paths, runtime: bunPath, host: hostScript,
                                    programs: .live(environment: [:], loginPath: { "/usr/bin:/bin" }))
        let state = try await makeState(ws, plugins: manager)
        defer { TestAppState.shutDown(state) }
        try await waitUntil("the plugin to run", limit: .seconds(20)) { state.plugins.plugin(id)?.runState == .running }

        guard case .page(let host) = state.pluginPageContent(id) else {
            Issue.record("expected the plugin's page")
            return
        }
        #expect(host.pluginID == id)

        // An edit pauses it: the native page, with the status text as the reason.
        try Data("// edited\n".utf8).write(to: ws.plugin.appending(path: "panel.js"), options: .atomic)
        state.plugins.start()
        try await waitUntil("the plugin to pause", limit: .seconds(10)) { state.plugins.plugin(id)?.status == .changed }
        guard case .notRunning(let title, let reason) = state.pluginPageContent(id) else {
            Issue.record("expected the native page")
            return
        }
        #expect(title == "Fixture Panel isn't running")
        #expect(reason == "Changed since you approved it")
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }
}
}
