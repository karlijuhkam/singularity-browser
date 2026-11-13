import Darwin
import Foundation
import MCP
import Testing
@testable import Singularity
import SingularityCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)
private let doorClient = repoRoot.appending(path: "Tests/SingularityAppTests/Fixtures/door-client.sh")

/// A data folder with the plugin "doorfix" (panel title "Door Helper", name "Door Fixture"),
/// allowed `browser` (unless `browser: false`) and the program `door` = `door-client.sh`, and with
/// `second: true` a second such plugin, "doortwo" ("Door Two"). A background starts the program
/// when asked and relays lines: what the test sends goes to the program's stdin, what the program
/// prints is kept until the test reads it. So the test speaks MCP through the real launcher,
/// started by the real `PluginProcess`, exactly where the Assistant's `claude` would.
private struct DoorWorkspace {
    static let id = "doorfix"
    static let title = "Door Helper"
    static let secondID = "doortwo"
    let root: URL
    let program: URL
    let ids: [String]
    var paths: Paths { Paths(root: root) }
    func plugin(_ id: String) -> URL { paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory) }

    init(browser: Bool = true, second: Bool = false) throws {
        let fm = FileManager.default
        root = URL(filePath: "/private/tmp/sg-dr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        program = root.appending(path: "door-client")
        ids = second ? [Self.id, Self.secondID] : [Self.id]
        let titles = [Self.id: Self.title, Self.secondID: "Door Two"]
        for id in ids {
            let plugin = Paths(root: root).pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
            try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
            func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: plugin.appending(path: path)) }
            let permissions = browser ? #""browser": true, "programs": ["door"]"# : #""programs": ["door"]"#
            try write("plugin.json", """
                {"id": "\(id)", "name": "Door Fixture", "version": "1.0.0", "description": "A test plugin.",
                 "author": "Tests", "background": "background.ts",
                 "panel": {"page": "panel.html", "title": "\(titles[id]!)"},
                 "permissions": {\(permissions)}}
                """)
            try write("panel.html", "<!doctype html><html><head><title>x</title></head><body></body></html>")
            try write("background.ts", Self.background)
        }
        try fm.copyItem(at: doorClient, to: program)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }

    private static let background = """
        import { singularity } from "singularity";
        let program: any = null;
        let buffer = "";
        let lines: string[] = [];
        let exit: unknown = null;
        let error: string | null = null;
        singularity.onPageMessage(async ({ payload }) => {
          const p = payload as any;
          if (p && Array.isArray(p.start)) {
            buffer = ""; lines = []; exit = null; error = null;
            const started = singularity.spawn("door", p.start, {});
            program = started;
            started.on("error", (e: Error) => { if (program === started) error = e.message; });
            started.on("exit", (code: number | null, signal: string | null) => { if (program === started) exit = { code, signal }; });
            started.stdout.on("data", (chunk: Buffer) => {
              if (program !== started) return;
              buffer += chunk.toString();
              let i: number;
              while ((i = buffer.indexOf("\\n")) >= 0) { lines.push(buffer.slice(0, i)); buffer = buffer.slice(i + 1); }
            });
            return { started: true };
          }
          if (p && typeof p.send === "string") {
            if (!program) return { sent: false };
            program.stdin.write(p.send + "\\n");
            return { sent: true };
          }
          if (p === "kill") { program?.kill("SIGKILL"); return { killed: true }; }
          if (p === "read") return { lines: lines.splice(0), error, exit };
          return null;
        });
        """

    private struct NotReady: Error, CustomStringConvertible { let description: String }

    /// Approved as they are now, on in no Space, with the door client pinned as `door`.
    func approve() throws {
        var approvals: [String: PluginApproval] = [:]
        for id in ids {
            let scan = PluginScan.scan(folder: plugin(id))
            guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
                throw NotReady(description: "the fixture plugin doesn't scan: \(scan.manifest)")
            }
            approvals[id] = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                           commandPaths: ["door": program.path], enabledSpaces: [],
                                           developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        }
        try PluginStateStore(file: paths.pluginStateFile).save(approvals)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// One MCP session: lines out, lines in. `send` and `take` are the transport; the rest is MCP.
@MainActor
private protocol MCPSession: AnyObject {
    func send(_ line: String) async throws
    /// The lines that arrived since the last call.
    func take() async throws -> [String]
    var received: [[String: Any]] { get set }
    var nextID: Int { get set }
}

private struct SessionError: Error, CustomStringConvertible { let description: String }

extension MCPSession {
    func send(_ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await send(String(decoding: data, as: UTF8.self))
    }

    /// Reads until a message matching `match` arrives (kept messages are searched first).
    func wait(_ what: String, limit: Duration = .seconds(20), for match: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + limit
        while true {
            if let index = received.firstIndex(where: match) { return received.remove(at: index) }
            guard ContinuousClock.now < deadline else { throw SessionError(description: "waited \(limit) for \(what); got \(received)") }
            for line in try await take() {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { received.append(object) }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let reply = try await wait("the answer to \(method)") { ($0["id"] as? Int) == id }
        guard let result = reply["result"] as? [String: Any] else { throw SessionError(description: "\(method) failed: \(reply)") }
        return result
    }

    func initialize(as name: String) async throws {
        _ = try await request("initialize", ["protocolVersion": "2025-03-26", "capabilities": [String: Any](),
                                             "clientInfo": ["name": name, "version": "1.0"]])
        try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func toolNames() async throws -> [String] {
        let result = try await request("tools/list", [:])
        return (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// The call's text and whether it was an error.
    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let result = try await request("tools/call", ["name": name, "arguments": arguments])
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false)
    }

    func waitForListChanged() async throws {
        _ = try await wait("tools/list_changed") { ($0["method"] as? String) == "notifications/tools/list_changed" }
    }
}

/// The plugin's program, reached through its background's relay.
@MainActor
private final class PluginSession: MCPSession {
    let manager: PluginManager
    var received: [[String: Any]] = []
    var nextID = 0
    init(manager: PluginManager) { self.manager = manager }

    func send(_ line: String) async throws {
        let reply = await manager.sendFromPanel(pluginID: DoorWorkspace.id, payload: .object(["send": .string(line)]))
        guard reply == .object(["sent": .bool(true)]) else { throw SessionError(description: "relay refused: \(String(describing: reply))") }
    }

    func take() async throws -> [String] {
        guard case .object(let fields)? = await manager.sendFromPanel(pluginID: DoorWorkspace.id, payload: .string("read")) else {
            throw SessionError(description: "the plugin didn't answer")
        }
        if case .string(let error)? = fields["error"] { throw SessionError(description: "the program failed: \(error)") }
        if let exit = fields["exit"], exit != .null { throw SessionError(description: "the program ended: \(exit)") }
        guard case .array(let lines)? = fields["lines"] else { return [] }
        return lines.compactMap { if case .string(let line) = $0 { return line } else { return nil } }
    }
}

/// A connection straight from the test process: not descended from any plugin's program.
@MainActor
private final class DirectSession: MCPSession {
    private let fd: Int32
    private let inbox = LockedLines()
    var received: [[String: Any]] = []
    var nextID = 0

    final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func takeAll() -> [String] { lock.withLock { defer { lines = [] }; return lines } }
    }

    init(socket path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { Darwin.close(fd); throw SessionError(description: "could not connect to \(path)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let fd = fd, inbox = inbox
        Thread.detachNewThread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { return }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    inbox.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
        }
    }

    func close() { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }

    func send(_ line: String) async throws {
        let bytes = Array((line + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { throw SessionError(description: "short write") }
    }

    func take() async throws -> [String] { inbox.takeAll() }
}

extension AppTests {
/// The agent door recognises a connection from a plugin's own program (through the real
/// `singularity-mcp`) and gives it the Spaces switched on for that plugin; anyone else is an
/// outside agent, as before.
@MainActor
@Suite(.serialized, .enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct PluginDoorTests {
    @MainActor private struct Rig {
        let ws: DoorWorkspace
        let appRoot: URL
        let manager: PluginManager
        let state: AppState
        let space: Space
        let a: BrowserTab
        let b: BrowserTab
        let launcher: URL
        func tool(_ name: String) -> String { AgentToolName.make(slug: space.slug, tool: name) }

        /// Starts the plugin's program in `mode` and waits until it runs.
        func startProgram(_ mode: String, extra: [String] = [], plugin: String = DoorWorkspace.id) async throws -> pid_t {
            let socket = state.paths.mcpSocket.path
            #expect(FileManager.default.fileExists(atPath: socket))
            let started = await manager.sendFromPanel(pluginID: plugin, payload: .object([
                "start": .array(([mode, launcher.path, socket] + extra).map { .string($0) }),
            ]))
            #expect(started == .object(["started": .bool(true)]))
            try await waitUntil("the program to run") { manager.programPID(of: plugin) != nil }
            return try #require(manager.programPID(of: plugin))
        }

        /// Ends the plugin's program (SIGKILL to it alone, as `program.kill`) and waits until it is gone.
        func killProgram() async throws {
            _ = await manager.sendFromPanel(pluginID: DoorWorkspace.id, payload: .string("kill"))
            try await waitUntil("the program to end") { manager.programPID(of: DoorWorkspace.id) == nil }
        }
    }

    /// The built `singularity-mcp`, next to this test bundle (`swift build` puts every product of
    /// the package in one folder). Never skipped: a missing launcher fails the test.
    private static func launcher() throws -> URL {
        var folders = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent() }
        folders.append(repoRoot.appending(path: ".build/debug"))
        for folder in folders {
            let url = folder.appending(path: "singularity-mcp")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        Issue.record("singularity-mcp is not built. Build it with `source scripts/env.sh && swift build --product singularity-mcp`, then run these tests again.")
        throw CancellationError()
    }

    /// One Space with agents OFF and two web tabs (a.example, b.example), the plugin(s) approved,
    /// running and doorfix switched on for the Space; its program started in `mode` ("exec",
    /// "child", or nil for none yet). `terminal`: the Space also has a terminal tab, first and not
    /// selected (so no shell starts), titled with a command, in a project.
    private func makeRig(mode: String? = "child", browser: Bool = true, second: Bool = false,
                         terminal: Bool = false) async throws -> Rig {
        let launcher = try Self.launcher()
        let ws = try DoorWorkspace(browser: browser, second: second)
        try ws.approve()
        // Programs allowed: a plain environment (no SINGULARITY_HOME), as the real app has it.
        let manager = PluginManager(paths: ws.paths, runtime: bunPath, host: hostScript,
                                    programs: .live(environment: [:], loginPath: { "/usr/bin:/bin" }))
        let appRoot = TestAppState.makeRoot()
        if terminal {
            let project = Project(name: "secret-project", path: "~/Developer/secret-project")
            var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~", projects: [project])
            var tab = BrowserTab.terminal(workingDirectory: "~/Developer/secret-project")
            tab.title = "claude --resume ~/Developer/secret-project"
            tab.projectID = project.id
            space.append(tab)
            let store = SpaceStore(paths: Paths(root: appRoot))
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
        }
        let state = TestAppState.make(root: appRoot, plugins: manager)
        state.closeWelcome()
        let spaceID = try #require(state.selectedSpaceID)
        #expect(state.space(spaceID)?.agentsEnabled == false)
        state.openInNewTab(URL(string: "https://a.example/page")!)
        state.openInNewTab(URL(string: "https://b.example/")!)
        let tabs = try #require(state.selectedSpace?.tabs.filter { !$0.isTerminal })
        manager.start()
        for id in ws.ids {
            try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(id)?.runState == .running }
        }
        manager.setEnabled(DoorWorkspace.id, space: spaceID, true)
        let rig = Rig(ws: ws, appRoot: appRoot, manager: manager, state: state, space: try #require(state.space(spaceID)),
                      a: tabs[0], b: tabs[1], launcher: launcher)
        if let mode { _ = try await rig.startProgram(mode) }
        return rig
    }

    /// The program first (it holds the launcher), then the state, then the folders.
    private func tearDown(_ rig: Rig) {
        rig.manager.terminateAll()
        TestAppState.shutDown(rig.state)
        rig.ws.remove()
        try? FileManager.default.removeItem(at: rig.appRoot)
    }

    /// The lines that arrive within `wait`: to show that nothing was sent.
    private func notifications(_ session: some MCPSession, within wait: Duration = .milliseconds(800)) async throws -> [[String: Any]] {
        try await Task.sleep(for: wait)
        for line in try await session.take() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { session.received.append(object) }
        }
        defer { session.received.removeAll() }
        return session.received.filter { ($0["method"] as? String) == "notifications/tools/list_changed" }
    }

    @Test(.timeLimit(.minutes(1))) func theProgramsConnectionGetsItsSpacesAndAStrangerGetsNone() async throws {
        let rig = try await makeRig(mode: "exec")
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        let names = try await plugin.toolNames()
        #expect(names.contains(rig.tool("list_tabs")), "got \(names)")
        #expect(names.contains(rig.tool("read_page")))
        let spaces = try await plugin.call(AgentToolName.listSpaces)
        #expect(!spaces.isError && spaces.text.contains("\"slug\" : \"\(rig.space.slug)\""), "got \(spaces.text)")

        // The test process connecting itself, calling itself "Assistant": an outside agent.
        let stranger = try DirectSession(socket: rig.state.paths.mcpSocket.path)
        defer { stranger.close() }
        try await stranger.initialize(as: "Assistant")
        #expect(try await stranger.toolNames() == [AgentToolName.listSpaces])
        let theirs = try await stranger.call(AgentToolName.listSpaces)
        #expect(theirs.text.hasPrefix("No Spaces are open to agents."), "got \(theirs.text)")
        let refused = try await stranger.call(rig.tool("list_tabs"))
        #expect(refused.isError && refused.text == "Agents are not allowed in the “\(rig.space.name)” Space.")
    }

    @Test(.timeLimit(.minutes(1))) func theLauncherAsAChildOfTheProgramIsRecognised() async throws {
        let rig = try await makeRig(mode: "child")
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        #expect(try await plugin.toolNames().contains(rig.tool("list_tabs")))

        // Its calls are logged with the plugin's title as the client.
        let tabs = try await plugin.call(rig.tool("list_tabs"))
        #expect(!tabs.isError && tabs.text.contains(rig.a.id.uuidString.lowercased()))
        let log = AgentLogStore(file: rig.state.paths.agentLogFile(rig.space.slug)).loadRecent()
        #expect(log.last?.client == DoorWorkspace.title, "got \(log)")
        #expect(log.last?.tool == rig.tool("list_tabs"))
    }

    @Test(.timeLimit(.minutes(1))) func theProgramOfAPluginWithoutBrowserIsAnOutsideAgent() async throws {
        let rig = try await makeRig(mode: "child", browser: false)
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        #expect(rig.state.mcp?.connectedCallers == [.outside])
        #expect(try await plugin.toolNames() == [AgentToolName.listSpaces])
        let spaces = try await plugin.call(AgentToolName.listSpaces)
        #expect(spaces.text.hasPrefix("No Spaces are open to agents."), "got \(spaces.text)")
    }

    @Test(.timeLimit(.minutes(1))) func switchingTheSpaceOffTellsTheConnectionAndHidesTheSpace() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        #expect(try await plugin.toolNames().contains(rig.tool("list_tabs")))
        let logged = AgentLogStore(file: rig.state.paths.agentLogFile(rig.space.slug)).loadRecent().count

        rig.manager.setEnabled(DoorWorkspace.id, space: rig.space.id, false)
        try await plugin.waitForListChanged()
        #expect(try await plugin.toolNames() == [AgentToolName.listSpaces])
        // A tool name remembered from before gets what a Space that doesn't exist gets, and isn't logged.
        let refused = try await plugin.call(rig.tool("list_tabs"))
        #expect(refused.isError && refused.text == "Unknown tool \(rig.tool("list_tabs")). Call list_spaces to see what is available.",
                "got \(refused)")
        let made = try await plugin.call("nosuchspace.list_tabs")
        #expect(made.text == "Unknown tool nosuchspace.list_tabs. Call list_spaces to see what is available.")
        #expect(AgentLogStore(file: rig.state.paths.agentLogFile(rig.space.slug)).loadRecent().count == logged)
        let none = try await plugin.call(AgentToolName.listSpaces)
        #expect(none.text == "No Spaces are open to Door Helper. The user can switch it on for a Space with the button under the chat, or in Settings → Plugins.")
    }

    @Test(.timeLimit(.minutes(1))) func onlyAChangeToItsOwnToolsIsSentToAPluginsConnection() async throws {
        let rig = try await makeRig(second: true)
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        let stranger = try DirectSession(socket: rig.state.paths.mcpSocket.path)
        defer { stranger.close() }
        try await stranger.initialize(as: "claude-code")

        // Another plugin's switch: nothing to either connection.
        rig.manager.setEnabled(DoorWorkspace.secondID, space: rig.space.id, true)
        #expect(try await notifications(plugin).isEmpty)
        #expect(try await notifications(stranger).isEmpty)
        // A Space closed to the plugin, created and renamed: nothing to the plugin's connection.
        let other = rig.state.createSpace(name: "Other", colorHex: "#000000", workingDirectory: "~")
        rig.state.updateSpace(other.id, name: "Renamed", colorHex: "#000000", workingDirectory: "~", agentsEnabled: false,
                              agentPolicy: .ask)
        #expect(try await notifications(plugin).isEmpty)
        // Its own switch going off: the plugin's connection is told; an outside agent isn't.
        rig.manager.setEnabled(DoorWorkspace.id, space: rig.space.id, false)
        #expect(try await notifications(plugin).count == 1)
        #expect(try await notifications(stranger).isEmpty)
        // Agents switched on: the outside agent is told, as always; the plugin's tools didn't change.
        rig.state.setAgentsEnabled(true, spaceID: rig.space.id)
        #expect(try await notifications(stranger).count == 1)
        #expect(try await notifications(plugin).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aConnectionFromAnEndedProgramGetsNothingAlsoAfterARestart() async throws {
        let rig = try await makeRig(mode: "child")
        defer { tearDown(rig) }
        let first = try #require(rig.manager.programPID(of: DoorWorkspace.id))
        let caller = AgentCaller.plugin(id: DoorWorkspace.id, title: DoorWorkspace.title)
        let toolbox = AgentToolbox(state: rig.state)
        #expect(toolbox.listTools(for: caller, program: first).map(\.name).contains(rig.tool("list_tabs")))

        try await rig.killProgram()
        let unknown = "Unknown tool \(rig.tool("list_tabs")). Call list_spaces to see what is available."
        #expect(toolbox.listTools(for: caller, program: first).map(\.name) == [AgentToolName.listSpaces])
        var result = await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: first)
        #expect(result.isError == true && text(result) == unknown, "got \(text(result))")

        // The plugin runs a new program: the old connection still gets nothing; the new one does.
        let second = try await rig.startProgram("child")
        #expect(second != first)
        result = await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: first)
        #expect(result.isError == true && text(result) == unknown)
        result = await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: second)
        #expect(result.isError != true)
    }

    @Test(.timeLimit(.minutes(1))) func aLauncherLeftBehindByItsProgramIsCutOff() async throws {
        let rig = try await makeRig(mode: nil)
        defer { tearDown(rig) }
        let folder = rig.ws.root.appending(path: "orphan", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await rig.startProgram("orphan", extra: [folder.path])
        let pidFile = folder.appending(path: "pid")
        try await waitUntil("the launcher's pid") { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil }
        let launcher = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let group = getpgid(launcher)
        defer { if group > 1 { kill(-group, SIGKILL) } }
        let plugin = AgentCaller.plugin(id: DoorWorkspace.id, title: DoorWorkspace.title)
        try await waitUntil("the launcher's connection") { rig.state.mcp?.connectedCallers.contains(plugin) == true }

        // The program ends; the launcher, in a group of its own, lives on. The app closes its
        // connection, and the launcher, seeing the end of it, exits.
        try await rig.killProgram()
        try await waitUntil("the connection to close") { rig.state.mcp?.connectedCallers.contains(plugin) == false }
        try await waitUntil("the launcher to exit") { kill(launcher, 0) != 0 }
    }

    @Test(.timeLimit(.minutes(1))) func aSiteSwitchedOffIsLeftOutAndRefused() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        rig.state.updateSiteSettings(spaceID: rig.space.id, site: "https://a.example") { $0.disabledPlugins.insert(DoorWorkspace.id) }
        let siteOff = "Door Helper is switched off for this site."

        let tabs = try await plugin.call(rig.tool("list_tabs"))
        #expect(!tabs.text.contains(rig.a.id.uuidString.lowercased()), "got \(tabs.text)")
        #expect(tabs.text.contains(rig.b.id.uuidString.lowercased()))

        let read = try await plugin.call(rig.tool("read_page"), ["tab_id": rig.a.id.uuidString.lowercased()])
        #expect(read.isError && read.text == siteOff, "got \(read)")
        let close = try await plugin.call(rig.tool("close"), ["tab_id": rig.a.id.uuidString.lowercased()])
        #expect(close.isError && close.text == siteOff, "got \(close)")

        // Going there is refused before anything is asked (the Space's policy is "ask").
        let navigate = try await plugin.call(rig.tool("navigate"), ["tab_id": rig.b.id.uuidString.lowercased(),
                                                                    "url": "https://a.example/other"])
        #expect(navigate.isError && navigate.text == siteOff, "got \(navigate)")
        let open = try await plugin.call(rig.tool("open"), ["url": "https://a.example/"])
        #expect(open.isError && open.text == siteOff, "got \(open)")
        #expect(rig.state.inbox.inbox.entries.isEmpty)
        #expect(rig.state.space(rig.space.id)?.tabs.count == 2)

        // An outside agent is not affected by the plugin's site switch.
        rig.state.setAgentsEnabled(true, spaceID: rig.space.id)
        let stranger = try DirectSession(socket: rig.state.paths.mcpSocket.path)
        defer { stranger.close() }
        try await stranger.initialize(as: "claude-code")
        let theirs = try await stranger.call(rig.tool("list_tabs"))
        #expect(theirs.text.contains(rig.a.id.uuidString.lowercased()))
    }

    @Test(.timeLimit(.minutes(1))) func anArtifactTabWhosePageIsOnASwitchedOffSiteIsLeftOut() async throws {
        MainRunLoopGuard.start
        let rig = try await makeRig(mode: nil)
        defer { tearDown(rig) }
        let artifacts = rig.state.paths.artifactsDirectory(rig.space.slug)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Report</title><p>hi</p>".utf8).write(to: artifacts.appending(path: "report.html"))
        rig.state.openArtifact("report.html")
        let tab = try #require(rig.state.selectedSpace?.tabs.first { $0.artifactPath == "report.html" })
        let controller = try #require(await rig.state.liveWebController(tabID: tab.id, spaceID: rig.space.id))
        // Its page leaves the artifact server (nothing listens on port 1: the error page keeps the address).
        controller.load(URL(string: "http://127.0.0.1:1/elsewhere")!)
        try await waitUntil("the page to move", limit: .seconds(10)) { controller.webView.url?.port == 1 }
        #expect(rig.state.space(rig.space.id)?.tab(tab.id)?.isArtifact == true)

        let caller = AgentCaller.plugin(id: DoorWorkspace.id, title: DoorWorkspace.title)
        let program = try await rig.startProgram("child")
        let toolbox = AgentToolbox(state: rig.state)
        let id = tab.id.uuidString.lowercased()
        var tabs = await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: program)
        #expect(text(tabs).contains(id))

        rig.state.updateSiteSettings(spaceID: rig.space.id, site: "http://127.0.0.1:1") { $0.disabledPlugins.insert(DoorWorkspace.id) }
        tabs = await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: program)
        #expect(!text(tabs).contains(id), "got \(text(tabs))")
        let close = await toolbox.call(rig.tool("close"), arguments: ["tab_id": .string(id)], client: "x", caller: caller, program: program)
        #expect(close.isError == true && text(close) == "Door Helper is switched off for this site.", "got \(text(close))")
        #expect(rig.state.space(rig.space.id)?.tab(tab.id) != nil)
    }

    /// Item of the final review: a plugin's `read_page` that was in flight (its page loading) when
    /// the owner switched the Space off for the plugin ends refused, as a call to a closed Space,
    /// with nothing from the page.
    @Test(.timeLimit(.minutes(1))) func aReadInFlightWhenTheSpaceGoesOffReturnsNothing() async throws {
        MainRunLoopGuard.start
        let server = try TitleFixtureServer.start()
        defer { server.stop() }
        let rig = try await makeRig(mode: "child")
        defer { tearDown(rig) }
        let caller = AgentCaller.plugin(id: DoorWorkspace.id, title: DoorWorkspace.title)
        let program = try #require(rig.manager.programPID(of: DoorWorkspace.id))
        let toolbox = AgentToolbox(state: rig.state)
        rig.state.openInNewTab(server.url("/slow-titled?t=SecretTitle"))
        let tab = try #require(rig.state.selectedSpace?.tabs.last)
        let read = Task { @MainActor in
            await toolbox.call(rig.tool("read_page"), arguments: ["tab_id": .string(tab.id.uuidString.lowercased())],
                               client: "x", caller: caller, program: program)
        }
        // The call has started (it marks the tab) and waits for the page, which is still loading
        // (the server answers after a second).
        try await waitUntil("the call to wait for the page", limit: .seconds(10)) {
            rig.state.isAgentBusy(tab.id) && rig.state.web.existingController(tab.id)?.webView.isLoading == true
        }
        rig.manager.setEnabled(DoorWorkspace.id, space: rig.space.id, false)
        let result = await read.value
        let got = text(result)
        #expect(result.isError == true && got == "Unknown tool \(rig.tool("read_page")). Call list_spaces to see what is available.",
                "got \(got)")
        #expect(!got.contains("SecretTitle") && !got.contains("titled") && !got.contains(String(server.port)))
        // The page did load: only the answer was withheld.
        #expect(rig.state.web.existingController(tab.id)?.webView.title == "SecretTitle")

        // An outside agent's read of the same page is not affected by the plugin's switch.
        rig.state.setAgentsEnabled(true, spaceID: rig.space.id)
        let theirs = await toolbox.call(rig.tool("read_page"), arguments: ["tab_id": .string(tab.id.uuidString.lowercased())],
                                        client: "x", caller: .outside)
        #expect(theirs.isError != true && text(theirs).contains("titled"), "got \(text(theirs))")
    }

    /// A plugin's connection learns of a terminal tab only its id, kind, section and whether it is
    /// selected or on screen: no title, folder or project. An outside agent's list is as before.
    @Test(.timeLimit(.minutes(1))) func aPluginsTabListNamesNoTerminal() async throws {
        let rig = try await makeRig(mode: "child", terminal: true)
        defer { tearDown(rig) }
        let terminal = try #require(rig.state.space(rig.space.id)?.tabs.first { $0.isTerminal })
        let id = terminal.id.uuidString.lowercased()
        let caller = AgentCaller.plugin(id: DoorWorkspace.id, title: DoorWorkspace.title)
        let program = try #require(rig.manager.programPID(of: DoorWorkspace.id))
        let toolbox = AgentToolbox(state: rig.state)

        func entries(_ result: CallTool.Result) throws -> [[String: Any]] {
            let lines = text(result).split(separator: "\n", omittingEmptySubsequences: false)
            let json = lines.dropFirst().prefix { !$0.hasPrefix("</untrusted_page_content") }.joined(separator: "\n")
            return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]], "got \(text(result))")
        }

        let mine = try entries(await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: program))
        let myTerminal = try #require(mine.first { $0["tab_id"] as? String == id })
        #expect(Set(myTerminal.keys) == ["tab_id", "kind", "section"], "got \(myTerminal)")
        #expect(myTerminal["kind"] as? String == "terminal" && myTerminal["section"] as? String == "open")
        // Web tabs keep their title and address.
        let web = try #require(mine.first { $0["tab_id"] as? String == rig.b.id.uuidString.lowercased() })
        #expect(web["url"] as? String == "https://b.example/" && web["title"] != nil)
        // (Not selected here: selecting a terminal would start a shell.)
        #expect(!text(await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: caller, program: program))
            .contains("secret-project"))

        // An outside agent: title, folder and project, as before.
        rig.state.setAgentsEnabled(true, spaceID: rig.space.id)
        let theirs = try entries(await toolbox.call(rig.tool("list_tabs"), arguments: [:], client: "x", caller: .outside))
        let theirTerminal = try #require(theirs.first { $0["tab_id"] as? String == id })
        #expect(theirTerminal["title"] as? String == "claude --resume ~/Developer/secret-project")
        #expect(theirTerminal["directory"] as? String == "~/Developer/secret-project")
        #expect(theirTerminal["project"] as? String == "secret-project")
        #expect(theirTerminal["kind"] as? String == "terminal" && theirTerminal["section"] as? String == "open")
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }
}
}
