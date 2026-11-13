import Darwin
import Foundation
import Testing
@testable import Singularity
import SingularityCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)
private let doorClient = repoRoot.appending(path: "Tests/SingularityAppTests/Fixtures/door-client.sh")

/// A data folder with one plugin, "doorfix" (panel title "Door Helper", name "Door Fixture"),
/// allowed `browser` and the program `door` = `door-client.sh`. Its background starts the program
/// when asked and relays lines: what the test sends goes to the program's stdin, what the program
/// prints is kept until the test reads it. So the test speaks MCP through the real launcher,
/// started by the real `PluginProcess`, exactly where the Assistant's `claude` would.
private struct DoorWorkspace {
    static let id = "doorfix"
    static let title = "Door Helper"
    let root: URL
    let program: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }

    init() throws {
        let fm = FileManager.default
        root = URL(filePath: "/private/tmp/sg-dr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        program = root.appending(path: "door-client")
        let plugin = Paths(root: root).pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: plugin.appending(path: path)) }
        try write("plugin.json", """
            {"id": "doorfix", "name": "Door Fixture", "version": "1.0.0", "description": "A test plugin.",
             "author": "Tests", "background": "background.ts",
             "panel": {"page": "panel.html", "title": "Door Helper"},
             "permissions": {"browser": true, "programs": ["door"]}}
            """)
        try write("panel.html", "<!doctype html><html><head><title>x</title></head><body></body></html>")
        try write("background.ts", """
            import { singularity } from "singularity";
            let program: any = null;
            let buffer = "";
            const lines: string[] = [];
            let exit: unknown = null;
            let error: string | null = null;
            singularity.onPageMessage(async ({ payload }) => {
              const p = payload as any;
              if (p && Array.isArray(p.start)) {
                program = singularity.spawn("door", p.start, {});
                program.on("error", (e: Error) => { error = e.message; });
                program.on("exit", (code: number | null, signal: string | null) => { exit = { code, signal }; });
                program.stdout.on("data", (chunk: Buffer) => {
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
              if (p === "read") return { lines: lines.splice(0), error, exit };
              return null;
            });
            """)
        try fm.copyItem(at: doorClient, to: program)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }

    private struct NotReady: Error, CustomStringConvertible { let description: String }

    /// Approved as it is now, on in no Space, with the door client pinned as `door`.
    func approve() throws {
        let scan = PluginScan.scan(folder: plugin)
        guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
            throw NotReady(description: "the fixture plugin doesn't scan: \(scan.manifest)")
        }
        let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                      commandPaths: ["door": program.path], enabledSpaces: [],
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
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
    private struct Rig {
        let ws: DoorWorkspace
        let appRoot: URL
        let manager: PluginManager
        let state: AppState
        let space: Space
        let a: BrowserTab
        let b: BrowserTab
        func tool(_ name: String) -> String { AgentToolName.make(slug: space.slug, tool: name) }
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

    /// One Space with agents OFF and two web tabs (a.example, b.example), the plugin approved,
    /// running and switched on for the Space, its program started in `mode` ("exec" or "child").
    private func makeRig(mode: String = "child") async throws -> Rig {
        let launcher = try Self.launcher()
        let ws = try DoorWorkspace()
        try ws.approve()
        // Programs allowed: a plain environment (no SINGULARITY_HOME), as the real app has it.
        let manager = PluginManager(paths: ws.paths, runtime: bunPath, host: hostScript,
                                    programs: .live(environment: [:], loginPath: { "/usr/bin:/bin" }))
        let appRoot = TestAppState.makeRoot()
        let state = TestAppState.make(root: appRoot, plugins: manager)
        state.closeWelcome()
        let spaceID = try #require(state.selectedSpaceID)
        #expect(state.space(spaceID)?.agentsEnabled == false)
        state.openInNewTab(URL(string: "https://a.example/page")!)
        state.openInNewTab(URL(string: "https://b.example/")!)
        let tabs = try #require(state.selectedSpace?.tabs)
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(DoorWorkspace.id)?.runState == .running }
        manager.setEnabled(DoorWorkspace.id, space: spaceID, true)

        let socket = state.paths.mcpSocket.path
        #expect(FileManager.default.fileExists(atPath: socket))
        let started = await manager.sendFromPanel(pluginID: DoorWorkspace.id, payload: .object([
            "start": .array([.string(mode), .string(launcher.path), .string(socket)]),
        ]))
        #expect(started == .object(["started": .bool(true)]))
        try await waitUntil("the program to run") { manager.programPID(of: DoorWorkspace.id) != nil }
        return Rig(ws: ws, appRoot: appRoot, manager: manager, state: state, space: try #require(state.space(spaceID)),
                   a: tabs[0], b: tabs[1])
    }

    /// The program first (it holds the launcher), then the state, then the folders.
    private func tearDown(_ rig: Rig) {
        rig.manager.terminateAll()
        TestAppState.shutDown(rig.state)
        rig.ws.remove()
        try? FileManager.default.removeItem(at: rig.appRoot)
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

    @Test(.timeLimit(.minutes(1))) func switchingTheSpaceOffTellsTheConnectionAndRefusesItsCalls() async throws {
        let rig = try await makeRig()
        defer { tearDown(rig) }
        let plugin = PluginSession(manager: rig.manager)
        try await plugin.initialize(as: "claude-code")
        #expect(try await plugin.toolNames().contains(rig.tool("list_tabs")))

        rig.manager.setEnabled(DoorWorkspace.id, space: rig.space.id, false)
        try await plugin.waitForListChanged()
        #expect(try await plugin.toolNames() == [AgentToolName.listSpaces])
        // A tool name remembered from before is refused.
        let refused = try await plugin.call(rig.tool("list_tabs"))
        #expect(refused.isError && refused.text == "Door Helper is switched off in the “\(rig.space.name)” Space.", "got \(refused)")
        let none = try await plugin.call(AgentToolName.listSpaces)
        #expect(none.text == "No Spaces are open to Door Helper. The user can switch it on for a Space with the button under the chat, or in Settings → Plugins.")
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
}
}
