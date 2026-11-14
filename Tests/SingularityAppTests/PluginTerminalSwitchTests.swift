import Foundation
import Testing
@testable import Singularity
import SingularityCore

/// A data folder with one plugin, "termfix", whose manifest has `browser`, `programs: ["prog"]`
/// and (unless `terminals: false`) `terminals`. Nothing ever runs: the approval written by
/// `approve(enabledSpaces:)` pins `prog` at a path that doesn't exist, so a plugin switched on in
/// a Space is "blocked" (approved, but not started), and with no Space on it is "switched off".
private struct TerminalSwitchWorkspace {
    static let id = "termfix"
    let root: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }

    init(terminals: Bool = true) throws {
        root = URL(filePath: "/private/tmp/sg-ts-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: plugin.appending(path: path)) }
        let permissions = terminals
            ? #""browser": true, "terminals": true, "programs": ["prog"]"#
            : #""browser": true, "programs": ["prog"]"#
        try write("plugin.json", """
            {"id": "\(Self.id)", "name": "Terminal Fixture", "version": "1.0.0", "description": "A test plugin.",
             "author": "Tests", "background": "background.ts", "permissions": {\(permissions)}}
            """)
        try write("background.ts", "export {};\n")
    }

    private struct NotReady: Error, CustomStringConvertible { let description: String }

    /// Approved as it is now, with `prog` pinned at a path that doesn't exist.
    func approve(enabledSpaces: Set<UUID>, terminalSpaces: Set<UUID> = []) throws {
        let scan = PluginScan.scan(folder: plugin)
        guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
            throw NotReady(description: "the fixture plugin doesn't scan: \(scan.manifest)")
        }
        let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                      commandPaths: ["prog": root.appending(path: "no-such-prog").path],
                                      enabledSpaces: enabledSpaces, terminalSpaces: terminalSpaces,
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
    }

    /// What is saved on disk now.
    var saved: PluginApproval? { PluginStateStore(file: paths.pluginStateFile).load()[Self.id] }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

extension AppTests {
/// The per-Space Terminals switch of a plugin with `terminals`: `PluginManager.setTerminalsEnabled`,
/// how it counts only while the Space itself is on (`terminalsAreOpen`), what tells the rest of
/// the app it went off, and what approval stores. No program, no Bun, no window.
@MainActor
@Suite(.serialized) struct PluginTerminalSwitchTests {
    private let id = TerminalSwitchWorkspace.id
    private let spaceA = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
    private let spaceB = Space(name: "Home", slug: "home", colorHex: "#E0AF68")

    /// A manager on the workspace (a runtime that doesn't exist, programs refused as in a test
    /// copy: nothing may start), once the plugin is scanned (and, with `approved`, shows as approved).
    private func makeManager(_ ws: TerminalSwitchWorkspace, approved: Bool = true) async throws -> PluginManager {
        MainRunLoopGuard.start
        let manager = PluginManager(paths: ws.paths, runtime: ws.root.appending(path: "no-bun"),
                                    host: ws.root.appending(path: "no-host.ts"),
                                    programs: .live(environment: ["SINGULARITY_HOME": ws.root.path],
                                                    loginPath: { "/usr/bin:/bin" }))
        manager.start()
        try await waitUntil("the plugin to be scanned") {
            approved ? manager.plugin(id)?.status == .approved : manager.plugin(id) != nil
        }
        return manager
    }

    private func tearDown(_ manager: PluginManager, _ ws: TerminalSwitchWorkspace) {
        manager.terminateAll()
        ws.remove()
    }

    @Test func theSwitchIsSavedAndReadBack() async throws {
        let ws = try TerminalSwitchWorkspace()
        try ws.approve(enabledSpaces: [spaceA.id, spaceB.id])
        let manager = try await makeManager(ws)
        defer { tearDown(manager, ws) }

        manager.setTerminalsEnabled(id, space: spaceA.id, true)
        #expect(manager.plugin(id)?.approval?.terminalSpaces == [spaceA.id])
        #expect(ws.saved?.terminalSpaces == [spaceA.id])
        #expect(manager.terminalsAreOpen(id, space: spaceA))
        #expect(!manager.terminalsAreOpen(id, space: spaceB))

        // A new manager (the next launch) reads it back.
        let again = try await makeManager(ws)
        defer { again.terminateAll() }
        #expect(again.plugin(id)?.approval?.terminalSpaces == [spaceA.id])
        #expect(again.terminalsAreOpen(id, space: spaceA))

        manager.setTerminalsEnabled(id, space: spaceA.id, false)
        #expect(manager.plugin(id)?.approval?.terminalSpaces == [])
        #expect(ws.saved?.terminalSpaces == [])
        #expect(!manager.terminalsAreOpen(id, space: spaceA))
        // The Space switch itself is untouched.
        #expect(ws.saved?.enabledSpaces == [spaceA.id, spaceB.id])
    }

    @Test func theSwitchCountsOnlyWhileTheSpaceIsOn() async throws {
        let ws = try TerminalSwitchWorkspace()
        try ws.approve(enabledSpaces: [spaceA.id], terminalSpaces: [spaceA.id])
        let manager = try await makeManager(ws)
        defer { tearDown(manager, ws) }
        #expect(manager.terminalsAreOpen(id, space: spaceA))

        manager.setEnabled(id, space: spaceA.id, false)
        #expect(!manager.terminalsAreOpen(id, space: spaceA))
        // The stored value is kept: it counts again once the Space is back on.
        #expect(ws.saved?.terminalSpaces == [spaceA.id])

        manager.setEnabled(id, space: spaceA.id, true)
        #expect(manager.terminalsAreOpen(id, space: spaceA))
    }

    @Test func goingOffIsReportedBothWays() async throws {
        let ws = try TerminalSwitchWorkspace()
        try ws.approve(enabledSpaces: [spaceA.id, spaceB.id])
        let manager = try await makeManager(ws)
        defer { tearDown(manager, ws) }
        var off: [String] = []
        var changes = 0
        manager.onTerminalsSwitchedOff = { plugin, space in off.append("\(plugin) \(space)") }
        manager.onSpacesChanged = { changes += 1 }

        manager.setTerminalsEnabled(id, space: spaceA.id, true)
        #expect(off.isEmpty)
        #expect(changes == 1)

        // 1. The Terminals switch itself.
        manager.setTerminalsEnabled(id, space: spaceA.id, false)
        #expect(off == ["\(id) \(spaceA.id)"])
        #expect(changes == 2)

        // 2. The Space switch, while its Terminals switch is on.
        manager.setTerminalsEnabled(id, space: spaceA.id, true)
        off = []
        manager.setEnabled(id, space: spaceA.id, false)
        #expect(off == ["\(id) \(spaceA.id)"])

        // A Space whose Terminals switch is off: nothing about terminals to report.
        off = []
        manager.setEnabled(id, space: spaceB.id, false)
        #expect(off.isEmpty)
    }

    @Test func aRemovedSpaceLeavesBothLists() async throws {
        let ws = try TerminalSwitchWorkspace()
        try ws.approve(enabledSpaces: [spaceA.id, spaceB.id], terminalSpaces: [spaceA.id, spaceB.id])
        let manager = try await makeManager(ws)
        defer { tearDown(manager, ws) }

        manager.spaceRemoved(spaceA.id)
        #expect(ws.saved?.enabledSpaces == [spaceB.id])
        #expect(ws.saved?.terminalSpaces == [spaceB.id])
        #expect(manager.plugin(id)?.approval?.terminalSpaces == [spaceB.id])

        // A Space only on the Terminals list (its Space switch went off earlier) leaves it too.
        manager.setEnabled(id, space: spaceB.id, false)
        #expect(ws.saved?.terminalSpaces == [spaceB.id])
        manager.spaceRemoved(spaceB.id)
        #expect(ws.saved?.terminalSpaces == [])
    }

    @Test func aPluginWithoutTerminalsIgnoresTheSwitch() async throws {
        let ws = try TerminalSwitchWorkspace(terminals: false)
        try ws.approve(enabledSpaces: [spaceA.id])
        let manager = try await makeManager(ws)
        defer { tearDown(manager, ws) }
        var calls = 0
        manager.onSpacesChanged = { calls += 1 }
        manager.onTerminalsSwitchedOff = { _, _ in calls += 1 }

        manager.setTerminalsEnabled(id, space: spaceA.id, true)
        manager.setTerminalsEnabled(id, space: spaceA.id, false)
        #expect(calls == 0)
        #expect(ws.saved?.terminalSpaces == [])
        #expect(!manager.terminalsAreOpen(id, space: spaceA))
    }

    @Test func approvalStoresTheTerminalsSwitches() async throws {
        let ws = try TerminalSwitchWorkspace()
        let program = ws.root.appending(path: "prog")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let manager = try await makeManager(ws, approved: false)
        defer { tearDown(manager, ws) }

        // `resolve` stands in for the login shell (a test never starts one).
        let review = try await manager.prepareReview(id) { _ in program.path }.get()
        // No Space on, so nothing starts after the approval.
        try await manager.approve(id, expectedFingerprint: review.fingerprint, enabledSpaces: [],
                                  terminalSpaces: [spaceA.id], developmentMode: false)
        #expect(ws.saved?.terminalSpaces == [spaceA.id])
        #expect(manager.plugin(id)?.approval?.terminalSpaces == [spaceA.id])
    }

    /// What the approval sheet hands to `approve`: only Spaces that exist; a Terminals switch only
    /// where its Space is ticked (it is shown unticked otherwise); none for a plugin without
    /// `terminals`, and none at all when the Space switches are hidden.
    @Test func theSheetPassesOnlyWhatItShows() throws {
        let gone = UUID()
        let existing = [spaceA.id, spaceB.id]
        let (enabled, terminals) = PluginApprovalSheet.chosenSpaces(
            enabled: [spaceA.id, gone], terminals: [spaceA.id, spaceB.id, gone],
            showsSpaceSwitches: true, hasTerminals: true, existing: existing)
        #expect(enabled == [spaceA.id])
        #expect(terminals == [spaceA.id])

        let noTerminals = PluginApprovalSheet.chosenSpaces(
            enabled: [spaceA.id], terminals: [spaceA.id], showsSpaceSwitches: true, hasTerminals: false, existing: existing)
        #expect(noTerminals.enabled == [spaceA.id])
        #expect(noTerminals.terminals == [])

        let hidden = PluginApprovalSheet.chosenSpaces(
            enabled: [spaceA.id], terminals: [spaceA.id], showsSpaceSwitches: false, hasTerminals: true, existing: existing)
        #expect(hidden.enabled == [])
        #expect(hidden.terminals == [])
    }
}
}
