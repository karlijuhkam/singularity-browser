import Foundation
import Testing
@testable import SingularityCore

// Paths in the repository, found from this file's location.
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/plugins")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

/// Collects what a plugin process reports, so tests can wait for it.
private final class Recorder: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var replies: [Int: JSONValue] = [:]
    private var logs: [(level: String, message: String)] = []
    private var exits: [Int32] = []

    func attach(_ process: PluginProcess) {
        process.onReply = { id, payload in self.lock.withLock { self.replies[id] = payload } }
        process.onLog = { level, message in self.lock.withLock { self.logs.append((level, message)) } }
        process.onExit = { status in self.lock.withLock { self.exits.append(status) } }
    }

    var logLines: [(level: String, message: String)] { lock.withLock { logs } }
    var exitStatuses: [Int32] { lock.withLock { exits } }

    func reply(_ id: Int) async throws -> JSONValue {
        try await waitFor("reply \(id)") { self.lock.withLock { self.replies[id] } }
    }
}

/// Polls `check` every 20 ms until it returns a value; fails after `timeout`.
private func waitFor<T>(_ what: String, timeout: Duration = .seconds(20),
                        _ check: @escaping () -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = check() { return value }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}

/// A temp folder (real path, so it matches what the sandbox sees) with a copy of the `echo`
/// fixture at `<root>/echo` and an empty `<root>/data`.
private func makeWorkspace(background: String? = nil) throws -> (root: URL, plugin: URL, data: URL) {
    let temp = FileManager.default.temporaryDirectory.appending(path: "sing-proc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(temp.path, &buffer) != nil else { throw CocoaError(.fileNoSuchFile) }
    let real = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let root = URL(filePath: real, directoryHint: .isDirectory)
    let plugin = root.appending(path: "echo", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: fixtures.appending(path: "echo"), to: plugin)
    if let background {
        try background.write(to: plugin.appending(path: "background.ts"), atomically: true, encoding: .utf8)
    }
    return (root, plugin, root.appending(path: "data", directoryHint: .isDirectory))
}

private func makeProcess(_ ws: (root: URL, plugin: URL, data: URL)) throws -> PluginProcess {
    PluginProcess(manifest: try PluginManifest.load(from: ws.plugin), folder: ws.plugin, dataFolder: ws.data,
                  runtime: bunPath, host: hostScript, commandPaths: ["echo": "/bin/echo"])
}

private func message(_ id: Int, _ payload: JSONValue) -> PluginWire {
    .pageMessage(requestID: id, tabID: UUID(), frameHost: "example.com", payload: payload)
}

// MARK: - Wire format and line splitting (no Bun needed)

@Suite struct PluginWireTests {
    @Test func encodesWithKindDiscriminator() throws {
        let tab = UUID()
        let messages: [PluginWire] = [
            .pageMessage(requestID: 1, tabID: tab, frameHost: "a.com",
                         payload: .object(["x": .array([.number(1.5), .bool(true), .null, .string("s")])])),
            .commandResult(callID: 2, result: CommandResult(status: 0, stdout: "out", stderr: "", timedOut: false)),
            .reply(requestID: 3, payload: .string("hi")),
            .runCommand(callID: 4, command: "op", arguments: ["item", "list"]),
            .log(level: "info", message: "hello"),
        ]
        for m in messages {
            let data = try JSONEncoder().encode(m)
            #expect(!data.contains(0x0A), "one message must be one line")
            #expect(try JSONDecoder().decode(PluginWire.self, from: data) == m)
        }
        let line = String(decoding: try JSONEncoder().encode(messages[3]), as: UTF8.self)
        #expect(line.contains(#""kind":"runCommand""#))
        // What host.ts sends.
        let fromPlugin = #"{"kind":"reply","requestID":7,"payload":{"echo":[1,"a",null,false]}}"#
        #expect(try JSONDecoder().decode(PluginWire.self, from: Data(fromPlugin.utf8))
                == .reply(requestID: 7, payload: .object(["echo": .array([.number(1), .string("a"), .null, .bool(false)])])))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginWire.self, from: Data(#"{"kind":"nope"}"#.utf8))
        }
    }

    @Test func splitsLinesAndDropsHugeOnes() {
        var lines = LineSplitter(maxLength: 10)
        #expect(lines.append(Data("ab".utf8)) == [])
        #expect(lines.append(Data("c\nde\n\nf".utf8)) == [.line(Data("abc".utf8)), .line(Data("de".utf8)), .line(Data())])
        // "f" + 12 more bytes passes the limit: the rest of that line is thrown away.
        #expect(lines.append(Data("123456789012".utf8)) == [.tooLong])
        #expect(lines.append(Data("345\nok\n".utf8)) == [.line(Data("ok".utf8))])
        #expect(lines.finish() == [])
        var tail = LineSplitter(maxLength: 10)
        _ = tail.append(Data("x".utf8))
        #expect(tail.finish() == [.line(Data("x".utf8))])
    }
}

// MARK: - The real thing: Bun under sandbox-exec

@Suite(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct PluginProcessTests {
    @Test(.timeLimit(.minutes(1))) func roundTripsPageMessages() async throws {
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("hi")))
        process.send(message(2, .object(["n": .number(3), "list": .array([.bool(true), .null])])))
        #expect(try await recorder.reply(1) == .object(["echo": .string("hi")]))
        #expect(try await recorder.reply(2) == .object(["echo": .object(["n": .number(3), "list": .array([.bool(true), .null])])]))
        // A handler that throws answers with the error message.
        process.send(message(3, .string("throw")))
        #expect(try await recorder.reply(3) == .object(["error": .string("boom")]))
    }

    @Test(.timeLimit(.minutes(1))) func repliesNoHandler() async throws {
        let ws = try makeWorkspace(background: #"console.log("no handler here");"#)
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }
        process.send(message(1, .string("hi")))
        #expect(try await recorder.reply(1) == .object(["error": .string("no handler")]))
    }

    @Test(.timeLimit(.minutes(1))) func runsDeclaredCommandOnly() async throws {
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("run-op")))
        process.send(message(2, .string("forbidden")))
        #expect(try await recorder.reply(1) == .object([
            "status": .number(0), "stdout": .string("hello\n"), "stderr": .string(""), "timedOut": .bool(false),
        ]))
        #expect(try await recorder.reply(2) == .object([
            "status": .number(126), "stdout": .string(""), "stderr": .string("not allowed by the manifest"),
            "timedOut": .bool(false),
        ]))
    }

    @Test(.timeLimit(.minutes(1))) func networkIsBlocked() async throws {
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("net")))
        let reply = try await recorder.reply(1)
        guard case .object(let fields) = reply, case .string(let error)? = fields["fetchError"] else {
            Issue.record("expected a fetch error, got \(reply)")
            return
        }
        #expect(!error.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cannotReadOutsideItsFolder() async throws {
        let ws = try makeWorkspace()
        // A file next to (not inside) the plugin and data folders.
        let outside = ws.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appending(path: "secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        // Control: its own files are readable, so the read code itself works.
        process.send(message(1, .object(["read": .string(ws.plugin.appending(path: "plugin.json").path)])))
        guard case .object(let own) = try await recorder.reply(1), case .string(let text)? = own["read"] else {
            Issue.record("plugin could not read its own plugin.json")
            return
        }
        #expect(text.contains(#""id": "echo""#))

        process.send(message(2, .object(["read": .string(secret.path)])))
        let reply = try await recorder.reply(2)
        guard case .object(let fields) = reply, case .string(let error)? = fields["readError"] else {
            Issue.record("expected a read error, got \(reply)")
            return
        }
        #expect(error.contains("EPERM") || error.contains("not permitted"), Comment(rawValue: error))
    }

    @Test(.timeLimit(.minutes(1))) func consoleLogDoesNotBreakTheWire() async throws {
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("console")))
        #expect(try await recorder.reply(1) == .object(["echo": .string("console")]))
        let logs = try await waitFor("both console lines") { () -> [(level: String, message: String)]? in
            let lines = recorder.logLines
            return lines.count >= 2 ? lines : nil
        }
        #expect(logs.contains { $0.level == "info" && $0.message == "noise on stdout" }, Comment(rawValue: "\(logs)"))
        #expect(logs.contains { $0.level == "error" && $0.message == "noise on stderr" }, Comment(rawValue: "\(logs)"))
    }

    @Test(.timeLimit(.minutes(1))) func environmentIsMinimal() async throws {
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("env")))
        guard case .object(let fields) = try await recorder.reply(1),
              case .array(let keyValues)? = fields["keys"], case .string(let home)? = fields["home"] else {
            Issue.record("unexpected env reply")
            return
        }
        let keys = Set(keyValues.compactMap { if case .string(let s) = $0 { s } else { nil } })
        for leaked in ["PATH", "SSH_AUTH_SOCK", "USER", "LOGNAME", "SHELL"] {
            #expect(!keys.contains(leaked), "\(leaked) leaked into the plugin: \(keys)")
        }
        #expect(home == ws.data.path)
        #expect(keys.isSubset(of: ["HOME", "TMPDIR", "LANG", "NO_COLOR", "BUN_RUNTIME_TRANSPILER_CACHE_PATH"]),
                Comment(rawValue: "\(keys)"))
    }

    @Test(.timeLimit(.minutes(1))) func stopEndsTheProcessOnce() async throws {
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        process.send(message(1, .string("hi")))
        _ = try await recorder.reply(1)
        process.stop()
        process.stop()
        _ = try await waitFor("exit") { recorder.exitStatuses.first }
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.exitStatuses.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func sendingToAnExitedPluginIsHarmless() async throws {
        // Writing to a pipe nobody reads any more must not kill the app (SIGPIPE).
        let ws = try makeWorkspace()
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }
        process.send(message(1, .string("crash")))
        for i in 2...200 {
            process.send(message(i, .string(String(repeating: "x", count: 10_000))))
            if i % 20 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(try await waitFor("exit") { recorder.exitStatuses.first } == 1)
        process.send(message(999, .string("after exit")))
    }

    @Test(.timeLimit(.minutes(1))) func stopKillsAPluginThatIgnoresSigterm() async throws {
        // Ignores SIGTERM, then blocks its only thread so it can't notice stdin closing either.
        let ws = try makeWorkspace(background: """
            import { singularity } from "singularity";
            process.on("SIGTERM", () => {});
            singularity.onPageMessage(() => { while (true) {} });
            """)
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        process.send(message(1, .string("block")))
        try await Task.sleep(for: .milliseconds(500))
        let stopped = ContinuousClock.now
        process.stop()
        let status = try await waitFor("exit") { recorder.exitStatuses.first }
        #expect(status == SIGKILL)
        #expect(ContinuousClock.now - stopped >= .seconds(1.5))
    }

    // MARK: Supervisor

    /// A clock the test moves by hand.
    private final class FakeClock: @unchecked Sendable {   // `now` behind `lock`
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    private final class Counter: @unchecked Sendable {   // `value` behind `lock`
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// Starts a supervisor on the echo plugin; every call of the factory is counted.
    private func supervise(_ clock: FakeClock, _ starts: Counter) throws -> PluginSupervisor {
        let ws = try makeWorkspace()
        let manifest = try PluginManifest.load(from: ws.plugin)
        return PluginSupervisor(restartDelay: .zero, now: { clock.now }) {
            starts.increment()
            return PluginProcess(manifest: manifest, folder: ws.plugin, dataFolder: ws.data,
                                 runtime: bunPath, host: hostScript, commandPaths: [:])
        }
    }

    /// Sends "crash" to the running plugin and waits until the supervisor has dealt with it:
    /// either a new process answers a ping, or the supervisor has given up.
    private func crash(_ supervisor: PluginSupervisor, _ starts: Counter, expectRestart: Bool) async throws {
        let exits = supervisor.recentLogs.filter { $0.message.hasPrefix("exited") }.count
        supervisor.send(message(99, .string("crash")))
        _ = try await waitFor("exit") {
            supervisor.recentLogs.filter { $0.message.hasPrefix("exited") }.count > exits ? true : nil
        }
        guard expectRestart else { return }
        let replies = Replies()
        supervisor.onReply = { id, payload in replies.add(id, payload) }
        // Ping until the new process answers (messages sent while it is starting are dropped).
        _ = try await waitFor("restarted plugin answers") { () -> Bool? in
            if replies.has(1) { return true }
            supervisor.send(message(1, .string("ping")))
            return nil
        }
    }

    private final class Replies: @unchecked Sendable {   // `ids` behind `lock`
        private let lock = NSLock()
        private var ids = Set<Int>()
        func add(_ id: Int, _ payload: JSONValue) { lock.withLock { _ = ids.insert(id) } }
        func has(_ id: Int) -> Bool { lock.withLock { ids.contains(id) } }
    }

    @Test(.timeLimit(.minutes(1))) func restartBackoffStopsAfterThreeCrashes() async throws {
        let clock = FakeClock(), starts = Counter()
        let supervisor = try supervise(clock, starts)
        defer { supervisor.stop() }
        supervisor.start()
        #expect(supervisor.state == .running)
        #expect(starts.value == 1)

        for _ in 1...3 {
            clock.advance(5)
            try await crash(supervisor, starts, expectRestart: true)
        }
        #expect(starts.value == 4)
        clock.advance(5)
        try await crash(supervisor, starts, expectRestart: false)
        // Gave up: no new process, now or later.
        try await Task.sleep(for: .milliseconds(500))
        #expect(starts.value == 4)
        #expect(supervisor.state == .crashedRepeatedly)
        #expect(supervisor.recentLogs.contains { $0.message.contains("exited with status 1") })
    }

    @Test(.timeLimit(.minutes(1))) func crashesOutsideTheWindowDoNotCount() async throws {
        let clock = FakeClock(), starts = Counter()
        let supervisor = try supervise(clock, starts)
        defer { supervisor.stop() }
        supervisor.start()
        // Five crashes 25 s apart: never more than three within 60 s.
        for _ in 1...5 {
            clock.advance(25)
            try await crash(supervisor, starts, expectRestart: true)
        }
        #expect(starts.value == 6)
        #expect(supervisor.state == .running)
    }

    @Test(.timeLimit(.minutes(1))) func deliberateStopDoesNotRestart() async throws {
        let clock = FakeClock(), starts = Counter()
        let supervisor = try supervise(clock, starts)
        supervisor.start()
        supervisor.stop()
        try await Task.sleep(for: .milliseconds(800))
        #expect(starts.value == 1)
        #expect(supervisor.state == .stopped)
    }
}
