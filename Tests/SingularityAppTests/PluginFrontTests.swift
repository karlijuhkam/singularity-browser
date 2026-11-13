import Foundation
import Testing
@testable import Singularity
import SingularityCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

/// A data folder with one plugin, "frontfix": a background that answers page messages with what
/// `singularity.front()` and `singularity.browser.server()` say and records every `onFrontChange`.
/// `frontTab` and `browser` switch the two permissions (and the program `browser` needs).
private struct FrontWorkspace {
    static let id = "frontfix"
    let root: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }
    let frontTab: Bool

    init(frontTab: Bool = true, browser: Bool = false) throws {
        self.frontTab = frontTab
        root = URL(filePath: "/private/tmp/sg-fr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let plugin = Paths(root: root).pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: plugin.appending(path: path)) }
        let permissions = [frontTab ? #""frontTab": true"# : nil, browser ? #""browser": true, "programs": ["fixture"]"# : nil]
            .compactMap { $0 }.joined(separator: ", ")
        try write("plugin.json", """
            {"id": "frontfix", "name": "Front Fixture", "version": "1.0.0", "description": "A test plugin.",
             "author": "Tests", "background": "background.ts",
             "panel": {"page": "panel.html", "title": "Front Fixture"},
             "permissions": {\(permissions)}}
            """)
        try write("panel.html", "<!doctype html><html><head><title>x</title></head><body></body></html>")
        try write("background.ts", """
            import { singularity } from "singularity";
            const changes: unknown[] = [];
            try { singularity.onFrontChange((front) => { changes.push(front); }); } catch {}
            singularity.onPageMessage(async ({ payload }) => {
              try {
                if (payload === "front") return { front: await singularity.front() };
                if (payload === "browser") return { browser: await singularity.browser.server() };
                if (payload === "changes") return { changes };
              } catch (error) { return { error: String((error as Error).message) }; }
              return null;
            });
            """)
    }

    func approve() throws {
        let scan = PluginScan.scan(folder: plugin)
        guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "the fixture doesn't scan: \(scan.manifest)"])
        }
        let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                      commandPaths: ["fixture": "/usr/bin/true"], enabledSpaces: [],
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

extension AppTests {
/// The tab in front and the browser server reach a plugin's background, with a real `AppState`.
@MainActor
@Suite(.serialized, .enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct PluginFrontTests {
    private struct Rig {
        let ws: FrontWorkspace
        let appRoot: URL
        let manager: PluginManager
        let state: AppState
        let spaceID: UUID
        let a: BrowserTab
        let b: BrowserTab
    }

    /// A state with one Space and two web tabs (b selected), the plugin approved and running, and
    /// the plugin switched on for the Space when `on`.
    private func makeRig(frontTab: Bool = true, browser: Bool = false, on: Bool = true) async throws -> Rig {
        let ws = try FrontWorkspace(frontTab: frontTab, browser: browser)
        try ws.approve()
        let manager = PluginManager(paths: ws.paths, runtime: bunPath, host: hostScript,
                                    programs: .live(environment: [:], loginPath: { "/usr/bin:/bin" }))
        let appRoot = TestAppState.makeRoot()
        let state = TestAppState.make(root: appRoot, plugins: manager)
        state.closeWelcome()
        let spaceID = try #require(state.selectedSpaceID)
        state.openInNewTab(URL(string: "https://a.example/page")!)
        state.openInNewTab(URL(string: "https://b.example/")!)
        let tabs = try #require(state.selectedSpace?.tabs)
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(FrontWorkspace.id)?.runState == .running }
        if on { manager.setEnabled(FrontWorkspace.id, space: spaceID, true) }
        return Rig(ws: ws, appRoot: appRoot, manager: manager, state: state, spaceID: spaceID, a: tabs[0], b: tabs[1])
    }

    private func tearDown(_ rig: Rig) {
        TestAppState.shutDown(rig.state)
        rig.manager.terminateAll()
        rig.ws.remove()
        try? FileManager.default.removeItem(at: rig.appRoot)
    }

    private func frontTab(_ front: PluginReach.Front) -> FrontTab? {
        if case .tab(let tab) = front { return tab }
        return nil
    }

    @Test(.timeLimit(.minutes(1))) func theFrontTabFollowsTheSelectionAndTheSwitches() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = FrontWorkspace.id

        // The selected web tab, with its title and address.
        rig.state.webTabDidChange(tabID: rig.b.id, spaceID: rig.spaceID, title: "Bee", url: URL(string: "https://b.example/x"))
        let front = try #require(frontTab(rig.state.pluginFront(id)))
        #expect(front.tab.id == rig.b.id.uuidString.lowercased())
        #expect(front.tab.kind == "web" && front.tab.title == "Bee" && front.tab.url == "https://b.example/x")
        #expect(front.space.slug == rig.state.selectedSpace?.slug)

        // Another tab, another answer.
        rig.state.selectTab(rig.a.id)
        #expect(frontTab(rig.state.pluginFront(id))?.tab.id == rig.a.id.uuidString.lowercased())

        // The site switched off for the plugin: hidden, and back on again.
        rig.state.updateSiteSettings(spaceID: rig.spaceID, site: "https://a.example") { $0.disabledPlugins.insert(id) }
        #expect(rig.state.pluginFront(id) == .hidden(.siteOff))
        rig.state.updateSiteSettings(spaceID: rig.spaceID, site: "https://a.example") { $0.disabledPlugins.remove(id) }
        #expect(frontTab(rig.state.pluginFront(id)) != nil)

        // The Space switched off.
        rig.manager.setEnabled(id, space: rig.spaceID, false)
        #expect(rig.state.pluginFront(id) == .hidden(.spaceOff))
    }

    @Test(.timeLimit(.minutes(1))) func aPluginTabAloneHasNothingAndInASplitReachesTheOtherPane() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = FrontWorkspace.id
        rig.state.openPluginPageAsTab(id)
        let pluginTab = try #require(rig.state.selectedTab)
        #expect(pluginTab.pluginID == id)
        #expect(rig.state.pluginFront(id) == .hidden(.nothing))

        // In a split with a and b (b joined first): the plugin tab reaches the pane focused last.
        rig.state.splitTab(rig.a.id, beside: pluginTab.id, edge: .right)
        rig.state.splitTab(rig.b.id, beside: pluginTab.id, edge: .right)
        rig.state.selectTab(rig.a.id)
        rig.state.selectTab(pluginTab.id)
        #expect(frontTab(rig.state.pluginFront(id))?.tab.id == rig.a.id.uuidString.lowercased())
        rig.state.selectTab(rig.b.id)
        rig.state.selectTab(pluginTab.id)
        #expect(frontTab(rig.state.pluginFront(id))?.tab.id == rig.b.id.uuidString.lowercased())
    }

    @Test(.timeLimit(.minutes(1))) func theBackgroundAsksAndIsToldAtMostOncePerHalfSecond() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = FrontWorkspace.id
        func send(_ text: String) async -> JSONValue? { await rig.manager.sendFromPanel(pluginID: id, payload: .string(text)) }
        func field(_ value: JSONValue?, _ name: String) -> JSONValue? {
            if case .object(let fields)? = value { return fields[name] }
            return nil
        }
        func changes() async -> [JSONValue] {
            if case .array(let list)? = field(await send("changes"), "changes") { return list }
            return []
        }
        func tabID(_ value: JSONValue) -> String? {
            guard case .object(let front) = value, case .object(let tab)? = front["tab"], case .string(let id)? = tab["id"] else { return nil }
            return id
        }

        // The answer to a question is the front tab.
        let answer = field(await send("front"), "front")
        #expect(answer.flatMap(tabID) == rig.b.id.uuidString.lowercased())

        // Switching the Space on told it at once (b); the same tab selected again adds nothing.
        try await Task.sleep(for: .milliseconds(700))
        rig.state.selectTab(rig.b.id)
        try await Task.sleep(for: .milliseconds(700))
        let first = await changes()
        #expect(first.count == 1 && first.first.flatMap(tabID) == rig.b.id.uuidString.lowercased(), "got \(first)")

        // a, b, a in a row: a goes at once; the end of the half second finds a again, which the
        // plugin already has. Two entries in all, not four.
        rig.state.selectTab(rig.a.id)
        rig.state.selectTab(rig.b.id)
        rig.state.selectTab(rig.a.id)
        try await Task.sleep(for: .milliseconds(1200))
        let sent = await changes()
        #expect(sent.count == 2, "got \(sent)")
        #expect(sent.last.flatMap(tabID) == rig.a.id.uuidString.lowercased())

        // A new title is a change; the switch going off sends null.
        rig.state.webTabDidChange(tabID: rig.a.id, spaceID: rig.spaceID, title: "Ay", url: nil)
        try await Task.sleep(for: .milliseconds(700))
        rig.manager.setEnabled(id, space: rig.spaceID, false)
        try await Task.sleep(for: .milliseconds(700))
        let later = await changes()
        #expect(later.count == 4, "got \(later)")
        #expect(later.last == .null)
    }

    /// What the plugin has been told so far, as tab ids (nil for a null).
    private func told(_ rig: Rig) async -> [String?] {
        let reply = await rig.manager.sendFromPanel(pluginID: FrontWorkspace.id, payload: .string("changes"))
        guard case .object(let fields)? = reply, case .array(let list)? = fields["changes"] else { return [] }
        return list.map { value in
            guard case .object(let front) = value, case .object(let tab)? = front["tab"], case .string(let id)? = tab["id"] else { return nil }
            return id
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }

    @Test(.timeLimit(.minutes(1))) func closingOrOpeningATabTellsThePlugin() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = FrontWorkspace.id
        try await settle()
        #expect(await told(rig) == [rig.b.id.uuidString.lowercased()])

        // Closing the tab in front: the neighbour is in front, and the plugin is told.
        rig.state.closeTab(rig.b.id, in: rig.spaceID, confirmIfBusy: false)
        #expect(frontTab(rig.state.pluginFront(id))?.tab.id == rig.a.id.uuidString.lowercased())
        try await settle()
        #expect(await told(rig).last == rig.a.id.uuidString.lowercased())

        // A new tab (no selectTab call on that path).
        rig.state.openInNewTab(URL(string: "https://c.example/")!)
        let c = try #require(rig.state.selectedTab)
        try await settle()
        #expect(await told(rig).last == c.id.uuidString.lowercased())
    }

    @Test(.timeLimit(.minutes(1))) func theWelcomeFlowHidesTheFrontTab() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = FrontWorkspace.id
        try await settle()
        rig.state.showWelcome()
        #expect(rig.state.pluginFront(id) == .hidden(.nothing))
        try await settle()
        #expect(await told(rig).last == .some(nil)) // null
        rig.state.closeWelcome()
        try await settle()
        #expect(await told(rig).last == rig.b.id.uuidString.lowercased())
    }

    @Test(.timeLimit(.minutes(1))) func aSplitMadeBySplitTabReachesTheLastFocusedPaneAndNeverThePluginsOwnTab() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let id = FrontWorkspace.id
        rig.state.openPluginPageAsTab(id)
        let pluginTab = try #require(rig.state.selectedTab)
        try await settle()
        // b joins a (b is focused last), then the plugin tab joins; it is selected and no selectTab follows.
        rig.state.splitTab(rig.b.id, beside: rig.a.id, edge: .right)
        rig.state.splitTab(pluginTab.id, beside: rig.a.id, edge: .left)
        #expect(rig.state.selectedTab?.id == pluginTab.id)
        #expect(frontTab(rig.state.pluginFront(id))?.tab.id == rig.b.id.uuidString.lowercased())
        try await settle()
        let sent = await told(rig)
        #expect(sent.last == rig.b.id.uuidString.lowercased())
        #expect(!sent.contains(pluginTab.id.uuidString.lowercased()), "got \(sent)")
    }

    @Test(.timeLimit(.minutes(1))) func aPluginWithoutTheFrontTabPermissionIsRefused() async throws {
        let rig = try await makeRig(frontTab: false)
        defer { tearDown(rig) }
        let reply = await rig.manager.sendFromPanel(pluginID: FrontWorkspace.id, payload: .string("front"))
        #expect(reply == .object(["error": .string("needs the frontTab permission")]))
        // Nothing reaches it when the tab in front changes.
        rig.state.selectTab(rig.a.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await rig.manager.sendFromPanel(pluginID: FrontWorkspace.id, payload: .string("changes"))
                == .object(["changes": .array([])]))
    }

    @Test(.timeLimit(.minutes(1))) func theBrowserServerIsTheLauncherBesideTheApp() async throws {
        let rig = try await makeRig(browser: true)
        defer { tearDown(rig) }
        let bin = rig.appRoot.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appending(path: "singularity-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let app = bin.appending(path: "Singularity")

        // A copy on its own data folder names its socket; the daily copy doesn't.
        #expect(rig.state.browserServerDescription(executable: app, environment: ["SINGULARITY_HOME": rig.appRoot.path])
                == .object(["command": .string(launcher.path), "args": .array([]),
                            "env": .object(["SINGULARITY_MCP_SOCKET": .string(rig.state.paths.mcpSocket.path)])]))
        #expect(rig.state.browserServerDescription(executable: app, environment: [:])
                == .object(["command": .string(launcher.path), "args": .array([]), "env": .object([:])]))
        // No launcher beside the executable (a bare binary): null.
        #expect(rig.state.browserServerDescription(executable: rig.appRoot.appending(path: "Singularity"), environment: [:]) == .null)

        // Through the wire: the plugin sees the same thing.
        rig.manager.browserServerProvider = { rig.state.browserServerDescription(executable: app, environment: [:]) }
        let reply = await rig.manager.sendFromPanel(pluginID: FrontWorkspace.id, payload: .string("browser"))
        #expect(reply == .object(["browser": .object(["command": .string(launcher.path), "args": .array([]), "env": .object([:])])]))
    }

    @Test(.timeLimit(.minutes(1))) func noBrowserPermissionGetsNull() async throws {
        let rig = try await makeRig(browser: false)
        defer { tearDown(rig) }
        rig.manager.browserServerProvider = { .object(["command": .string("x")]) }
        #expect(await rig.manager.sendFromPanel(pluginID: FrontWorkspace.id, payload: .string("browser"))
                == .object(["browser": .null]))
    }
}
}
