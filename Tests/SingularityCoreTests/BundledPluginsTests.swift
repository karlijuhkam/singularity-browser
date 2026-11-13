import Foundation
import Testing
@testable import SingularityCore

/// The repo's ready-made 1Password plugin (the build scripts ship this folder inside the app).
private let onePasswordFolder = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Plugins/1password", directoryHint: .isDirectory)

@Suite struct BundledPluginsTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "bundled-plugins-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `<root>/<folder>/plugin.json` with `json`.
    private func writePlugin(_ folder: String, in root: URL, json: String) throws {
        let dir = root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
    }

    private func manifest(id: String, name: String, description: String) -> String {
        """
        {"id": "\(id)", "name": "\(name)", "version": "0.1.0", "description": "\(description)",
         "author": "Test", "permissions": {"pageAdditions": [], "fillForms": [], "commands": {}, "network": []}}
        """
    }

    @Test func listsValidPluginsSortedByName() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // The folder "0-zebra" sorts before "1password", the name "Zebra" after "1Password": the
        // order shows which of the two the list goes by.
        try writePlugin("0-zebra", in: root, json: manifest(id: "0-zebra", name: "Zebra", description: "Stripes."))
        try FileManager.default.copyItem(at: onePasswordFolder, to: root.appending(path: "1password"))

        let plugins = BundledPlugins.list(in: root)

        #expect(plugins.map(\.id) == ["1password", "0-zebra"])
        let first = try #require(plugins.first)
        #expect(first.name == "1Password")
        #expect(first.summary == "Fill logins from 1Password, unlocked with Touch ID.")
        #expect(first.folder.standardizedFileURL == root.appending(path: "1password").standardizedFileURL)
        #expect(plugins[1].name == "Zebra")
        #expect(plugins[1].summary == "Stripes.")
    }

    @Test func skipsBrokenPluginsAndPlainFiles() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin("good", in: root, json: manifest(id: "good", name: "Good", description: "Works."))
        try writePlugin("broken", in: root, json: "{ not json")
        // Valid JSON, but the id does not match the folder: still skipped.
        try writePlugin("renamed", in: root, json: manifest(id: "other", name: "Other", description: "x"))
        try Data("hello".utf8).write(to: root.appending(path: "notes.txt"))

        #expect(BundledPlugins.list(in: root).map(\.id) == ["good"])
    }

    @Test func missingFolderListsNothing() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)")
        #expect(BundledPlugins.list(in: missing).isEmpty)
    }

    @Test func theAssistantIsListedWithItsPanelTitle() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = onePasswordFolder.deletingLastPathComponent()
        try FileManager.default.copyItem(at: onePasswordFolder, to: root.appending(path: "1password"))
        try FileManager.default.copyItem(at: repo.appending(path: "assistant"), to: root.appending(path: "assistant"))
        // A copy may carry packages someone installed by hand; the list doesn't need them.
        try? FileManager.default.removeItem(at: root.appending(path: "assistant/node_modules"))

        let plugins = BundledPlugins.list(in: root)
        #expect(plugins.map(\.id) == ["1password", "assistant"])
        #expect(plugins.map(\.panelTitle) == [nil, "Assistant"])
        #expect(BundledPlugins.offeredPanelTitle(plugins) == "Assistant")
        #expect(BundledPlugins.offeredPanelTitle(Array(plugins.prefix(1))) == nil)
        #expect(BundledPlugins.offeredPanelTitle([]) == nil)
    }

    @Test func notInstalledLeavesOutWhatIsInThePluginsFolder() {
        let folder = URL(fileURLWithPath: "/x")
        let bundled = [BundledPlugin(id: "1password", name: "1Password", summary: "", folder: folder),
                       BundledPlugin(id: "assistant", name: "Assistant", summary: "", folder: folder, panelTitle: "Assistant")]
        #expect(BundledPlugins.notInstalled(bundled, installedIDs: []).map(\.id) == ["1password", "assistant"])
        #expect(BundledPlugins.notInstalled(bundled, installedIDs: ["assistant", "mine"]).map(\.id) == ["1password"])
        #expect(BundledPlugins.notInstalled(bundled, installedIDs: ["assistant", "1password"]).isEmpty)
        #expect(BundledPlugins.notInstalled([], installedIDs: ["assistant"]).isEmpty)
    }

    @Test func folders() {
        let resources = URL(fileURLWithPath: "/Applications/Singularity.app/Contents/Resources")
        #expect(BundledPlugins.pluginsFolder(resources: resources).path
                == "/Applications/Singularity.app/Contents/Resources/Plugins")
        #expect(BundledPlugins.guideFolder(resources: resources).path
                == "/Applications/Singularity.app/Contents/Resources/plugin-guide")
    }

    @Test func authoringPrompt() {
        let guide = URL(fileURLWithPath: "/Applications/Singularity.app/Contents/Resources/plugin-guide")
        let plugins = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Singularity/plugins")
        #expect(BundledPlugins.authoringPrompt(guide: guide, pluginsDirectory: plugins)
                == "Read /Applications/Singularity.app/Contents/Resources/plugin-guide/AUTHORING.md "
                + "(a template is in /Applications/Singularity.app/Contents/Resources/plugin-guide/template), "
                + "then write a Singularity plugin in ~/Singularity/plugins/<id> that …")
    }
}
