import Foundation
import Testing
@testable import SingularityCore

@Suite struct PluginTerminalsTests {
    private func manifest(_ perms: String) throws -> PluginManifest {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sing-term-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        let json = #"{"id":"x","name":"X","version":"1","description":"d","author":"a","background":"background.ts","permissions":{\#(perms)}}"#
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
        return try PluginManifest.load(from: dir)
    }

    @Test func decodesWithBrowser() throws {
        let m = try manifest(#""terminals":true,"browser":true,"programs":["x"]"#)
        #expect(m.permissions.terminals)
        #expect(try !manifest("").permissions.terminals)
    }

    @Test func needsBrowser() {
        #expect(throws: PluginError.terminalsNeedBrowser) { _ = try manifest(#""terminals":true,"programs":["x"]"#) }
        #expect(PluginError.terminalsNeedBrowser.userMessage == "it asks to see terminals but not to use the browser")
    }

    @Test func widens() {
        let old = PluginManifest.Permissions(browser: true)
        let new = PluginManifest.Permissions(browser: true, terminals: true)
        #expect(new.widens(old))
        #expect(!new.widens(new))
        #expect(!old.widens(new))
    }

    private func approval(perms: PluginManifest.Permissions, spaces: Set<UUID> = [], terminals: Set<UUID> = []) -> PluginApproval {
        PluginApproval(fingerprint: "f", permissions: perms, commandPaths: [:], enabledSpaces: spaces,
                       terminalSpaces: terminals, developmentMode: false, approvedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func approvalWithoutTerminalSpacesDecodesEmptyAndRoundTripsSorted() throws {
        let a = approval(perms: .init())
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        obj.removeValue(forKey: "terminalSpaces")
        let old = try JSONDecoder().decode(PluginApproval.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.terminalSpaces.isEmpty)

        let ids = (0..<4).map { _ in UUID() }
        let b = approval(perms: .init(), terminals: Set(ids))
        let enc = JSONEncoder()
        let first = try enc.encode(b)
        let back = try JSONDecoder().decode(PluginApproval.self, from: first)
        #expect(back.terminalSpaces == Set(ids))
        let list = (try JSONSerialization.jsonObject(with: first) as! [String: Any])["terminalSpaces"] as! [String]
        #expect(list == ids.map(\.uuidString).sorted())
    }

    @Test func terminalsAreOpenTruthTable() {
        let space = Space(name: "Work", slug: "work", colorHex: "#000000")
        let on = PluginManifest.Permissions(browser: true, terminals: true)
        let off = PluginManifest.Permissions(browser: true)
        func open(_ a: PluginApproval?, _ s: PluginStatus = .approved) -> Bool {
            PluginReach.terminalsAreOpen(space, approval: a, status: s)
        }
        #expect(open(approval(perms: on, spaces: [space.id], terminals: [space.id])))
        #expect(!open(approval(perms: on, spaces: [], terminals: [space.id])))      // Space off
        #expect(!open(approval(perms: on, spaces: [space.id], terminals: [])))      // switch off
        #expect(!open(approval(perms: off, spaces: [space.id], terminals: [space.id]))) // permission off
        #expect(!open(nil))
        #expect(!open(approval(perms: on, spaces: [space.id], terminals: [space.id]), .changed))
    }

    @Test func terminalSendAlwaysAsks() {
        let ctx = AgentActionContext(kind: .terminalSend, pageOrigin: "https://a.example", targetOrigin: nil)
        let allowed: Set<String> = ["https://a.example"]
        #expect(!AgentActionKind.terminalSend.isRead)
        #expect(AgentApprovalRules.decide(ctx, policy: .readOnly, allowedOrigins: allowed) == .deny(AgentApprovalRules.readOnlyReason))
        #expect(AgentApprovalRules.decide(ctx, policy: .ask, allowedOrigins: allowed) == .ask(siteOrigin: nil))
        #expect(AgentApprovalRules.decide(ctx, policy: .allowAll, allowedOrigins: allowed) == .ask(siteOrigin: nil))
    }

    @Test func toolNamesAndTexts() throws {
        let p = try #require(AgentToolName.parse("work.read_terminal"))
        #expect(p.slug == "work" && p.tool == "read_terminal")
        #expect(AgentToolName.terminals == "terminals")
        #expect(AgentToolName.terminalTools == ["read_terminal", "send_to_terminal", "answer_question"])
        #expect(AgentCaller.noTerminalSpaces(title: "Assistant")
                == "No Space lets Assistant see its terminals. The owner can switch that on in Settings → Plugins.")
        let desc = PermissionDescriptions.lines(for: .init(browser: true, terminals: true), commandPaths: [:])
        #expect(desc.contains("See the terminals of Spaces you switch on for it, read their screens, and send text to one after you approved the exact text"))
    }
}
