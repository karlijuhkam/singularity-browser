import Foundation
import Testing
@testable import SingularityCore

/// The `ask` permission: what the home's Ask row hands to a plugin. The manifest rule, what counts
/// as asking for more, the wire message, the Space rule (`space: null` where the plugin may not
/// know the Space), the length limit, and which plugin gets it.
@Suite struct AskRulesTests {
    /// A plugin folder named `t` with background.ts and panel.html, and the given manifest pieces.
    private func load(permissions: String, panel: Bool) throws -> PluginManifest {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sing-ask-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "t", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        try Data("<p>hi</p>".utf8).write(to: dir.appending(path: "panel.html"))
        var json = #"{"id":"t","name":"T","version":"1","description":"d","author":"a","background":"background.ts","permissions":\#(permissions)"#
        if panel { json += #","panel":{"page":"panel.html","title":"Assistant"}"# }
        json += "}"
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
        return try PluginManifest.load(from: dir)
    }

    private func encoded(_ wire: PluginWire?) throws -> String {
        let wire = try #require(wire)
        return String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
    }

    // MARK: - The manifest

    @Test func manifestRefusesAskWithoutPanel() throws {
        #expect(throws: PluginError.askNeedsPanel) { _ = try load(permissions: #"{"ask":true}"#, panel: false) }
        #expect(PluginError.askNeedsPanel.userMessage == "it asks to receive questions but has no panel")
        let withPanel = try load(permissions: #"{"ask":true}"#, panel: true)
        #expect(withPanel.permissions.ask)
        #expect(try !load(permissions: "{}", panel: true).permissions.ask)
    }

    @Test func askIsAWidening() throws {
        typealias P = PluginManifest.Permissions
        #expect(P(ask: true).widens(P()))
        #expect(!P().widens(P(ask: true)))
        #expect(!P(ask: true).widens(P(ask: true)))
        // An approval written before the key existed reads as "not granted".
        let old = try JSONDecoder().decode(P.self, from: Data(#"{"frontTab":true}"#.utf8))
        #expect(!old.ask)
        let again = try JSONDecoder().decode(P.self, from: JSONEncoder().encode(P(ask: true)))
        #expect(again.ask)
    }

    @Test func theApprovalSheetSaysSo() {
        let lines = PermissionDescriptions.lines(
            for: .init(ask: true), commandPaths: [:], packages: nil,
            hasPageScript: false, hasBackground: true, hasPanel: true)
        #expect(lines.contains("Receives what you type into a new tab's Ask row"))
        let none = PermissionDescriptions.lines(
            for: .init(), commandPaths: [:], packages: nil,
            hasPageScript: false, hasBackground: true, hasPanel: true)
        #expect(!none.contains("Receives what you type into a new tab's Ask row"))
    }

    @Test func hostIsToldOfTheFlag() {
        #expect(PluginProcess.permissionFlags(.init(ask: true)).contains(#""ask":true"#))
        #expect(PluginProcess.permissionFlags(.init()).contains(#""ask":false"#))
    }

    // MARK: - The wire

    @Test func wireEncodesAsk() throws {
        let space = FrontTab.SpaceRef(slug: "work", name: "Work")
        let json = try encoded(AskRules.wireMessage(text: "what is this?", space: space))
        #expect(json.contains(#""kind":"ask""#))
        #expect(json.contains(#""text":"what is this?""#))
        #expect(json.contains(#""space":{"#))
        #expect(json.contains(#""slug":"work""#) && json.contains(#""name":"Work""#))
        // And back.
        let decoded = try JSONDecoder().decode(PluginWire.self, from: Data(json.utf8))
        #expect(decoded == .ask(text: "what is this?", space: .object(["slug": .string("work"), "name": .string("Work")])))
    }

    @Test func askSpaceIsNullWhenSpaceOff() throws {
        let space = Space(name: "Secret Plans", slug: "secret-plans", colorHex: "#5E81F4")
        let ref = AskRules.spaceRef(space, enabledSpaces: [UUID()])
        #expect(ref == nil)
        let json = try encoded(AskRules.wireMessage(text: "hello", space: ref))
        #expect(json.contains(#""space":null"#))
        #expect(!json.contains("secret") && !json.contains("Secret"))
        #expect(!json.contains(space.id.uuidString) && !json.contains(space.id.uuidString.lowercased()))
        // Switched on, it is named.
        #expect(AskRules.spaceRef(space, enabledSpaces: [space.id]) == .init(slug: "secret-plans", name: "Secret Plans"))
    }

    @Test func askRefusesOverMaxLength() throws {
        #expect(AskRules.maxLength == 20_000)
        #expect(AskRules.wireMessage(text: String(repeating: "a", count: 20_000), space: nil) != nil)
        #expect(AskRules.wireMessage(text: String(repeating: "a", count: 20_001), space: nil) == nil)
        #expect(AskRules.wireMessage(text: "", space: nil) == nil)
        #expect(AskRules.wireMessage(text: "  \n\t ", space: nil) == nil)
    }

    // MARK: - Which plugin

    @Test func targetPrefersTheToggledPlugin() {
        let candidates: [(id: String, hasAsk: Bool, approved: Bool)] = [
            ("a", true, true), ("b", true, true),
        ]
        #expect(AskRules.target(toggle: "b", candidates: candidates) == "b")
        #expect(AskRules.target(toggle: "a", candidates: candidates) == "a")
    }

    @Test func targetFallsBackToFirstApprovedWithAsk() {
        let candidates: [(id: String, hasAsk: Bool, approved: Bool)] = [
            ("toggled", false, true), ("unapproved", true, false), ("plain", false, true), ("asker", true, true), ("later", true, true),
        ]
        #expect(AskRules.target(toggle: "toggled", candidates: candidates) == "asker")
        #expect(AskRules.target(toggle: "unapproved", candidates: candidates) == "asker")
        #expect(AskRules.target(toggle: nil, candidates: candidates) == "asker")
        #expect(AskRules.target(toggle: nil, candidates: [("x", false, true), ("y", true, false)]) == nil)
        #expect(AskRules.target(toggle: nil, candidates: []) == nil)
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

    /// A background with a panel that registers `onAsk` (when it may) and posts what it got to its
    /// panel; the asks are sent by a stand-in for the app. Returns the panel posts in order.
    private func hostPosts(permissions: String, asks: [PluginWire], expecting count: Int) async throws -> [JSONValue] {
        let temp = FileManager.default.temporaryDirectory.appending(path: "sing-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = URL(filePath: try PluginProcess.realPath(temp), directoryHint: .isDirectory)
        let plugin = root.appending(path: "t", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data(#"{"id":"t","name":"T","version":"1","description":"d","author":"a","background":"background.ts","panel":{"page":"panel.html","title":"T"},"permissions":\#(permissions)}"#.utf8)
            .write(to: plugin.appending(path: "plugin.json"))
        try Data("<p>hi</p>".utf8).write(to: plugin.appending(path: "panel.html"))
        try Data("""
            import { singularity } from "singularity";
            try {
              singularity.onAsk((ask) => singularity.panel.post({ got: ask }));
              singularity.panel.post({ registered: true });
            } catch (error) {
              singularity.panel.post({ refused: String(error.message) });
            }
            """.utf8).write(to: plugin.appending(path: "background.ts"))
        let process = PluginProcess(manifest: try PluginManifest.load(from: plugin), folder: plugin,
                                    dataFolder: root.appending(path: "data", directoryHint: .isDirectory),
                                    runtime: Self.bun, host: Self.repoRoot.appending(path: "Resources/plugin-host/host.ts"),
                                    commandPaths: [:])
        let posts = Box<[JSONValue]>([])
        process.onPanelPost = { payload in posts.change { $0.append(payload) } }
        try process.start()
        defer { process.stop() }
        for ask in asks { process.send(ask) }
        let deadline = ContinuousClock.now + .seconds(20)
        while posts.get().count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // A little longer, so a post that should not come has the chance to.
        try await Task.sleep(for: .milliseconds(300))
        return posts.get()
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"), .timeLimit(.minutes(1)))
    func theHostHandsAnAskToTheHandler() async throws {
        let named = try #require(AskRules.wireMessage(text: "what is this?", space: .init(slug: "work", name: "Work")))
        let unnamed = try #require(AskRules.wireMessage(text: "and here?", space: nil))
        let posts = try await hostPosts(permissions: #"{"ask":true}"#, asks: [named, unnamed], expecting: 3)
        #expect(posts.contains(.object(["registered": .bool(true)])))
        #expect(posts.contains(.object(["got": .object(["text": .string("what is this?"),
                                                        "space": .object(["slug": .string("work"), "name": .string("Work")])])])))
        #expect(posts.contains(.object(["got": .object(["text": .string("and here?"), "space": .null])])))
        #expect(posts.count == 3)
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"), .timeLimit(.minutes(1)))
    func withoutThePermissionOnAskThrowsAndAsksAreDropped() async throws {
        let ask = try #require(AskRules.wireMessage(text: "hello", space: nil))
        let posts = try await hostPosts(permissions: "{}", asks: [ask], expecting: 1)
        #expect(posts == [.object(["refused": .string("needs the ask permission")])])
    }
}
