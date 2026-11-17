import Foundation
import Testing
@testable import Singularity
import SingularityCore

/// A data folder with one plugin, "askfix": a panel and a background that records every ask it
/// gets (`singularity.onAsk`) and hands the list back to a panel message "asks". `ask` switches
/// the permission. Never `claude`, no program at all.
private struct AskWorkspace {
    static let id = "askfix"
    let root: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }

    init(ask: Bool) throws {
        root = URL(filePath: "/private/tmp/sg-ak-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let plugin = Paths(root: root).pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: plugin.appending(path: path)) }
        try write("plugin.json", """
            {"id": "askfix", "name": "Ask Fixture", "version": "1.0.0", "description": "A test plugin.",
             "author": "Tests", "background": "background.ts",
             "panel": {"page": "panel.html", "title": "Fixture Helper"},
             "permissions": {\(ask ? #""ask": true"# : "")}}
            """)
        try write("panel.html", "<!doctype html><html><head><title>x</title></head><body></body></html>")
        try write("background.ts", """
            import { singularity } from "singularity";
            const asks: unknown[] = [];
            try { singularity.onAsk((ask) => { asks.push(ask); }); } catch {}
            singularity.onPageMessage(async ({ payload }) => {
              if (payload === "asks") return { asks };
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
                                      commandPaths: [:], enabledSpaces: [],
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

extension AppTests {
/// The home's "Ask <Title>" row hands the typed text to the plugin with `ask`, with a real
/// `AppState` and a real Bun background. No shell, no window, no `claude`.
@MainActor
@Suite(.serialized, .enabled(if: TestAppState.hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct HomeAskTests {
    private struct Rig {
        let ws: AskWorkspace
        let appRoot: URL
        let manager: PluginManager
        let state: AppState
        let spaceID: UUID
    }

    /// One Space, the fixture approved and running (on for the Space when `on`), the home selected.
    private func makeRig(ask: Bool = true, on: Bool = true) async throws -> Rig {
        MainRunLoopGuard.start
        let ws = try AskWorkspace(ask: ask)
        try ws.approve()
        let manager = PluginManager(paths: ws.paths, runtime: TestAppState.repositoryBun,
                                    host: TestAppState.repositoryHostFolder.appending(path: "host.ts"),
                                    programs: .live(environment: [:], loginPath: { "/usr/bin:/bin" }))
        let appRoot = TestAppState.makeRoot()
        let state = TestAppState.make(root: appRoot, plugins: manager)
        state.terminalHandleOverride = { _ in nil }
        state.inbox.appIsActive = { false }
        state.inbox.windowIsKey = { false }
        state.closeWelcome()
        let spaceID = try #require(state.selectedSpaceID)
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(AskWorkspace.id)?.runState == .running }
        if on { manager.setEnabled(AskWorkspace.id, space: spaceID, true) }
        state.openHome()
        return Rig(ws: ws, appRoot: appRoot, manager: manager, state: state, spaceID: spaceID)
    }

    private func tearDown(_ rig: Rig) {
        TestAppState.shutDown(rig.state)
        rig.manager.terminateAll()
        rig.ws.remove()
        try? FileManager.default.removeItem(at: rig.appRoot)
    }

    /// What the background has received so far, once it has `count` asks.
    private func asks(_ rig: Rig, count: Int) async throws -> [JSONValue] {
        var received: [JSONValue] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let reply = await rig.manager.sendFromPanel(pluginID: AskWorkspace.id, payload: .string("asks"))
            if case .object(let object)? = reply, case .array(let list)? = object["asks"] {
                received = list
                if list.count >= count { return list }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return received
    }

    private func json(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test(.timeLimit(.minutes(1))) func askReachesThePluginWithSpace() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let space = try #require(rig.state.space(rig.spaceID))
        #expect(rig.state.askTarget == AskWorkspace.id)
        #expect(rig.state.askAssistant("What changed today?"))
        let received = try await asks(rig, count: 1)
        #expect(received == [.object([
            "text": .string("What changed today?"),
            "space": .object(["slug": .string(space.slug), "name": .string(space.name)]),
        ])])
    }

    @Test(.timeLimit(.minutes(1))) func askFromSpaceOffHasNullSpace() async throws {
        let rig = try await makeRig(on: false)
        defer { tearDown(rig) }
        let space = try #require(rig.state.space(rig.spaceID))
        #expect(rig.state.askAssistant("hello"))
        let received = try await asks(rig, count: 1)
        #expect(received == [.object(["text": .string("hello"), "space": .null])])
        let text = try json(.array(received))
        #expect(!text.contains(space.slug) && !text.contains(space.name))
    }

    @Test(.timeLimit(.minutes(1))) func askOpensPanelAndKeepsHome() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let before = try #require(rig.state.space(rig.spaceID))
        let homeID = try #require(before.selectedTab?.id)
        #expect(before.selectedTab?.isHome == true)
        #expect(rig.state.shownPanelPlugin == nil)

        #expect(rig.state.askAssistant("hi"))
        #expect(rig.state.shownPanelPlugin == AskWorkspace.id)
        let after = try #require(rig.state.space(rig.spaceID))
        #expect(after.selectedTabID == homeID)
        #expect(after.tabs.map(\.id) == before.tabs.map(\.id))
        #expect(rig.state.selectedSpaceID == rig.spaceID)

        // Blank or too long: nothing is sent and the panel isn't touched.
        rig.state.closePluginPanel()
        #expect(!rig.state.askAssistant("   \n"))
        #expect(!rig.state.askAssistant(String(repeating: "a", count: AskRules.maxLength + 1)))
        #expect(rig.state.shownPanelPlugin == nil)
        #expect(try await asks(rig, count: 1).count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func askMovesTabPageToPanel() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        rig.state.openPluginPageAsTab(AskWorkspace.id)
        #expect(rig.state.selectedSpace?.tabs.contains { $0.pluginID == AskWorkspace.id } == true)
        rig.state.openHome()
        let homeID = try #require(rig.state.selectedSpace?.selectedTab?.id)
        #expect(rig.state.selectedSpace?.selectedTab?.isHome == true)

        #expect(rig.state.askAssistant("move it"))
        let space = try #require(rig.state.space(rig.spaceID))
        #expect(!space.tabs.contains { $0.pluginID == AskWorkspace.id })
        #expect(rig.state.shownPanelPlugin == AskWorkspace.id)
        #expect(space.selectedTabID == homeID)
        #expect(try await asks(rig, count: 1).count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func noAskRowWithoutAskPlugin() async throws {
        let rig = try await makeRig(ask: false)
        defer { tearDown(rig) }
        #expect(rig.state.askTarget == nil)
        #expect(HomeSearch.askOffer(for: "hello", state: rig.state) == nil)
        #expect(!rig.state.askAssistant("hello"))
        #expect(rig.state.shownPanelPlugin == nil)
    }

    @Test(.timeLimit(.minutes(1))) func askRowNamesThePanelAndRefusesTooLong() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        #expect(HomeSearch.askOffer(for: "", state: rig.state) == nil)
        #expect(HomeSearch.askOffer(for: "  ", state: rig.state) == nil)
        #expect(HomeSearch.askOffer(for: "hello", state: rig.state) == .ask(title: "Ask Fixture Helper"))
        #expect(HomeSearch.askOffer(for: String(repeating: "a", count: AskRules.maxLength + 1), state: rig.state) == .tooLong)
        #expect(HomeSearch.askTooLongText == "Too long to send (max 20 000 characters).")
    }
}
}
