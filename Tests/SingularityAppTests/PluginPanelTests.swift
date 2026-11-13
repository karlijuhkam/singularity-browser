import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

// Bun, the plugin host and the fixture program in the repository, found from this file's location.
// The fixture program uses system tools only; no test here runs anything from the user's PATH.
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let echoProgram = repoRoot.appending(path: "Tests/SingularityCoreTests/Fixtures/echo-program.sh")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

/// The login PATH the tests hand the manager (the real one would run the user's login shell).
private let fixturePATH = "/private/tmp/sg-fixture-bin:/usr/bin:/bin"

extension AppTests {
/// `PluginManager` running a plugin with its own panel: it runs with no Space switched on, its page
/// talks to its background (and back), its program gets the app's environment, and its page exists
/// only while the background runs.
@MainActor
@Suite(.serialized, .enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct PluginPanelTests {
    @Test(.timeLimit(.minutes(1))) func aPanelPluginRunsWithoutASpaceAndItsPageTalksToIt() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        try ws.approve()
        let manager = makeManager(ws)
        defer { manager.terminateAll() }
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(PanelWorkspace.id)?.runState == .running }
        #expect(manager.plugin(PanelWorkspace.id)?.approval?.enabledSpaces.isEmpty == true)

        // A panel message goes through without any Space.
        let reply = await manager.sendFromPanel(pluginID: PanelWorkspace.id, payload: .string("hi"))
        #expect(field(reply, "tabID") == .string("panel"))
        #expect(field(reply, "echo") == .string("hi"))
        // A page script's message still needs the plugin on in its Space.
        #expect(await manager.send(pluginID: PanelWorkspace.id, tabID: UUID(), space: UUID(), frameHost: "example.com",
                                   payload: .string("hi")) == nil)

        #expect(manager.panelPlugins().map(\.id) == [PanelWorkspace.id])
        #expect(manager.panelTitle(PanelWorkspace.id) == "Fixture Panel")

        // The page: one host, kept; its send reaches the background, and posts reach the page.
        let host = try #require(manager.pageHost(for: PanelWorkspace.id))
        #expect(manager.pageHost(for: PanelWorkspace.id) === host)
        let window = show(host)
        defer { window.close() }
        try await waitUntilPage(host, "the page's message to be answered", "window.__reply && window.__reply.echo && window.__reply.echo.hello", equals: "page")
        #expect(try await host.webView.evaluateJavaScript("window.__reply.tabID") as? String == "panel")
        #expect(await manager.sendFromPanel(pluginID: PanelWorkspace.id, payload: .object(["post": .string("x")]))
                == .object(["posted": .bool(true)]))
        try await waitUntilPage(host, "the post to reach the page", "document.title", equals: #"post:{"pushed":"x"}"#)

        // Quitting tears the page down with the background.
        manager.terminateAll()
        #expect(isTornDown(host))
        #expect(host.webView.superview == nil)
        #expect(manager.pageHost(for: PanelWorkspace.id) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aPausedPluginHasNoPageAndSaysWhy() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        #expect(makeManager(ws).notRunningReason("nothing-here") == "This plugin isn't installed.")
        try ws.approve()
        let manager = makeManager(ws)
        defer { manager.terminateAll() }
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(PanelWorkspace.id)?.runState == .running }
        let host = try #require(manager.pageHost(for: PanelWorkspace.id))

        // An edit pauses it (not in development mode): no page, and the status text says why.
        try Data("// edited\n".utf8).write(to: ws.plugin.appending(path: "panel.js"), options: .atomic)
        manager.start()   // looks at every folder again now, rather than waiting for the file watcher
        try await waitUntil("the plugin to pause", limit: .seconds(10)) { manager.plugin(PanelWorkspace.id)?.status == .changed }
        #expect(manager.plugin(PanelWorkspace.id)?.runState == .stopped)
        #expect(manager.pageHost(for: PanelWorkspace.id) == nil)
        #expect(manager.notRunningReason(PanelWorkspace.id) == "Changed since you approved it")
        // The old page was torn down, so it can't serve the unapproved file.
        #expect(isTornDown(host))
    }

    @Test(.timeLimit(.minutes(1))) func aCrashRestartReloadsThePage() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        try ws.approve()
        let manager = makeManager(ws)
        defer { manager.terminateAll() }
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(PanelWorkspace.id)?.runState == .running }
        let host = try #require(manager.pageHost(for: PanelWorkspace.id))
        let window = show(host)
        defer { window.close() }
        try await waitUntilPage(host, "the page to load", "window.__reply && window.__reply.echo && window.__reply.echo.hello", equals: "page")
        let firstLoad = try await host.webView.evaluateJavaScript("window.__loadID") as? String

        #expect(await manager.sendFromPanel(pluginID: PanelWorkspace.id, payload: .string("crash"))
                == .object(["crashing": .bool(true)]))
        // The supervisor starts a new background after a second; the same page is loaded again.
        try await waitUntilPage(host, "the page to load again", "window.__loadID !== \(jsString(firstLoad ?? ""))", equals: true)
        try await waitUntilPage(host, "the reloaded page's message to be answered", "window.__reply && window.__reply.echo && window.__reply.echo.hello", equals: "page")
        #expect(manager.pageHost(for: PanelWorkspace.id) === host)
        #expect(!isTornDown(host))
    }

    @Test(.timeLimit(.minutes(1))) func programsGetTheAppsEnvironment() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        try ws.approve()
        // No SINGULARITY_HOME: programs are allowed, as in the owner's daily copy.
        let manager = makeManager(ws, environment: [:])
        defer { manager.terminateAll() }
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(PanelWorkspace.id)?.runState == .running }

        let reply = await manager.sendFromPanel(pluginID: PanelWorkspace.id, payload: .string("env"))
        #expect(field(reply, "error") == .null)
        #expect(field(reply, "code") == .number(0))
        guard case .string(let text)? = field(reply, "text") else {
            Issue.record("no output: \(String(describing: reply))")
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        // Its working directory is the plugin's data folder.
        #expect(lines.first == ws.paths.pluginsDataDirectory(PanelWorkspace.id).path)
        let env = Set(lines.dropFirst())
        #expect(env.contains("PATH=\(fixturePATH)"))
        #expect(env.contains("HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)"))
        #expect(env.contains("USER=\(NSUserName())"))
        #expect(env.contains("LANG=en_US.UTF-8"))
        #expect(env.contains("FIXTURE_SETTING=yes"))
        #expect(!env.contains { $0.hasPrefix("NOT_LISTED=") })
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        #expect(env.contains("CLAUDE_AGENT_SDK_CLIENT_APP=singularity/\(version)"))
        // Nothing else from the test process's own environment (SHLVL and PWD are set by the
        // fixture's own /bin/sh).
        #expect(Set(env.map { String($0.prefix { $0 != "=" }) }).subtracting(["SHLVL", "PWD"])
                == ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "CLAUDE_AGENT_SDK_CLIENT_APP", "FIXTURE_SETTING"])
    }

    @Test(.timeLimit(.minutes(1))) func aTestCopyStartsNoPrograms() async throws {
        let ws = try PanelWorkspace()
        defer { ws.remove() }
        try ws.approve()
        let manager = makeManager(ws, environment: ["SINGULARITY_HOME": "/private/tmp/sg-elsewhere"])
        defer { manager.terminateAll() }
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(PanelWorkspace.id)?.runState == .running }

        let reply = await manager.sendFromPanel(pluginID: PanelWorkspace.id, payload: .string("env"))
        #expect(field(reply, "error") == .string("programs are off in a test copy"))
        #expect(field(reply, "text") == .string(""))
    }

    @Test func spaceSwitchesShowOnlyWhereTheyMeanSomething() throws {
        func manifest(_ extra: String) throws -> PluginManifest {
            try JSONDecoder().decode(PluginManifest.self, from: Data("""
                {"id": "m", "name": "M", "version": "1.0.0", "description": "", "author": "A",
                 "background": "background.ts", "permissions": {"pageAdditions": ["https://*/*"]} \(extra)}
                """.utf8))
        }
        let panel = #", "panel": {"page": "panel.html", "title": "M"}"#
        let page = #", "page": {"script": "page.ts", "sites": ["https://*/*"]}"#
        // A panel and no page script: no switches (the sheet says the panel is in every Space).
        #expect(!PluginApprovalSheet.showsSpaceSwitches(try manifest(panel)))
        // A page script: its switches, with or without a panel.
        #expect(PluginApprovalSheet.showsSpaceSwitches(try manifest(panel + page)))
        #expect(PluginApprovalSheet.showsSpaceSwitches(try manifest(page)))
        // Background only: the switches are what starts it.
        #expect(PluginApprovalSheet.showsSpaceSwitches(try manifest("")))
    }

    // MARK: - Helpers

    /// A manager on the workspace, with the test's Bun and plugin host. Programs follow
    /// `ProgramLaunchSettings.live` for `environment` (the app's would be the process's own), with
    /// a fixed login PATH instead of asking the user's login shell.
    private func makeManager(_ ws: PanelWorkspace, environment: [String: String] = [:]) -> PluginManager {
        PluginManager(paths: ws.paths, runtime: bunPath, host: hostScript,
                      programs: .live(environment: environment, loginPath: { fixturePATH }))
    }

    /// Puts the page's web view in an off-screen window that never becomes key (a key window of the
    /// test process can take the owner's keyboard).
    private func show(_ host: PluginPageHost) -> NSWindow {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.webView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView!.addSubview(host.webView)
        window.orderFront(nil)
        return window
    }

    private func waitUntilPage<T: Equatable>(_ host: PluginPageHost, _ what: String, _ script: String,
                                             equals expected: T) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let value = try? await host.webView.evaluateJavaScript(script) as? T, value == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
    }

    /// `PluginPageHost.tearDown` removed the page API and the web view's other user scripts.
    private func isTornDown(_ host: PluginPageHost) -> Bool {
        host.webView.configuration.userContentController.userScripts.isEmpty
    }

    private func jsString(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private func field(_ value: JSONValue?, _ name: String) -> JSONValue? {
        if case .object(let fields)? = value { return fields[name] }
        return nil
    }
}
}

/// A data folder (`/private/tmp/sg-pn-…`, a real path as the sandbox sees it) with one plugin,
/// "panelfix": a panel page, a background that answers panel messages, posts to its page and
/// starts the fixture program, and the fixture program itself outside the plugins folder.
private struct PanelWorkspace {
    static let id = "panelfix"
    let root: URL
    let program: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }

    init() throws {
        let fm = FileManager.default
        root = URL(filePath: "/private/tmp/sg-pn-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        program = root.appending(path: "fixture-program")
        let plugin = Paths(root: root).pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: plugin.appending(path: path))
        }
        try write("plugin.json", """
            {"id": "panelfix", "name": "Panel Fixture", "version": "1.0.0", "description": "A test panel plugin.",
             "author": "Tests", "background": "background.ts",
             "panel": {"page": "panel.html", "title": "Fixture Panel"},
             "permissions": {"programs": ["fixture"], "programEnv": ["FIXTURE_SETTING"]}}
            """)
        try write("background.ts", """
            import { singularity } from "singularity";

            async function runFixture(args: string[]) {
              const program = singularity.spawn("fixture", args, { env: { FIXTURE_SETTING: "yes", NOT_LISTED: "no" } });
              let error: string | null = null;
              program.on("error", (e: Error) => { error = e.message; });
              const exited = new Promise<number | null>((resolve) => program.on("exit", (code: number | null) => resolve(code)));
              program.stdin.end();
              const chunks: Buffer[] = [];
              const reading = (async () => { for await (const chunk of program.stdout) chunks.push(chunk); })();
              const code = await exited;
              await reading;
              return { error, code, text: Buffer.concat(chunks).toString() };
            }

            singularity.onPageMessage(async ({ tabID, payload }) => {
              const p = payload as any;
              if (p && typeof p === "object" && "post" in p) {
                singularity.panel.post({ pushed: p.post });
                return { posted: true };
              }
              if (p === "env") return await runFixture(["env"]);
              if (p === "crash") {
                setTimeout(() => process.exit(1), 50);
                return { crashing: true };
              }
              return { tabID, echo: payload };
            });
            """)
        try write("panel.html", """
            <!doctype html>
            <html><head><title>loading</title><script type="module" src="./panel.js"></script></head><body></body></html>
            """)
        try write("panel.js", """
            window.__loadID = Math.random().toString(36).slice(2);
            window.singularity.onMessage((message) => { document.title = "post:" + JSON.stringify(message); });
            window.singularity.send({ hello: "page" }).then(
              (reply) => { window.__reply = reply; },
              (error) => { window.__reply = { error: String(error) }; });
            """)
        try fm.copyItem(at: echoProgram, to: program)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }

    private struct NotReady: Error, CustomStringConvertible { let description: String }

    /// Approves the plugin as it is now, on in no Space, with the fixture program pinned: what
    /// `PluginManager.approve` would save, written before the manager starts.
    func approve() throws {
        let scan = PluginScan.scan(folder: plugin)
        guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
            throw NotReady(description: "the fixture plugin doesn't scan: \(scan.manifest)")
        }
        let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                      commandPaths: ["fixture": program.path], enabledSpaces: [],
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
