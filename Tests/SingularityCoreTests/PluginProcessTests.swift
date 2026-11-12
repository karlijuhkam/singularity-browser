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

/// A test's temp folder: `<root>/echo` (a copy of the fixture) and `<root>/data`.
private struct Workspace {
    let root: URL, plugin: URL, data: URL
    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A temp folder (real path, so it matches what the sandbox sees) with a copy of the `echo`
/// fixture at `<root>/echo` and an empty `<root>/data`. Callers `defer { ws.remove() }`.
private func makeWorkspace(background: String? = nil) throws -> Workspace {
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
    return Workspace(root: root, plugin: plugin, data: root.appending(path: "data", directoryHint: .isDirectory))
}

private func makeProcess(_ ws: Workspace, commandPaths: [String: String] = ["echo": "/bin/echo"]) throws -> PluginProcess {
    PluginProcess(manifest: try PluginManifest.load(from: ws.plugin), folder: ws.plugin, dataFolder: ws.data,
                  runtime: bunPath, host: hostScript, commandPaths: commandPaths)
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
        defer { ws.remove() }
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

    @Test(.timeLimit(.minutes(1))) func storageKeepsValuesAcrossRestarts() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        func storage(_ parts: JSONValue...) -> JSONValue { .object(["storage": .array(parts)]) }

        let first = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(first)
        try first.start()
        first.send(message(1, storage(.string("get"), .string("missing"))))
        #expect(try await recorder.reply(1) == .object(["value": .string("<undefined>")]))
        first.send(message(2, storage(.string("set"), .string("settings"), .object(["theme": .string("dark"), "n": .number(3)]))))
        #expect(try await recorder.reply(2) == .object(["ok": .bool(true)]))
        first.send(message(3, storage(.string("set"), .string("list"), .array([.number(1), .null, .string("a")]))))
        _ = try await recorder.reply(3)
        first.send(message(4, storage(.string("copy"))))
        #expect(try await recorder.reply(4) == .object(["value": .object(["a": .number(1)])]))
        first.send(message(5, storage(.string("delete"), .string("o"))))
        #expect(try await recorder.reply(5) == .object(["deleted": .bool(true)]))
        first.send(message(6, storage(.string("delete"), .string("o"))))
        #expect(try await recorder.reply(6) == .object(["deleted": .bool(false)]))
        first.stop()

        // The file is whole, readable JSON in the data folder, and no temporary file is left.
        let file = ws.data.appending(path: "storage.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(saved?.keys.sorted() == ["list", "settings"])
        #expect(!FileManager.default.fileExists(atPath: ws.data.appending(path: "storage.json.tmp").path))

        // A new process (a restart of the plugin or of Singularity) finds the same values.
        let second = try makeProcess(ws)
        let again = Recorder()
        again.attach(second)
        try second.start()
        defer { second.stop() }
        second.send(message(1, storage(.string("get"), .string("settings"))))
        #expect(try await again.reply(1) == .object(["value": .object(["theme": .string("dark"), "n": .number(3)])]))
        second.send(message(2, storage(.string("keys"))))
        #expect(try await again.reply(2) == .object(["keys": .array([.string("settings"), .string("list")])]))
        second.send(message(3, storage(.string("clear"))))
        _ = try await again.reply(3)
        second.send(message(4, storage(.string("keys"))))
        #expect(try await again.reply(4) == .object(["keys": .array([])]))
    }

    @Test(.timeLimit(.minutes(1))) func storageRefusesBadValuesAndSurvivesABrokenFile() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        func storage(_ parts: JSONValue...) -> JSONValue { .object(["storage": .array(parts)]) }
        // A store someone (or a crash of an older version) left unreadable.
        try FileManager.default.createDirectory(at: ws.data, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: ws.data.appending(path: "storage.json"))

        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        // The broken file is set aside, said in the log, and the store works.
        process.send(message(1, storage(.string("keys"))))
        #expect(try await recorder.reply(1) == .object(["keys": .array([])]))
        let names = try FileManager.default.contentsOfDirectory(atPath: ws.data.path)
        #expect(names.contains { $0.hasPrefix("storage.unreadable-") })
        #expect(recorder.logLines.contains { $0.level == "error" && $0.message.contains("storage.json couldn't be read") })

        func error(_ id: Int) async throws -> String {
            guard case .object(let fields) = try await recorder.reply(id), case .string(let text)? = fields["storageError"] else {
                Issue.record("expected a storage error for \(id)")
                return ""
            }
            return text
        }
        process.send(message(2, storage(.string("bad"))))
        #expect(try await error(2).contains("must be JSON"))
        process.send(message(3, storage(.string("huge"))))
        #expect(try await error(3).contains("storage is full"))
        process.send(message(4, storage(.string("get"), .string(""))))
        #expect(try await error(4).contains("storage key"))
        // Nothing of the refused values was kept.
        process.send(message(5, storage(.string("keys"))))
        #expect(try await recorder.reply(5) == .object(["keys": .array([])]))

        // Fifty changes at once all land, and the file is whole afterwards.
        process.send(message(6, storage(.string("burst"))))
        #expect(try await recorder.reply(6) == .object(["keys": .number(50)]))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: ws.data.appending(path: "storage.json"))) as? [String: Any]
        #expect(saved?.count == 50)
    }

    @Test(.timeLimit(.minutes(1))) func repliesNoHandler() async throws {
        let ws = try makeWorkspace(background: #"console.log("no handler here");"#)
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        defer { ws.remove() }
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
        // The test waits for the first reply (Bun is up, SIGTERM is ignored) and for the "blocking" line
        // (the thread is stuck) before it stops the plugin. A fixed sleep here used to lose the race on
        // a busy Mac: SIGTERM reached Bun before the script ran and ended it with status 15.
        let ws = try makeWorkspace(background: #"""
            import { singularity } from "singularity";
            import { writeSync } from "node:fs";
            process.on("SIGTERM", () => {});
            let seen = 0;
            singularity.onPageMessage(() => {
              if (seen++ === 0) return "ready";
              writeSync(1, JSON.stringify({ kind: "log", level: "info", message: "blocking" }) + "\n");
              while (true) {}
            });
            """#)
        defer { ws.remove() }
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        process.send(message(1, .string("ready?")))
        _ = try await recorder.reply(1)
        process.send(message(2, .string("block")))
        _ = try await waitFor("the plugin to block") {
            recorder.logLines.contains { $0.message == "blocking" } ? true : nil
        }
        let stopped = ContinuousClock.now
        process.stop()
        let status = try await waitFor("exit") { recorder.exitStatuses.first }
        #expect(status == SIGKILL)
        #expect(ContinuousClock.now - stopped >= .seconds(1.5))
    }

    @Test(.timeLimit(.minutes(1))) func stopsAPluginThatDoesNotReadItsInput() async throws {
        // Blocks its only thread forever, so it never reads stdin.
        let ws = try makeWorkspace(background: "while (true) {}")
        defer { ws.remove() }
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        let big = message(1, .string(String(repeating: "x", count: 100_000)))
        let messageSize = try JSONEncoder().encode(big).count + 1
        var maxPending = 0
        // Up to 40 MB: far more than the 16 MB cap.
        for _ in 0..<400 where recorder.exitStatuses.isEmpty {
            process.send(big)
            maxPending = max(maxPending, process.pendingInputBytes)
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await waitFor("exit") { recorder.exitStatuses.first }
        #expect(maxPending <= PluginProcess.maxPendingInput + messageSize)
        #expect(maxPending > PluginProcess.maxPendingInput / 2, "the test should have filled the queue")
        #expect(recorder.logLines.contains { $0.level == "error" && $0.message == "plugin is not reading its input" })
        // Once the process is gone the queued messages are dropped.
        _ = try await waitFor("queue drained") { process.pendingInputBytes == 0 ? true : nil }
    }

    @Test(.timeLimit(.minutes(1))) func capsConcurrentCommands() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        // A slow stand-in for "echo", so the ten calls really overlap.
        let slow = ws.root.appending(path: "slow-echo")
        try "#!/bin/sh\nsleep 1\necho \"$@\"\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let process = try makeProcess(ws, commandPaths: ["echo": slow.path])
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("burst")))
        guard case .array(let results) = try await recorder.reply(1) else {
            Issue.record("expected an array of results")
            return
        }
        #expect(results.count == 10)   // every promise settled
        let tooMany = results.filter {
            $0 == .object(["status": .number(126), "stdout": .string(""),
                           "stderr": .string("too many commands running"), "timedOut": .bool(false)])
        }
        let ran = results.filter {
            $0 == .object(["status": .number(0), "stdout": .string("hello\n"), "stderr": .string(""), "timedOut": .bool(false)])
        }
        #expect(tooMany.count >= 6, Comment(rawValue: "\(results)"))
        #expect(ran.count >= 1 && ran.count <= 4, Comment(rawValue: "\(results)"))
        #expect(tooMany.count + ran.count == 10)
    }

    @Test(.timeLimit(.minutes(1))) func pluginBunfigAndEnvFilesAreIgnored() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        // Without --config/--no-env-file, Bun (started in the plugin folder) would run the preload
        // before host.ts and load the .env file.
        try #"preload = ["./preload.ts"]"#.write(to: ws.plugin.appending(path: "bunfig.toml"), atomically: true, encoding: .utf8)
        try #"process.stdout.write("PRELOAD\n");"#.write(to: ws.plugin.appending(path: "preload.ts"), atomically: true, encoding: .utf8)
        try "PLUGIN_ENV_LEAK=1\n".write(to: ws.plugin.appending(path: ".env"), atomically: true, encoding: .utf8)
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("env")))
        guard case .object(let fields) = try await recorder.reply(1), case .array(let keys)? = fields["keys"] else {
            Issue.record("unexpected env reply")
            return
        }
        #expect(!keys.contains(.string("PLUGIN_ENV_LEAK")))
        #expect(!recorder.logLines.contains { $0.message.contains("PRELOAD") }, Comment(rawValue: "\(recorder.logLines)"))
    }

    @Test(.timeLimit(.minutes(1))) func uncaughtErrorsAreLoggedAndThePluginKeepsRunning() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("reject")))
        process.send(message(2, .string("uncaught")))
        _ = try await recorder.reply(1)
        _ = try await recorder.reply(2)
        let logs = try await waitFor("both errors logged") { () -> [(level: String, message: String)]? in
            let errors = recorder.logLines.filter { $0.level == "error" }
            let both = errors.contains { $0.message.contains("forgotten rejection") }
                && errors.contains { $0.message.contains("thrown in a timer") }
            return both ? errors : nil
        }
        // One entry each, with the stack.
        #expect(logs.filter { $0.message.contains("forgotten rejection") }.count == 1, Comment(rawValue: "\(logs)"))
        #expect(logs.filter { $0.message.contains("thrown in a timer") }.count == 1, Comment(rawValue: "\(logs)"))
        #expect(logs.allSatisfy { $0.message.contains("background.ts") }, Comment(rawValue: "\(logs)"))
        // Still alive.
        process.send(message(3, .string("still here?")))
        #expect(try await recorder.reply(3) == .object(["echo": .string("still here?")]))
        #expect(recorder.exitStatuses.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func logMessagesAreCutAndLevelsMapped() async throws {
        // writeSync(1, …) bypasses host.ts's console redirection, like a plugin forging lines would.
        let ws = try makeWorkspace(background: #"""
            import { singularity } from "singularity";
            import { writeSync } from "node:fs";
            singularity.onPageMessage(() => {
              console.log("y".repeat(20000));
              writeSync(1, JSON.stringify({ kind: "log", level: "fatal", message: "odd level" }) + "\n");
              writeSync(1, "z".repeat(20000) + "\n");
              return "done";
            });
            """#)
        defer { ws.remove() }
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        defer { process.stop() }

        process.send(message(1, .string("go")))
        #expect(try await recorder.reply(1) == .string("done"))
        let logs = try await waitFor("three log lines") { () -> [(level: String, message: String)]? in
            let lines = recorder.logLines
            return lines.count >= 3 ? lines : nil
        }
        #expect(logs.contains { $0.level == "info" && $0.message == "odd level" })
        for long in logs where long.message.hasPrefix("y") || long.message.hasPrefix("z") {
            #expect(long.message.utf8.count <= PluginProcess.maxLogMessageBytes)
            #expect(long.message.hasSuffix("…"))
        }
        #expect(logs.filter { $0.message.hasPrefix("y") || $0.message.hasPrefix("z") }.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func terminateNowKillsAtOnce() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = try makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()
        process.send(message(1, .string("hi")))
        _ = try await recorder.reply(1)
        let started = ContinuousClock.now
        process.terminateNow()
        #expect(try await waitFor("exit") { recorder.exitStatuses.first } == SIGKILL)
        #expect(ContinuousClock.now - started < .seconds(1.5))
    }

    /// At app quit, a command the plugin started (outside the sandbox) is killed with it.
    @Test(.timeLimit(.minutes(1))) func terminateNowKillsRunningCommands() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        // A stand-in for "echo" that records its pid and then sleeps (exec keeps the same pid).
        let pidFile = ws.root.appending(path: "child.pid")
        let slow = ws.root.appending(path: "sleepy-echo")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let process = try makeProcess(ws, commandPaths: ["echo": slow.path])
        let recorder = Recorder()
        recorder.attach(process)
        try process.start()

        process.send(message(1, .string("run-op")))
        let pid = try await waitFor("the command's pid") { () -> Int32? in
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
            return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(kill(pid, 0) == 0)                       // the sleep is running
        #expect(process.commandChildren.count == 1)
        process.terminateNow()
        // Gone (killed and reaped): signal 0 to its pid fails with ESRCH.
        _ = try await waitFor("the command to end", timeout: .seconds(5)) { kill(pid, 0) != 0 ? true : nil }
        _ = try await waitFor("the list to empty", timeout: .seconds(5)) { process.commandChildren.count == 0 ? true : nil }
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
    private func supervise(_ clock: FakeClock, _ starts: Counter,
                           restartDelay: Duration = .zero) throws -> (PluginSupervisor, Workspace) {
        let ws = try makeWorkspace()
        let manifest = try PluginManifest.load(from: ws.plugin)
        let supervisor = PluginSupervisor(restartDelay: restartDelay, now: { clock.now }) {
            starts.increment()
            return PluginProcess(manifest: manifest, folder: ws.plugin, dataFolder: ws.data,
                                 runtime: bunPath, host: hostScript, commandPaths: [:])
        }
        return (supervisor, ws)
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
        let (supervisor, ws) = try supervise(clock, starts)
        defer { ws.remove() }
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
        let (supervisor, ws) = try supervise(clock, starts)
        defer { ws.remove() }
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
        let (supervisor, ws) = try supervise(clock, starts)
        defer { ws.remove() }
        supervisor.start()
        supervisor.stop()
        try await Task.sleep(for: .milliseconds(800))
        #expect(starts.value == 1)
        #expect(supervisor.state == .stopped)
    }

    @Test(.timeLimit(.minutes(1))) func startDuringAPendingRestartDoesNotResetTheCrashCount() async throws {
        let clock = FakeClock(), starts = Counter()
        let (supervisor, ws) = try supervise(clock, starts, restartDelay: .milliseconds(300))
        defer { ws.remove() }
        defer { supervisor.stop() }
        supervisor.start()
        for round in 1...4 {
            clock.advance(5)
            let exits = supervisor.recentLogs.filter { $0.message.hasPrefix("exited") }.count
            supervisor.send(message(99, .string("crash")))
            _ = try await waitFor("exit") {
                supervisor.recentLogs.filter { $0.message.hasPrefix("exited") }.count > exits ? true : nil
            }
            if round == 4 { break }
            // A restart is pending: start() must neither launch another process nor forget the crashes.
            supervisor.start()
            let replies = Replies()
            supervisor.onReply = { id, payload in replies.add(id, payload) }
            _ = try await waitFor("restarted plugin answers") { () -> Bool? in
                if replies.has(1) { return true }
                supervisor.send(message(1, .string("ping")))
                return nil
            }
        }
        _ = try await waitFor("give up") { supervisor.state == .crashedRepeatedly ? true : nil }
        #expect(starts.value == 4)
        // stop() then start() starts the count over.
        supervisor.stop()
        supervisor.start()
        #expect(supervisor.state == .running)
        #expect(starts.value == 5)
    }

    private struct Refused: Error {}

    @Test(.timeLimit(.minutes(1))) func aRefusingFactoryEndsAsFailedToStart() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let manifest = try PluginManifest.load(from: ws.plugin)
        let refuse = Counter(), starts = Counter()
        let supervisor = PluginSupervisor(restartDelay: .zero) {
            starts.increment()
            if refuse.value == 0 { throw Refused() }
            return PluginProcess(manifest: manifest, folder: ws.plugin, dataFolder: ws.data,
                                 runtime: bunPath, host: hostScript, commandPaths: [:])
        }
        defer { supervisor.stop() }
        supervisor.start()
        guard case .failedToStart = supervisor.state else { Issue.record("state \(supervisor.state)"); return }
        #expect(supervisor.recentLogs.contains { $0.message.hasPrefix("not started") })
        // Nothing pending: a later start() tries again.
        refuse.increment()
        supervisor.start()
        #expect(supervisor.state == .running)
        #expect(starts.value == 2)
    }

    @Test(.timeLimit(.minutes(1))) func terminateNowKillsWithoutRestart() async throws {
        let clock = FakeClock(), starts = Counter()
        let (supervisor, ws) = try supervise(clock, starts)
        defer { ws.remove() }
        supervisor.start()
        #expect(supervisor.state == .running)
        supervisor.terminateNow()
        #expect(supervisor.state == .stopped)
        try await Task.sleep(for: .milliseconds(500))
        #expect(starts.value == 1)
        #expect(supervisor.state == .stopped)
    }
}
