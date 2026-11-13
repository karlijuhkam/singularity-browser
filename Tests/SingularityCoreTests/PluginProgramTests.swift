import Foundation
import Testing
@testable import SingularityCore

// Paths in the repository, found from this file's location.
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

// MARK: - Wire, policy and environment (no Bun needed)

@Suite struct PluginProgramWireTests {
    @Test func newMessagesRoundTrip() throws {
        let messages: [PluginWire] = [
            .startProgram(programID: 1, program: "claude", arguments: ["--print", "a b"], environment: ["X": "1"]),
            .programInput(programID: 1, data: "AAEC/w=="),
            .closeProgramInput(programID: 1),
            .killProgram(programID: 1, signal: "SIGINT"),
            .programOutputRead(programID: 1, bytes: 49152),
            .panelPost(payload: .object(["text": .string("hi"), "n": .array([.number(1), .null])])),
            .programStarted(programID: 2),
            .programFailed(programID: 2, reason: "a program is already running"),
            .programOutput(programID: 2, data: "aGVsbG8K"),
            .programExit(programID: 2, status: 0, signal: nil),
            .programExit(programID: 3, status: nil, signal: "SIGKILL"),
            .panelMessage(requestID: 9, payload: .string("ping")),
        ]
        for m in messages {
            let data = try JSONEncoder().encode(m)
            #expect(!data.contains(0x0A), "one message must be one line")
            #expect(try JSONDecoder().decode(PluginWire.self, from: data) == m)
        }
        // The "kind" is the case name.
        let line = String(decoding: try JSONEncoder().encode(messages[4]), as: UTF8.self)
        #expect(line.contains(#""kind":"programOutputRead""#))
        // What host.ts sends: an environment may be missing (none), and null fields mean none.
        #expect(try JSONDecoder().decode(PluginWire.self, from: Data(#"{"kind":"startProgram","programID":4,"program":"x","arguments":[]}"#.utf8))
                == .startProgram(programID: 4, program: "x", arguments: [], environment: [:]))
        #expect(try JSONDecoder().decode(PluginWire.self, from: Data(#"{"kind":"programExit","programID":5,"status":null,"signal":"SIGTERM"}"#.utf8))
                == .programExit(programID: 5, status: nil, signal: "SIGTERM"))
    }

    @Test func spawnIsRefusedInATestCopy() {
        #expect(ProgramPolicy.spawnAllowed(environment: [:]))
        #expect(ProgramPolicy.spawnAllowed(environment: ["SINGULARITY_REAL_PROGRAMS": "1"]))
        #expect(!ProgramPolicy.spawnAllowed(environment: ["SINGULARITY_HOME": "/private/tmp/sg-test"]))
        #expect(ProgramPolicy.spawnAllowed(environment: ["SINGULARITY_HOME": "/private/tmp/sg-test",
                                                         "SINGULARITY_REAL_PROGRAMS": "1"]))
        // Exactly "1".
        #expect(!ProgramPolicy.spawnAllowed(environment: ["SINGULARITY_HOME": "/x", "SINGULARITY_REAL_PROGRAMS": "yes"]))
        #expect(!ProgramPolicy.spawnAllowed(environment: ["SINGULARITY_HOME": "/x", "SINGULARITY_REAL_PROGRAMS": ""]))
    }

    @Test func environmentIsExactlyWhatTheAppChooses() {
        let env = ProgramEnvironment.make(
            home: "/Users/me", user: "me", loginPath: "/opt/homebrew/bin:/usr/bin:/bin", tmpdir: "/var/folders/x/T/",
            appVersion: "0.3.0",
            requested: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "NOT_ALLOWED": "1", "EMPTY_ONE": "",
                        "WITH_NUL": "a\u{0}b", "HOME": "/elsewhere"],
            allowed: ["CLAUDE_CONFIG_DIR", "EMPTY_ONE", "WITH_NUL", "HOME"])
        #expect(env == [
            "HOME": "/Users/me",
            "USER": "me",
            "LOGNAME": "me",
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "TMPDIR": "/var/folders/x/T/",
            "LANG": "en_US.UTF-8",
            "CLAUDE_AGENT_SDK_CLIENT_APP": "singularity/0.3.0",
            "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work",
        ])
        // Nothing requested: just the fixed set.
        #expect(Set(ProgramEnvironment.make(home: "/h", user: "u", loginPath: "/bin", tmpdir: "/t", appVersion: "1",
                                            requested: [:], allowed: []).keys)
                == ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "CLAUDE_AGENT_SDK_CLIENT_APP"])
    }

    @Test func signalNames() {
        #expect(ProgramSignal.number("SIGTERM") == SIGTERM)
        #expect(ProgramSignal.number("SIGKILL") == SIGKILL)
        #expect(ProgramSignal.number("SIGINT") == SIGINT)
        #expect(ProgramSignal.number("SIGHUP") == SIGTERM)   // anything else is SIGTERM
        #expect(ProgramSignal.number("") == SIGTERM)
        #expect(ProgramSignal.name(SIGKILL) == "SIGKILL")
        #expect(ProgramSignal.name(SIGSEGV) == "SIGSEGV")
        #expect(ProgramSignal.name(99) == "SIG99")
    }
}

// MARK: - The real thing: Bun in the sandbox, the fixture program outside it

/// Collects what a plugin process reports, so tests can wait for it.
private final class Recorder: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var replies: [Int: JSONValue] = [:]
    private var logs: [(level: String, message: String)] = []
    private var exits: [Int32] = []
    private var posts: [JSONValue] = []

    func attach(_ process: PluginProcess) {
        process.onReply = { id, payload in self.record(reply: id, payload) }
        process.onLog = { level, message in self.lock.withLock { self.logs.append((level, message)) } }
        process.onExit = { status in self.lock.withLock { self.exits.append(status) } }
        process.onPanelPost = { payload in self.record(post: payload) }
    }

    func record(reply id: Int, _ payload: JSONValue) { lock.withLock { replies[id] = payload } }
    func record(post payload: JSONValue) { lock.withLock { posts.append(payload) } }

    var logLines: [(level: String, message: String)] { lock.withLock { logs } }
    var exitStatuses: [Int32] { lock.withLock { exits } }
    var panelPosts: [JSONValue] { lock.withLock { posts } }

    func reply(_ id: Int) async throws -> JSONValue {
        try await waitFor("reply \(id)") { self.lock.withLock { self.replies[id] } }
    }
}

/// Polls `check` every 20 ms until it returns a value; fails after `timeout`.
private func waitFor<T>(_ what: String, timeout: Duration = .seconds(30),
                        _ check: @escaping () -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = check() { return value }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}

/// A test's temp folder (real path, as the sandbox sees it): `<root>/program` (a copy of the
/// fixture plugin), `<root>/data`, and the fixture program at `<root>/fixture-program`.
private struct Workspace {
    let root: URL, plugin: URL, data: URL, program: URL
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func makeWorkspace() throws -> Workspace {
    let temp = FileManager.default.temporaryDirectory.appending(path: "sing-prog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let root = URL(filePath: try PluginProcess.realPath(temp), directoryHint: .isDirectory)
    let plugin = root.appending(path: "program", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: fixtures.appending(path: "plugins/program"), to: plugin)
    let program = root.appending(path: "fixture-program")
    try FileManager.default.copyItem(at: fixtures.appending(path: "echo-program.sh"), to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    return Workspace(root: root, plugin: plugin, data: root.appending(path: "data", directoryHint: .isDirectory),
                     program: program)
}

/// What the tests pass as the app's environment for programs: the real thing is built by the
/// manager (Task 5); here a fixed home and the system PATH.
private func testEnvironment(_ requested: [String: String]) -> [String: String] {
    ProgramEnvironment.make(home: "/private/tmp/sg-fixture-home", user: "fixture", loginPath: "/usr/bin:/bin",
                            tmpdir: "/private/tmp", appVersion: "test", requested: requested,
                            allowed: ["FIXTURE_SETTING"])
}

private func makeProcess(_ ws: Workspace, programsAllowed: Bool = true,
                         commandPaths: [String: String]? = nil) throws -> PluginProcess {
    PluginProcess(manifest: try PluginManifest.load(from: ws.plugin), folder: ws.plugin, dataFolder: ws.data,
                  runtime: bunPath, host: hostScript, commandPaths: commandPaths ?? ["fixture": ws.program.path],
                  programsAllowed: programsAllowed, programEnvironment: testEnvironment)
}

private func message(_ id: Int, _ payload: JSONValue) -> PluginWire {
    .pageMessage(requestID: id, tabID: UUID(), frameHost: "example.com", payload: payload)
}

/// Starts a process on a fresh workspace; the caller stops it and removes the workspace.
private func started(programsAllowed: Bool = true, commandPaths: [String: String]? = nil)
    throws -> (PluginProcess, Recorder, Workspace) {
    let ws = try makeWorkspace()
    let process = try makeProcess(ws, programsAllowed: programsAllowed, commandPaths: commandPaths)
    let recorder = Recorder()
    recorder.attach(process)
    try process.start()
    return (process, recorder, ws)
}

private func field(_ value: JSONValue, _ name: String) -> JSONValue? {
    if case .object(let fields) = value { return fields[name] } else { return nil }
}

/// Whether a process with this pid exists (signal 0 checks without sending anything).
private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

@Suite(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct PluginProgramTests {
    @Test(.timeLimit(.minutes(1))) func echoIsBinarySafe() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("echo")))
        #expect(try await recorder.reply(1) == .object(["same": .bool(true), "length": .number(700 * 1024), "code": .number(0)]))
    }

    @Test(.timeLimit(.minutes(1))) func slowReaderGetsEverythingWhileTheAppHoldsLittle() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("slow")))
        let reply = try await recorder.reply(1)
        #expect(field(reply, "lines") == .number(750_000))
        #expect(field(reply, "inOrder") == .bool(true))
        #expect(field(reply, "code") == .number(0))
        guard case .number(let bytes)? = field(reply, "bytes"), case .number(let buffered)? = field(reply, "maxBuffered") else {
            Issue.record("unexpected reply \(reply)")
            return
        }
        #expect(bytes > 5_000_000)
        // The plugin's stream never held much more than the app's limit...
        #expect(buffered <= Double(PluginProcess.maxProgramUnread + 2 * PluginProcess.maxProgramOutputChunk))
        // ...and the app stopped reading the program: it reached its limit but never went past it
        // by more than one chunk.
        let peak = process.programUnreadPeak
        #expect(peak > PluginProcess.maxProgramUnread / 2, "the slow reader never made the app wait (\(peak))")
        #expect(peak <= PluginProcess.maxProgramUnread + PluginProcess.maxProgramOutputChunk, "\(peak)")
    }

    @Test(.timeLimit(.minutes(1))) func exitComesAfterTheLastByte() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("exit")))
        let expected = (1...20000).reduce(0) { $0 + String($1).utf8.count + 1 }
        #expect(try await recorder.reply(1) == .object([
            "code": .number(7), "signal": .null, "atExit": .number(Double(expected)), "bytes": .number(Double(expected)),
        ]))
    }

    @Test(.timeLimit(.minutes(1))) func killEndsTheProgram() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("kill")))
        #expect(try await recorder.reply(1) == .object([
            "code": .null, "signal": .string("SIGTERM"), "killed": .bool(true), "exitCode": .null,
        ]))
    }

    @Test(.timeLimit(.minutes(1))) func programGetsOnlyTheAppsEnvironmentInTheDataFolder() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("env")))
        guard case .string(let text)? = field(try await recorder.reply(1), "text") else {
            Issue.record("no text")
            return
        }
        var lines = text.split(separator: "\n").map(String.init)
        #expect(lines.removeFirst() == ws.data.path)
        var env: [String: String] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        #expect(env["HOME"] == "/private/tmp/sg-fixture-home")
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["CLAUDE_AGENT_SDK_CLIENT_APP"] == "singularity/test")
        #expect(env["FIXTURE_SETTING"] == "yes")
        #expect(env["NOT_LISTED"] == nil)
        #expect(env["EMPTY"] == nil)
        // The rest is what /bin/sh itself adds; nothing comes from the app's own environment.
        let fromShell: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"]
        let expected = Set(testEnvironment(["FIXTURE_SETTING": "yes"]).keys)
        #expect(Set(env.keys).subtracting(fromShell) == expected, "\(env.keys.sorted())")
    }

    @Test(.timeLimit(.minutes(1))) func stderrGoesToThePluginLog() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("stderr")))
        #expect(try await recorder.reply(1) == .object(["code": .number(0)]))
        #expect(recorder.logLines.contains { $0.level == "info" && $0.message == "fixture: a line on stderr" },
                Comment(rawValue: "\(recorder.logLines)"))
    }

    /// How the plugin goes away while its program ignores SIGTERM: stopped, killed at app quit, or crashed.
    enum Ending: CaseIterable { case stop, terminateNow, pluginExits }

    @Test(.timeLimit(.minutes(1)), arguments: Ending.allCases)
    func programAndItsChildEndWithThePlugin(_ ending: Ending) async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string(ending == .pluginExits ? "ignore-term-then-crash" : "ignore-term")))
        guard case .string(let text)? = field(try await recorder.reply(1), "pids") else {
            Issue.record("no pids")
            return
        }
        let pids = text.split(separator: " ").compactMap { Int32($0) }
        try #require(pids.count == 2)
        #expect(pids.allSatisfy(alive))
        let begun = ContinuousClock.now
        switch ending {
        case .stop: process.stop()
        case .terminateNow: process.terminateNow()
        case .pluginExits: _ = try await waitFor("the plugin to exit") { recorder.exitStatuses.first }
        }
        _ = try await waitFor("the program and its child to end", timeout: .seconds(5)) {
            pids.contains(where: alive) ? nil : true
        }
        // At app quit there is no time for SIGTERM and a wait: terminateNow kills at once.
        #expect(ContinuousClock.now - begun < (ending == .terminateNow ? .seconds(1) : .seconds(3)))
    }

    @Test(.timeLimit(.minutes(1))) func whatAProgramLeavesBehindEndsWithIt() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("leave-child")))
        let reply = try await recorder.reply(1)
        guard case .string(let text)? = field(reply, "pid"), let pid = Int32(text) else {
            Issue.record("no pid: \(reply)")
            return
        }
        #expect(field(reply, "code") == .number(0))
        // The child held the program's stdout open; it was killed when the program ended, so
        // the exit came without waiting out the 2 s grace, and the child is gone.
        _ = try await waitFor("the child to end", timeout: .seconds(1)) { alive(pid) ? nil : true }
    }

    @Test(.timeLimit(.minutes(1))) func refusedStarts() async throws {
        func refusal(_ name: String, programsAllowed: Bool = true, commandPaths: [String: String]? = nil) async throws -> JSONValue {
            let (process, recorder, ws) = try started(programsAllowed: programsAllowed, commandPaths: commandPaths)
            defer { ws.remove() }
            defer { process.stop() }
            process.send(message(1, .object(["spawnFail": .string(name)])))
            return try await recorder.reply(1)
        }
        func failed(_ reason: String) -> JSONValue { .object(["error": .string(reason), "code": .number(126)]) }
        #expect(try await refusal("fixture", programsAllowed: false) == failed("programs are off in a test copy"))
        #expect(try await refusal("other") == failed("not allowed by the manifest"))
        #expect(try await refusal("unpinned") == failed("not allowed by the manifest"))
        #expect(try await refusal("fixture", commandPaths: ["fixture": "/nonexistent/fixture"])
                == failed("the program is missing or changed"))
        #expect(try await refusal("fixture", commandPaths: ["fixture": "/bin/sh"])
                == failed("the program is missing or changed"))
    }

    @Test(.timeLimit(.minutes(1))) func oneProgramAtATime() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("twice")))
        #expect(try await recorder.reply(1) == .object([
            "second": .object(["error": .string("a program is already running"), "code": .number(126)]),
            "first": .object(["code": .number(0), "signal": .null]),
        ]))
        // Once the first has ended, another may start.
        process.send(message(2, .string("exit")))
        #expect(field(try await recorder.reply(2), "code") == .number(7))
    }

    @Test(.timeLimit(.minutes(1))) func panelPostsReachTheApp() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(message(1, .string("post")))
        let reply = try await recorder.reply(1)
        guard case .string(let thrown)? = field(reply, "thrown") else {
            Issue.record("a 300 KB post did not throw: \(reply)")
            return
        }
        #expect(thrown.contains("256 KB"))
        #expect(recorder.panelPosts == [.object(["hello": .string("panel"), "n": .array([.number(1), .number(2)])])])
    }

    @Test(.timeLimit(.minutes(1))) func panelMessagesAreAnsweredByOnPageMessage() async throws {
        let (process, recorder, ws) = try started()
        defer { ws.remove() }
        defer { process.stop() }
        process.send(.panelMessage(requestID: 1, payload: .object(["say": .string("hi")])))
        #expect(try await recorder.reply(1) == .object([
            "tabID": .string("panel"), "frameHost": .string(""), "payload": .object(["say": .string("hi")]),
        ]))
    }

    @Test(.timeLimit(.minutes(1))) func supervisorForwardsPanelMessagesAndPosts() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let manifest = try PluginManifest.load(from: ws.plugin)
        let supervisor = PluginSupervisor(restartDelay: .zero) {
            PluginProcess(manifest: manifest, folder: ws.plugin, dataFolder: ws.data, runtime: bunPath,
                          host: hostScript, commandPaths: ["fixture": ws.program.path],
                          programsAllowed: true, programEnvironment: testEnvironment)
        }
        let recorder = Recorder()
        supervisor.onReply = { id, payload in recorder.record(reply: id, payload) }
        supervisor.onPanelPost = { payload in recorder.record(post: payload) }
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.send(.panelMessage(requestID: 1, payload: .string("x")))
        #expect(field(try await recorder.reply(1), "tabID") == .string("panel"))
        supervisor.send(message(2, .string("post")))
        _ = try await recorder.reply(2)
        #expect(recorder.panelPosts.count == 1)
    }
}
