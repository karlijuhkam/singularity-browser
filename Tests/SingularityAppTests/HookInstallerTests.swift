import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// `HookInstaller`: the file I/O behind Settings → Agents → "Show questions in the inbox".
/// Every test uses its own temporary folder and a fake helper there; none ever builds
/// `HookInstaller()` with the default file (that would be the owner's real ~/.claude/settings.json).
@MainActor
@Suite(.serialized) struct HookInstallerTests {
    struct Fixture {
        let root: URL
        let file: URL          // <root>/.claude/settings.json (folder not created)
        let helper: String     // <root>/Singularity.app/Contents/MacOS/singularity-hook (executable)
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(filePath: "/private/tmp/sg-hook-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let macOS = root.appending(path: "Singularity.app/Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let helper = macOS.appending(path: "singularity-hook")
        #expect(FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8),
                                               attributes: [.posixPermissions: 0o755]))
        return Fixture(root: root, file: root.appending(path: ".claude/settings.json"), helper: helper.path)
    }

    private func installer(_ f: Fixture, helper: String? = nil) -> HookInstaller {
        HookInstaller(settingsFile: f.file, helper: helper ?? f.helper)
    }

    private func write(_ text: String, to f: Fixture, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: f.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: f.file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.file.path)
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func object(_ url: URL) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    @Test func statusOfAMissingFileCreatesNothing() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(installer(f).status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: f.file.deletingLastPathComponent().path))
    }

    @Test func installOnAMissingFileCreatesItPrivately() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installer = installer(f)
        try installer.install()
        #expect(installer.status() == .installed)
        #expect(try mode(f.file) == 0o600)
        let hooks = try #require(try object(f.file)["hooks"] as? NSDictionary)
        #expect(Set(hooks.allKeys as? [String] ?? []) == ["PreToolUse", "PermissionRequest", "Stop"])
        // The timeout is the one shared constant.
        let pre = try #require((hooks["PreToolUse"] as? [NSDictionary])?.first?["hooks"] as? [NSDictionary])
        #expect(pre.first?["timeout"] as? Int == ClaudeHookSettings.hookTimeoutSeconds)
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.file.deletingLastPathComponent().path) == ["settings.json"])
    }

    @Test func removeKeepsEverythingElse() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try write("""
        {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other-tool stop"}]}]}}
        """, to: f)
        let installer = installer(f)
        try installer.install()
        #expect(installer.status() == .installed)
        try installer.remove()
        #expect(installer.status() == .notInstalled)
        let out = try object(f.file)
        #expect(out["model"] as? String == "opus")
        let stop = try #require((out["hooks"] as? NSDictionary)?["Stop"] as? [NSDictionary])
        #expect(stop.count == 1)
        #expect((stop[0]["hooks"] as? [NSDictionary])?.first?["command"] as? String == "other-tool stop")
        #expect((out["hooks"] as? NSDictionary)?["PreToolUse"] == nil)
    }

    @Test func removeOnAMissingFileCreatesNothing() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try installer(f).remove()
        #expect(!FileManager.default.fileExists(atPath: f.file.deletingLastPathComponent().path))
    }

    @Test func notJSONIsLeftAlone() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try write("not json", to: f)
        let before = try Data(contentsOf: f.file)
        let installer = installer(f)
        #expect(installer.status() == .unreadable)
        #expect(throws: HookInstaller.Failure.unreadable) { try installer.install() }
        #expect(throws: HookInstaller.Failure.unreadable) { try installer.remove() }
        #expect(try Data(contentsOf: f.file) == before)
    }

    @Test func notUTF8IsLeftAlone() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = Data([0x7B, 0x22, 0xFF, 0xFE, 0x22, 0x3A, 0x31, 0x7D])   // {"<FF FE>":1}
        try before.write(to: f.file)
        let installer = installer(f)
        #expect(installer.status() == .unreadable)
        #expect(throws: HookInstaller.Failure.unreadable) { try installer.install() }
        #expect(throws: HookInstaller.Failure.unreadable) { try installer.remove() }
        #expect(try Data(contentsOf: f.file) == before)
    }

    @Test func aSymlinkIsWrittenThrough() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // A dotfile manager keeps the real file elsewhere and links to it (here: relative link).
        let dotfiles = f.root.appending(path: "dotfiles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appending(path: "claude-settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try FileManager.default.createDirectory(at: f.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.file.path, withDestinationPath: "../dotfiles/claude-settings.json")

        let installer = installer(f)
        try installer.install()
        #expect(installer.status() == .installed)
        // Still a link, to the same place; the target holds the hooks and kept its mode.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.file.path) == "../dotfiles/claude-settings.json")
        #expect(try object(target)["hooks"] != nil)
        #expect(try object(target)["model"] as? String == "opus")
        #expect(try mode(target) == 0o640)

        try installer.remove()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.file.path) == "../dotfiles/claude-settings.json")
        #expect(try object(target)["hooks"] == nil)
    }

    @Test func permissionsArePreserved() throws {
        for wanted in [0o644, 0o600, 0o640] {
            let f = try makeFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try write("{}", to: f, mode: wanted)
            try installer(f).install()
            #expect(try mode(f.file) == wanted)
            try installer(f).remove()
            #expect(try mode(f.file) == wanted)
        }
    }

    @Test func installWhenInstalledDoesNotRewrite() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installer = installer(f)
        try installer.install()
        let inode = try FileManager.default.attributesOfItem(atPath: f.file.path)[.systemFileNumber] as? Int
        try installer.install()
        #expect(try FileManager.default.attributesOfItem(atPath: f.file.path)[.systemFileNumber] as? Int == inode)
    }

    @Test func updateRepointsAnotherCopy() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let other = "/Volumes/Old/Singularity.app/Contents/MacOS/singularity-hook"
        try write(try ClaudeHookSettings.install(settingsText: nil, helper: other, timeoutSeconds: 3600), to: f)
        let installer = installer(f)
        #expect(installer.status() == .otherCopy(other))
        try installer.install()
        #expect(installer.status() == .installed)
    }

    @Test func aStaleInstallIsRepaired() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try write(try ClaudeHookSettings.install(settingsText: nil, helper: f.helper, timeoutSeconds: 20), to: f)
        let installer = installer(f)
        #expect(installer.status() == .notInstalled)
        try installer.install()
        #expect(installer.status() == .installed)
    }

    @Test func noHelperNoInstall() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let missing = f.root.appending(path: "nowhere/singularity-hook").path
        let installer = installer(f, helper: missing)
        #expect(installer.rowState() == .helperMissing)
        #expect(throws: HookInstaller.Failure.helperMissing) { try installer.install() }
        #expect(!FileManager.default.fileExists(atPath: f.file.deletingLastPathComponent().path))
    }

    @Test func rowStateFollowsTheHelperAndTheFile() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(installer(f).rowState() == .status(.notInstalled))
        let translocated = "/private/var/folders/x/AppTranslocation/ABC/d/Singularity.app/Contents/MacOS/singularity-hook"
        #expect(installer(f, helper: translocated).rowState() == .translocated)
        try installer(f).install()
        #expect(installer(f).rowState() == .status(.installed))
    }
}
}
