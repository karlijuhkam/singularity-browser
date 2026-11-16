import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// A plugin's `openTerminals` and `notifications` in the app: what `PluginManager` answers, the
/// tab it makes and the line it leaves to be typed, the banner it posts. No shell starts
/// (terminal tabs are fakes) and no banner reaches macOS (a fake backend).
@MainActor
@Suite(.serialized) struct PluginActionsStateTests {
    @MainActor final class Fixture {
        static let id = "acts"
        let root: URL
        let state: AppState
        let manager: PluginManager
        let space: Space
        let program: URL
        var clock = Date(timeIntervalSince1970: 10_000)
        var notices: [(title: String, body: String)] = []

        init(permissions: String = #""openTerminals": ["prog"], "notifications": true"#, approve: Bool = true) async throws {
            MainRunLoopGuard.start
            root = TestAppState.makeRoot()
            let paths = Paths(root: root)
            let folder = paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("""
                {"id": "\(Self.id)", "name": "Acts", "version": "1.0.0", "description": "A test plugin.",
                 "author": "Tests", "background": "background.ts", "permissions": {\(permissions)}}
                """.utf8).write(to: folder.appending(path: "plugin.json"))
            try Data("export {};\n".utf8).write(to: folder.appending(path: "background.ts"))
            // The pinned program: a real executable file with a harmless name. Nothing runs it.
            program = root.appending(path: "bin/prog")
            try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)

            let web = BrowserTab.web(URL(string: "about:blank")!, title: "page")
            space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~/Developer",
                          tabs: [web], selectedTabID: web.id)
            let store = SpaceStore(paths: paths)
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
            if approve {
                let scan = PluginScan.scan(folder: folder)
                let manifest = try #require(scan.validManifest), snapshot = try #require(scan.snapshot)
                let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                              commandPaths: ["prog": program.path], enabledSpaces: [], terminalSpaces: [],
                                              developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
                try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
            }
            // A runtime that doesn't exist: the background never starts. The answers are asked of
            // the manager directly, as its supervisor would.
            manager = PluginManager(paths: paths, runtime: root.appending(path: "no-bun"), host: root.appending(path: "no-host.ts"))
            state = TestAppState.make(root: root, plugins: manager)
            state.closeWelcome()
            state.terminalHandleOverride = { _ in nil }   // terminal tabs start no shell
            manager.now = { [unowned self] in self.clock }
            manager.noticePoster = { [unowned self] title, body in self.notices.append((title, body)) }
            manager.start()
            try await waitUntil("the plugin to be scanned") { self.manager.plugin(Self.id) != nil && self.manager.firstScanDone }
        }

        func tearDown() {
            manager.terminateAll()
            TestAppState.shutDown(state)
            try? FileManager.default.removeItem(at: root)
        }

        func ask(_ name: String, _ payload: [String: JSONValue]) -> JSONValue {
            manager.answerAppRequest(pluginID: Self.id, name: name, payload: .object(payload))
        }
        func open(_ args: [String], program: String = "prog") -> JSONValue {
            ask("openTerminal", ["program": .string(program), "args": .array(args.map(JSONValue.string))])
        }
        var terminalTabs: [BrowserTab] { state.space(space.id)?.tabs.filter(\.isTerminal) ?? [] }
    }

    static let ok = JSONValue.object(["ok": .bool(true)])
    static func refused(_ why: String) -> JSONValue { .object(["ok": .bool(false), "error": .string(why)]) }

    @Test func aTerminalOpensWithTheLineLeftToBeTyped() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(f.open(["gwb", "--fresh"]) == Self.ok)
        let tab = try #require(f.terminalTabs.first)
        #expect(f.terminalTabs.count == 1)
        #expect(f.state.selectedTab?.id == tab.id)
        #expect(tab.workingDirectory == "~/Developer")
        // Typed once, by the tab's first shell, like a launcher's command; never saved.
        #expect(f.state.pendingCommands[tab.id] == "\(f.program.path) gwb --fresh")
        #expect(f.state.takePendingCommand(tab.id) == "\(f.program.path) gwb --fresh")
        #expect(f.state.takePendingCommand(tab.id) == nil)
        f.state.flushSaves()
        let saved = try String(contentsOf: Paths(root: f.root).spaceFile("work"), encoding: .utf8)
        #expect(!saved.contains("--fresh"))
    }

    @Test func onlyTheDeclaredProgramAndPlainWords() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(f.open(["x"], program: "other") == Self.refused("not allowed by the manifest"))
        #expect(f.open(["a; rm -rf ~"]) == Self.refused("arguments must be plain words (letters, digits and - . _ / : = @ + ,)"))
        #expect(f.open(["$(x)"]) != Self.ok)
        #expect(f.ask("openTerminal", ["program": .string("prog"), "args": .array([.number(1)])]) == Self.refused("arguments must be plain words"))
        #expect(f.ask("format", [:]) == Self.refused("unknown request"))
        #expect(f.manager.answerAppRequest(pluginID: "nobody", name: "openTerminal", payload: .object([:])) == Self.refused("not allowed"))
        #expect(f.terminalTabs.isEmpty)
        #expect(f.state.pendingCommands.isEmpty)
    }

    @Test func aProgramThatWentMissingOpensNothing() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try FileManager.default.removeItem(at: f.program)
        #expect(f.open(["gwb"]) == Self.refused("the program is missing or changed"))
        #expect(f.terminalTabs.isEmpty)
    }

    @Test func terminalsAreLimited() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(f.open(["a"]) == Self.ok)
        #expect(f.open(["b"]) == Self.refused("too many terminals at once"))    // under 2 s apart
        for _ in 0..<4 {
            f.clock += 3
            #expect(f.open(["c"]) == Self.ok)
        }
        f.clock += 3
        #expect(f.open(["d"]) == Self.refused("too many terminals at once"))    // five in a minute
        f.clock += 60
        #expect(f.open(["e"]) == Self.ok)
        #expect(f.terminalTabs.count == 6)
    }

    @Test func nothingOpensUnderTheWelcomeFlow() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        f.state.showWelcome()
        #expect(f.open(["gwb"]) == Self.refused("no Space to open a terminal in"))
        #expect(f.terminalTabs.isEmpty)
    }

    @Test func aNoticeIsCleanedHeadedAndLimited() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        #expect(f.ask("notify", ["title": .string("Pilot"), "body": .string("PLAT-9 waits\nfor you")]) == Self.ok)
        #expect(f.notices.count == 1)
        #expect(f.notices[0].title == "Acts: Pilot" && f.notices[0].body == "PLAT-9 waits for you")
        #expect(f.ask("notify", ["title": .string("again")]) == Self.refused("too many notifications"))   // under 5 s apart
        f.clock += 6
        #expect(f.ask("notify", ["title": .string(" "), "body": .string("")]) == Self.refused("nothing to show"))
        #expect(f.ask("notify", ["body": .string("only a body")]) == Self.ok)
        #expect(f.notices.last?.title == "Acts")
        #expect(f.notices.count == 2)
    }

    @Test func withoutThePermissionsNothingHappens() async throws {
        let f = try await Fixture(permissions: #""commands": {"prog": ["x"]}"#)
        defer { f.tearDown() }
        #expect(f.open(["gwb"]) == Self.refused("not allowed by the manifest"))
        #expect(f.ask("notify", ["title": .string("x")]) == Self.refused("not allowed by the manifest"))
        #expect(f.terminalTabs.isEmpty && f.notices.isEmpty)
    }

    @Test func aPluginThatIsNotApprovedGetsNothing() async throws {
        let f = try await Fixture(approve: false)
        defer { f.tearDown() }
        #expect(f.open(["gwb"]) == Self.refused("not allowed"))
        #expect(f.ask("notify", ["title": .string("x")]) == Self.refused("not allowed"))
        #expect(f.terminalTabs.isEmpty && f.notices.isEmpty)
    }

    @Test func aPluginsBannerIsPostedAndNotWithdrawnWithTheInbox() async throws {
        MainRunLoopGuard.start
        let backend = InboxNotifierTests.FakeBackend()
        let notifier = InboxNotifier(onOpen: {}, backend: backend)
        notifier.post(title: "Bots: Pilot", body: "PLAT-9 waits for you")
        await notifier.settle()
        #expect(backend.posted.count == 1)
        #expect(backend.posted[0].title == "Bots: Pilot" && backend.posted[0].body == "PLAT-9 waits for you")
        #expect(backend.posted[0].id.hasPrefix("plugin-"))
        notifier.sync(with: [])
        await notifier.settle()
        #expect(backend.removed.isEmpty)
        // Denied in System Settings: nothing is posted, and nothing is asked again.
        backend.status = .denied
        notifier.post(title: "Bots", body: "x")
        await notifier.settle()
        #expect(backend.posted.count == 1 && backend.authorisationRequests == 1)
    }
}
}
