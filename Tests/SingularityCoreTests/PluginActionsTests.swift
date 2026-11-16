import Foundation
import Testing
@testable import SingularityCore

/// The two small things a plugin may ask for (`openTerminals`, `notifications`): the manifest,
/// what counts as asking for more, the approval sheet's words, the wire message, and the rules.
@Suite struct PluginActionsTests {
    private func load(permissions: String = "{}", background: Bool = true) throws -> PluginManifest {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sing-act-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "t", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        var json = #"{"id":"t","name":"T","version":"1","description":"d","author":"a","permissions":\#(permissions)"#
        if background { json += #","background":"background.ts""# }
        json += "}"
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
        return try PluginManifest.load(from: dir)
    }

    // MARK: - The manifest

    @Test func theKeysAreOptionalAndRead() throws {
        let plain = try load()
        #expect(plain.permissions.openTerminals == [] && !plain.permissions.notifications)
        let full = try load(permissions: #"{"openTerminals":["herdr-bot"],"notifications":true,"commands":{"hc":["ls"]}}"#)
        #expect(full.permissions.openTerminals == ["herdr-bot"])
        #expect(full.permissions.notifications)
        #expect(full.permissions.pinnedNames == ["hc", "herdr-bot"])
    }

    @Test func refusedNamesForATerminal() {
        for name in ["bash", "python3", "sudo", "a b", "../x", ""] {
            #expect(throws: PluginError.refusedTerminalProgram(name)) {
                _ = try load(permissions: #"{"openTerminals":["\#(name)"]}"#)
            }
        }
        #expect(throws: PluginError.refusedTerminalProgram("a")) { _ = try load(permissions: #"{"openTerminals":["a","b","a"]}"#) }
        #expect(throws: PluginError.refusedTerminalProgram("e")) { _ = try load(permissions: #"{"openTerminals":["a","b","c","d","e"]}"#) }
        // Nothing would ask for the terminal without a background program.
        #expect(throws: PluginError.refusedTerminalProgram("a")) { _ = try load(permissions: #"{"openTerminals":["a"]}"#, background: false) }
        #expect(PluginError.refusedTerminalProgram("bash").userMessage == "it asks to open terminals that run “bash”, which plugins may not")
    }

    @Test func askingForMoreNeedsApprovalAgain() {
        typealias P = PluginManifest.Permissions
        #expect(P(openTerminals: ["a"]).widens(P()))
        #expect(P(openTerminals: ["a", "b"]).widens(P(openTerminals: ["a"])))
        #expect(!P(openTerminals: ["a"]).widens(P(openTerminals: ["a", "b"])))
        #expect(P(notifications: true).widens(P()))
        #expect(!P().widens(P(notifications: true)))
        #expect(!P(openTerminals: ["a"], notifications: true).widens(P(openTerminals: ["a"], notifications: true)))
    }

    @Test func anOldApprovalFileStillLoads() throws {
        // Written before these keys existed: both read as "not granted".
        let old = try JSONDecoder().decode(PluginManifest.Permissions.self, from: Data(#"{"commands":{"hc":["ls"]}}"#.utf8))
        #expect(old.openTerminals == [] && !old.notifications)
        let again = try JSONDecoder().decode(PluginManifest.Permissions.self,
                                             from: JSONEncoder().encode(PluginManifest.Permissions(openTerminals: ["a"], notifications: true)))
        #expect(again.openTerminals == ["a"] && again.notifications)
    }

    @Test func theApprovalSheetSaysSo() {
        let lines = PermissionDescriptions.lines(
            for: .init(openTerminals: ["herdr-bot"], notifications: true), commandPaths: ["herdr-bot": "/u/bin/herdr-bot"],
            packages: nil, hasPageScript: false, hasBackground: true, hasPanel: false)
        #expect(lines.contains("Opens terminal tabs that run /u/bin/herdr-bot with arguments it chooses. That program is not sandboxed: it uses the internet and acts as you"))
        #expect(lines.contains("Shows notifications under its name"))
        #expect(lines.contains("Its background program never uses the internet; the programs it runs can"))
    }

    @Test func theWireMessageRoundTrips() throws {
        let message = PluginWire.appRequest(requestID: 7, name: "openTerminal",
                                            payload: .object(["program": .string("herdr-bot"), "args": .array([.string("gwb")])]))
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(PluginWire.self, from: data) == message)
        let fromHost = #"{"kind":"appRequest","requestID":3,"name":"notify","payload":{"title":"a","body":"b"}}"#
        #expect(try JSONDecoder().decode(PluginWire.self, from: Data(fromHost.utf8))
            == .appRequest(requestID: 3, name: "notify", payload: .object(["title": .string("a"), "body": .string("b")])))
        let flags = PluginProcess.permissionFlags(.init(openTerminals: ["a"], notifications: true))
        #expect(flags.contains(#""openTerminals":true"#) && flags.contains(#""notifications":true"#))
        #expect(try JSONSerialization.jsonObject(with: Data(flags.utf8)) is [String: Any])
    }

    // MARK: - What may be typed

    @Test func onlyPlainWordsBecomeACommandLine() {
        #expect(PluginTerminalRules.commandLine(path: "/u/bin/herdr-bot", arguments: ["gwb", "--fresh"]) == "'/u/bin/herdr-bot' 'gwb' '--fresh'")
        #expect(PluginTerminalRules.commandLine(path: "/u/bin/herdr-bot", arguments: []) == "'/u/bin/herdr-bot'")
        // Every word is quoted: a plain word could be one of the owner's zsh aliases (`G` for
        // `| grep`), and zsh reads `=ls` as the path of ls.
        #expect(PluginTerminalRules.commandLine(path: "/u/bin/x", arguments: ["G", "=ls"]) == "'/u/bin/x' 'G' '=ls'")
        #expect(PluginTerminalRules.commandLine(path: "/u/bin/x", arguments: ["--topic", "a_b-1", "k=v", "a/b.c", "x@y", "1,2", "a:b", "+1"])
            == "'/u/bin/x' '--topic' 'a_b-1' 'k=v' 'a/b.c' 'x@y' '1,2' 'a:b' '+1'")
        for bad in ["a b", "a;b", "$(x)", "`x`", "a|b", "a&b", "a>b", "'", "\"", "a\nb", "", "~", "*", "a\\b", "ä", "#x", "!x", "(x)",
                    String(repeating: "a", count: 201)] {
            #expect(PluginTerminalRules.commandLine(path: "/u/bin/x", arguments: ["ok", bad]) == nil, "\(bad)")
        }
        #expect(PluginTerminalRules.commandLine(path: "/u/bin/x", arguments: Array(repeating: "a", count: 17)) == nil)
        // The pinned path is one shell word whatever is in it.
        #expect(PluginTerminalRules.commandLine(path: "/Users/a b/it's/x", arguments: ["y"]) == "'/Users/a b/it'\\''s/x' 'y'")
        #expect(PluginTerminalRules.commandLine(path: "relative/x", arguments: []) == nil)
        #expect(PluginTerminalRules.commandLine(path: "/a\nrm -rf", arguments: []) == nil)
        // A control character in the path would be a key in the shell's line editor.
        for key in ["\t", "\u{1b}", "\u{3}", "\u{f}", "\r", "\u{0}"] {
            #expect(PluginTerminalRules.commandLine(path: "/u/bin/x\(key)y", arguments: []) == nil)
        }
    }

    @Test func theLimits() {
        var limit = PluginRateLimit(limit: 3, window: 60, minimumGap: 2)
        let t0 = Date(timeIntervalSince1970: 1000)
        // (seconds after t0, allowed?) in order: too close, then three in a minute, then aged out.
        let steps: [(TimeInterval, Bool)] = [(0, true), (1, false), (2, true), (5, true), (10, false), (61, true)]
        for (after, expected) in steps {
            let allowed = limit.allow(now: t0.addingTimeInterval(after))
            #expect(allowed == expected, "at \(after) s")
        }
        #expect(PluginRateLimit.terminals.limit == 5 && PluginRateLimit.notifications.limit == 20)
    }

    @Test func aNoticeAlwaysSaysWhichPluginSpeaks() {
        let text = PluginNotice.text(pluginName: "Bots", title: "Pilot", body: "PLAT-9 waits\nfor you\u{1b}[31m")
        #expect(text?.title == "Plugin “Bots”")
        #expect(text?.body == "Pilot: PLAT-9 waits for you[31m")
        #expect(PluginNotice.text(pluginName: "Bots", title: "", body: "x")?.body == "x")
        #expect(PluginNotice.text(pluginName: "Bots", title: "only a title", body: "")?.body == "only a title")
        #expect(PluginNotice.text(pluginName: "Bots", title: " ", body: "\n") == nil)
        // A name chosen to look like the inbox, the app or a way out of the quotes stays inside them.
        #expect(PluginNotice.text(pluginName: "Claude Code · Work", title: "", body: "Wants to use Bash")?.title == "Plugin “Claude Code · Work”")
        #expect(PluginNotice.text(pluginName: "Singularity", title: "Update ready", body: "")?.title == "Plugin “Singularity”")
        #expect(PluginNotice.text(pluginName: "x” Singularity “y", title: "t", body: "")?.title == "Plugin “x' Singularity 'y”")
        #expect(PluginNotice.text(pluginName: "Bots", title: String(repeating: "t", count: 500), body: String(repeating: "b", count: 900))
            .map { $0.title == "Plugin “Bots”" && $0.body.count <= 382 } == true)
    }

    // MARK: - The real host (Bun under the sandbox)

    private static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let bun = repoRoot.appending(path: "Vendor/bun/bun")
    private static let hasBun = FileManager.default.isExecutableFile(atPath: bun.path)

    private final class Box<T>: @unchecked Sendable {   // behind `lock`
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.withLock { value } }
        func change(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
    }

    /// A background that asks for a terminal and a notification, with and without the
    /// permissions, against a stand-in for the app. What it asked and what it was told.
    private func roundTrip(permissions: String) async throws -> (asked: [String], answer: JSONValue) {
        let temp = FileManager.default.temporaryDirectory.appending(path: "sing-act-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        // The real path: the sandbox profile is written for it (/var is a link to /private/var).
        let root = URL(filePath: try PluginProcess.realPath(temp), directoryHint: .isDirectory)
        let plugin = root.appending(path: "t", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data(#"{"id":"t","name":"T","version":"1","description":"d","author":"a","background":"background.ts","permissions":\#(permissions)}"#.utf8)
            .write(to: plugin.appending(path: "plugin.json"))
        try Data("""
            import { singularity } from "singularity";
            singularity.onPageMessage(async () => ({
              open: await singularity.terminal.open("herdr-bot", ["gwb", "--fresh"]),
              notify: await singularity.notify("Pilot", "waits for you"),
            }));
            """.utf8).write(to: plugin.appending(path: "background.ts"))
        let process = PluginProcess(manifest: try PluginManifest.load(from: plugin), folder: plugin,
                                    dataFolder: root.appending(path: "data", directoryHint: .isDirectory),
                                    runtime: Self.bun, host: Self.repoRoot.appending(path: "Resources/plugin-host/host.ts"),
                                    commandPaths: ["herdr-bot": "/u/bin/herdr-bot"])
        let asked = Box<[String]>([])
        let reply = Box<JSONValue?>(nil)
        process.onAppRequest = { [weak process] id, name, payload in
            asked.change { $0.append("\(name) \(String(decoding: (try? JSONEncoder().encode(payload)) ?? Data(), as: UTF8.self))") }
            process?.send(.reply(requestID: id, payload: name == "notify"
                                 ? .object(["ok": .bool(false), "error": .string("too many notifications")])
                                 : .object(["ok": .bool(true)])))
        }
        process.onReply = { _, payload in reply.change { $0 = payload } }
        try process.start()
        defer { process.stop() }
        process.send(.pageMessage(requestID: 1, tabID: UUID(), frameHost: "", payload: .null))
        let deadline = ContinuousClock.now + .seconds(20)
        while reply.get() == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return (asked.get().sorted(), try #require(reply.get()))
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"), .timeLimit(.minutes(1)))
    func aBackgroundAsksTheAppAndGetsTheAnswer() async throws {
        let (asked, answer) = try await roundTrip(permissions: #"{"openTerminals":["herdr-bot"],"notifications":true}"#)
        #expect(asked.count == 2)
        #expect(asked.first?.hasPrefix("notify ") == true && asked.first?.contains("waits for you") == true)
        #expect(asked.last?.hasPrefix("openTerminal ") == true && asked.last?.contains("--fresh") == true)
        #expect(answer == .object(["open": .object(["ok": .bool(true)]),
                                   "notify": .object(["ok": .bool(false), "error": .string("too many notifications")])]))
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"), .timeLimit(.minutes(1)))
    func withoutThePermissionsTheHostDoesNotEvenAsk() async throws {
        let (asked, answer) = try await roundTrip(permissions: "{}")
        #expect(asked.isEmpty)
        #expect(answer == .object([
            "open": .object(["ok": .bool(false), "error": .string("needs the openTerminals permission")]),
            "notify": .object(["ok": .bool(false), "error": .string("needs the notifications permission")]),
        ]))
    }
}
