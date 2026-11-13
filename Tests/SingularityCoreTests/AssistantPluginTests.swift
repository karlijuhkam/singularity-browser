import Foundation
import Testing
@testable import SingularityCore

/// The repo's Assistant plugin (the build scripts ship this folder inside the app).
private let assistantFolder = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Plugins/assistant", directoryHint: .isDirectory)

@Suite struct AssistantPluginTests {
    @Test func manifestLoads() throws {
        let manifest = try PluginManifest.load(from: assistantFolder)
        #expect(manifest.id == "assistant")
        #expect(manifest.name == "Assistant")
        #expect(manifest.description == "A built-in helper you can chat with, running on your own Claude sign-in.")
        #expect(manifest.background == "background.ts")
        #expect(manifest.panel == .init(page: "panel.tsx", title: "Assistant"))
        #expect(manifest.page == nil)
        #expect(manifest.permissions.programs == ["claude"])
        #expect(manifest.permissions.programEnv == ["CLAUDE_CONFIG_DIR", "CLAUDE_AGENT_SDK_VERSION",
                                                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SDK_READS_SESSION_STATE"])
        #expect(manifest.permissions.commands.isEmpty && manifest.permissions.network.isEmpty)
        #expect(manifest.permissions.pageAdditions.isEmpty && manifest.permissions.fillForms.isEmpty)
    }

    /// package.json and bun.lock pass the same check as at approval: exact versions, a matching
    /// lock made without optional packages.
    @Test func packagesPassTheCheck() throws {
        let summary = try PluginPackages.check(folder: assistantFolder)
        #expect(summary.packages == [PluginPackage(name: "@anthropic-ai/claude-agent-sdk", version: "0.3.323"),
                                     PluginPackage(name: "preact", version: "11.2.0")])
        // The lock's 113 entries less the SDK's 8 optional platform packages: what
        // `bun install --omit=optional` put in node_modules when the lock was made.
        #expect(summary.lockedCount == 105)
    }

    @Test func approvalLines() throws {
        let review = try PluginReview.prepare(scan: PluginScan.scan(folder: assistantFolder)) { name in
            "/opt/bin/" + name
        }.get()
        #expect(review.missingCommands.isEmpty)
        #expect(review.permissionLines == [
            "Shows its own panel and tab",
            "Keeps /opt/bin/claude running and talks to it. This program is not sandboxed: it uses the internet and acts as you",
            "Passes these settings to it: CLAUDE_AGENT_SDK_VERSION, CLAUDE_CODE_ENTRYPOINT, "
                + "CLAUDE_CODE_SDK_READS_SESSION_STATE, CLAUDE_CONFIG_DIR",
            "Installs 2 packages from the npm registry (105 with the packages they use)",
            "Its background program never uses the internet; the programs it runs can",
        ])
    }
}
