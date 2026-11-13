import Foundation
import SingularityCore
import Testing
@testable import Singularity

/// Opt-in, never part of `scripts/test.sh`: the bundled Assistant plugin with the REAL `claude`,
/// on the owner's own Claude account, sending two short messages.
///
///     source scripts/env.sh && SINGULARITY_REAL_ASSISTANT=1 swift test --filter RealAssistantTests
///
/// What it does, as the app does it but with no window and no app:
/// - copies `Plugins/assistant` to `/private/tmp/sg-ra-<8 hex>/assistant` and installs its packages
///   there with the repository's Bun and the app's own install (`PluginPackages.install`: the same
///   Bun arguments, no optional packages, no install scripts). This needs the network.
/// - finds `claude` the way the approval sheet pins it (`CommandBroker.resolve` through the login
///   shell's PATH), and builds the program's environment with `ProgramEnvironment.make` from the
///   real home folder, user and login PATH, plus only the names the manifest lists in `programEnv`.
/// - runs `background.ts` under the real `PluginProcess` (Bun in the plugin sandbox) with
///   `programsAllowed: true`, sends `hello`, waits for `ready` with a billing value, sends
///   "Reply with the single word: pong", and expects at least one piece of the answer and `ready`
///   again, all within 60 s of the `hello`.
/// - then a second message in the same conversation that asks for the tool `alpha.ping` of a
///   fixture MCP server (`Fixtures/fixture-mcp-server.ts`, run with the repository's Bun, answers
///   `pong-alpha-7391`). The test answers the plugin's `singularity.browser.server()` request with
///   that server, in place of the app's `singularity-mcp`, so no app and no browser are involved.
///   It expects a tool line that ends `done` and `7391` in the answer. (The plugin's request for the
///   tab in front is answered with "none".)
///
/// It uses the owner's plan (a few cents of usage) and leaves one short session in Claude's own
/// folder (`~/.claude/projects/…`, named after the temporary data folder). A throwaway
/// `CLAUDE_CONFIG_DIR` can't be used: that folder would be signed out. The temporary folder is
/// removed afterwards.
private let realAssistantRequested = ProcessInfo.processInfo.environment["SINGULARITY_REAL_ASSISTANT"] == "1"

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostFolder = repoRoot.appending(path: "Resources/plugin-host", directoryHint: .isDirectory)
private let fixtureServer = repoRoot.appending(path: "Tests/SingularityAppTests/Fixtures/fixture-mcp-server.ts")

extension AppTests {
    @MainActor
    @Suite(.serialized, .enabled(if: realAssistantRequested, "opt-in: set SINGULARITY_REAL_ASSISTANT=1 (uses your real claude and your Claude plan)"))
    struct RealAssistantTests {
        @Test(.timeLimit(.minutes(5)))
        func twoMessagesWithTheRealClaude() async throws {
            guard FileManager.default.isExecutableFile(atPath: bunPath.path) else {
                Issue.record("Vendor/bun/bun is missing (run scripts/fetch-bun.sh)")
                return
            }
            // A short real path (the sandbox profile names real paths).
            let root = URL(filePath: "/private/tmp/sg-ra-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
            let files = FileManager.default
            try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: root) }
            let folder = root.appending(path: "assistant", directoryHint: .isDirectory)
            let data = root.appending(path: "data", directoryHint: .isDirectory)
            try files.copyItem(at: repoRoot.appending(path: "Plugins/assistant", directoryHint: .isDirectory), to: folder)

            // The packages, as approval installs them.
            let install = await PluginPackages.install(folder: folder, runtime: bunPath, hostFolder: hostFolder,
                                                       stagingRoot: root.appending(path: "staging", directoryHint: .isDirectory))
            print("real-assistant: \(install.message)")
            guard install.outcome == .installed else {
                Issue.record("installing the packages failed: \(install.message)\n\(install.output)")
                return
            }

            // The program, as the approval sheet pins it, and the environment the app gives it.
            let shell = LoginShell.path()
            let (claude, loginPath) = await Task.detached {
                (CommandBroker.resolve("claude", loginShell: shell), CommandBroker.loginPath(loginShell: shell))
            }.value
            guard let claude, let loginPath else {
                Issue.record("claude was not found on the login shell's PATH")
                return
            }
            print("real-assistant: claude is \(claude)")
            let manifest = try PluginManifest.load(from: folder)
            let allowed = manifest.permissions.programEnv
            let home = files.homeDirectoryForCurrentUser.path
            try PluginInstaller.makeDataFolder(data)
            let process = PluginProcess(
                manifest: manifest, folder: folder, dataFolder: data, runtime: bunPath,
                host: hostFolder.appending(path: "host.ts"), commandPaths: ["claude": claude],
                programsAllowed: true,
                programEnvironment: { requested in
                    ProgramEnvironment.make(home: home, user: NSUserName(), loginPath: loginPath,
                                            tmpdir: NSTemporaryDirectory(), appVersion: "real-assistant-test",
                                            requested: requested, allowed: allowed)
                })
            let seen = Seen()
            process.onReply = { id, payload in seen.reply(id, payload) }
            process.onPanelPost = { payload in seen.post(payload) }
            // The plugin asks for the tab in front (none here) and for the browser's tool server: the
            // fixture server, run with the repository's Bun.
            process.onFrontRequest = { [weak process] id in process?.send(.reply(requestID: id, payload: .null)) }
            process.onBrowserServerRequest = { [weak process] id in
                process?.send(.reply(requestID: id, payload: .object([
                    "command": .string(bunPath.path),
                    "args": .array([.string(fixtureServer.path)]),
                    "env": .object([:]),
                ])))
            }
            process.onLog = { level, message in print("real-assistant: log \(level): \(message)") }
            process.onExit = { _ in seen.exited() }
            try process.start()
            defer {
                // The program ends with the plugin; give both a moment before the folder goes.
                process.stop()
                let end = Date().addingTimeInterval(5)
                while !seen.hasExited && Date() < end { usleep(50_000) }
            }

            let deadline = ContinuousClock.now + .seconds(60)
            process.send(.panelMessage(requestID: 1, payload: .object(["type": .string("hello")])))
            _ = try await seen.waitForReply(1, until: deadline)

            // Ready, and it says how it bills.
            let ready = try await seen.waitForPost("ready", until: deadline) { post in
                Self.field(post, "type") == .string("state") && Self.field(post, "status") == .string("ready")
            }
            let billing = Self.field(ready, "billing")
            print("real-assistant: ready; billing \(billing.map { "\($0)" } ?? "none"), Claude \(Self.field(ready, "providerVersion").map { "\($0)" } ?? "?")")
            #expect(billing == .string("plan") || billing == .string("api"))
            if Self.field(ready, "billingNoticeSeen") == .bool(false) {
                // The page would show its billing notice first; the test reads it and says OK.
                process.send(.panelMessage(requestID: 2, payload: .object(["type": .string("billingSeen")])))
                _ = try await seen.waitForReply(2, until: deadline)
            }

            let postsBefore = seen.postCount
            process.send(.panelMessage(requestID: 3, payload: .object([
                "type": .string("send"), "text": .string("Reply with the single word: pong"),
            ])))
            let sent = try await seen.waitForReply(3, until: deadline)
            #expect(Self.field(sent, "status") == .string("answering"), "send was answered with \(sent)")

            // At least one piece of the answer, then ready again.
            _ = try await seen.waitFor("ready after the answer", until: deadline) { () -> Bool? in
                let posts = seen.posts.dropFirst(postsBefore)
                guard let delta = posts.firstIndex(where: { Self.field($0, "type") == .string("delta") }) else { return nil }
                let readyAgain = posts[delta...].contains {
                    Self.field($0, "type") == .string("state") && Self.field($0, "status") == .string("ready")
                }
                return readyAgain ? true : nil
            }
            let answer = seen.posts.dropFirst(postsBefore).compactMap { post -> String? in
                guard Self.field(post, "type") == .string("delta"), case .string(let text)? = Self.field(post, "text") else { return nil }
                return text
            }.joined()
            print("real-assistant: answer \(answer.debugDescription)")
            #expect(!answer.isEmpty)

            // The second message: a tool of the fixture server. The plugin's tool line must end
            // "done" and the answer must hold the number the tool returned.
            let postsBeforeTool = seen.postCount
            process.send(.panelMessage(requestID: 4, payload: .object([
                "type": .string("send"),
                "text": .string("Call the browser tool alpha_ping (alpha.ping) once, with no arguments, then tell me the exact text it returned."),
            ])))
            let toolSent = try await seen.waitForReply(4, until: deadline)
            #expect(Self.field(toolSent, "status") == .string("answering"), "send was answered with \(toolSent)")
            _ = try await seen.waitFor("ready after the tool answer", until: deadline) { () -> Bool? in
                let posts = seen.posts.dropFirst(postsBeforeTool)
                guard let first = posts.firstIndex(where: { Self.field($0, "type") == .string("delta") }) else { return nil }
                let readyAgain = posts[first...].contains {
                    Self.field($0, "type") == .string("state") && Self.field($0, "status") == .string("ready")
                }
                return readyAgain ? true : nil
            }
            let toolPosts = Array(seen.posts.dropFirst(postsBeforeTool))
            let toolAnswer = toolPosts.compactMap { post -> String? in
                guard Self.field(post, "type") == .string("delta"), case .string(let text)? = Self.field(post, "text") else { return nil }
                return text
            }.joined()
            print("real-assistant: tool answer \(toolAnswer.debugDescription)")
            #expect(toolAnswer.contains("7391"), "the answer should hold the tool's text: \(toolAnswer)")
            // The state posts carry the messages; some message has a tool line whose status is done.
            let doneLines = toolPosts.flatMap { post -> [String] in
                guard Self.field(post, "type") == .string("state"), case .array(let messages)? = Self.field(post, "messages") else { return [] }
                return messages.flatMap { message -> [String] in
                    guard case .array(let tools)? = Self.field(message, "tools") else { return [] }
                    return tools.compactMap { tool in
                        guard Self.field(tool, "status") == .string("done"), case .string(let text)? = Self.field(tool, "text") else { return nil }
                        return text
                    }
                }
            }
            print("real-assistant: tool lines done \(doneLines)")
            #expect(!doneLines.isEmpty, "no tool line ended done")
        }

        private static func field(_ value: JSONValue, _ name: String) -> JSONValue? {
            if case .object(let fields) = value { return fields[name] } else { return nil }
        }
    }
}

/// What the plugin process reports (from background threads), for the test to wait on.
private final class Seen: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var replies: [Int: JSONValue] = [:]
    private var _posts: [JSONValue] = []
    private var _exited = false

    func reply(_ id: Int, _ payload: JSONValue) { lock.withLock { replies[id] = payload } }
    func post(_ payload: JSONValue) {
        lock.withLock { _posts.append(payload) }
        // A state other than starting/ready/answering is a failure the page would show; say which.
        if case .object(let fields) = payload, fields["type"] == .string("state"), case .string(let status)? = fields["status"],
           !["starting", "ready", "answering"].contains(status) {
            print("real-assistant: status \(status), error \(fields["error"].map { "\($0)" } ?? "none")")
        }
    }

    func exited() { lock.withLock { _exited = true } }
    var hasExited: Bool { lock.withLock { _exited } }
    var posts: [JSONValue] { lock.withLock { _posts } }
    var postCount: Int { lock.withLock { _posts.count } }

    // The waits run on the main actor, as the test does, so their checks never cross threads.
    @MainActor
    func waitForReply(_ id: Int, until deadline: ContinuousClock.Instant) async throws -> JSONValue {
        try await waitFor("the answer to request \(id)", until: deadline) { self.lock.withLock { self.replies[id] } }
    }

    /// The first post that passes `check`.
    @MainActor
    func waitForPost(_ what: String, until deadline: ContinuousClock.Instant,
                     _ check: (JSONValue) -> Bool) async throws -> JSONValue {
        try await waitFor(what, until: deadline) { self.posts.first(where: check) }
    }

    /// Polls `value` until it returns something; records an issue and throws at the deadline.
    @MainActor
    func waitFor<T>(_ what: String, until deadline: ContinuousClock.Instant, _ value: () -> T?) async throws -> T {
        while ContinuousClock.now < deadline {
            if let found = value() { return found }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for \(what); the plugin posted: \(posts)")
        throw CancellationError()
    }
}
