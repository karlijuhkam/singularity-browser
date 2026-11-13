import Foundation
import Testing
@testable import SingularityCore

@Suite struct BundledPluginUpdateTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "plugin-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makePlugin(_ id: String, version: String, in root: URL, files: [String: String] = [:]) throws -> URL {
        let dir = root.appending(path: id, directoryHint: .isDirectory)
        try write("""
            {"id": "\(id)", "name": "Test", "version": "\(version)", "description": "d", "author": "A",
             "permissions": {"pageAdditions": [], "fillForms": [], "commands": {}, "network": []}}
            """, "plugin.json", in: dir)
        for (path, text) in files { try write(text, path, in: dir) }
        return dir
    }

    private func shipped(version: String = "2.0.0") -> BundledPlugin {
        BundledPlugin(id: "p", name: "P", summary: "", folder: URL(filePath: "/x"), version: version)
    }

    // MARK: offer

    @Test func offersADifferentVersion() {
        let offer = BundledPlugins.updateOffer(installedID: "p", installedVersion: "1.0.0", developmentMode: false,
                                               filesMatchApproval: true, bundled: [shipped()])
        #expect(offer?.version == "2.0.0")
    }

    @Test func offersNothingInTheOtherCases() {
        func offer(id: String = "p", version: String = "1.0.0", dev: Bool = false, match: Bool = true) -> BundledPlugin? {
            BundledPlugins.updateOffer(installedID: id, installedVersion: version, developmentMode: dev,
                                       filesMatchApproval: match, bundled: [shipped()])
        }
        #expect(offer(version: "2.0.0") == nil)   // same version
        #expect(offer(dev: true) == nil)          // development mode
        #expect(offer(match: false) == nil)       // edited files
        #expect(offer(id: "other") == nil)        // not shipped
    }

    @Test func listCarriesTheManifestVersion() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePlugin("p", version: "3.1.4", in: root)
        #expect(BundledPlugins.list(in: root).first?.version == "3.1.4")
    }

    // MARK: update

    @Test func updateReplacesFilesAndKeepsData() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: "plugins")
        let shippedRoot = root.appending(path: "shipped")
        _ = try makePlugin("p", version: "1.0.0", in: plugins, files: ["old.ts": "old", "keep.ts": "v1"])
        _ = try makePlugin("p", version: "2.0.0", in: shippedRoot, files: ["new.ts": "new", "keep.ts": "v2"])
        try write("secret", "plugins-data/p/storage.json", in: root)

        try PluginInstaller.update(id: "p", from: shippedRoot.appending(path: "p"), pluginsDirectory: plugins)

        let dest = plugins.appending(path: "p")
        #expect(!FileManager.default.fileExists(atPath: dest.appending(path: "old.ts").path))
        #expect(try String(contentsOf: dest.appending(path: "new.ts"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: dest.appending(path: "keep.ts"), encoding: .utf8) == "v2")
        #expect(try PluginManifest.load(from: dest).version == "2.0.0")
        #expect(try String(contentsOf: root.appending(path: "plugins-data/p/storage.json"), encoding: .utf8) == "secret")
    }

    @Test func unreadableSourceLeavesTheOldFolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: "plugins")
        _ = try makePlugin("p", version: "1.0.0", in: plugins, files: ["old.ts": "old"])

        #expect(throws: PluginInstaller.AddError.self) {
            try PluginInstaller.update(id: "p", from: root.appending(path: "missing"), pluginsDirectory: plugins)
        }
        let dest = plugins.appending(path: "p")
        #expect(try PluginManifest.load(from: dest).version == "1.0.0")
        #expect(try String(contentsOf: dest.appending(path: "old.ts"), encoding: .utf8) == "old")
    }

    @Test func sourceWithASymlinkLeavesTheOldFolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: "plugins")
        _ = try makePlugin("p", version: "1.0.0", in: plugins, files: ["old.ts": "old"])
        let source = try makePlugin("p", version: "2.0.0", in: root.appending(path: "shipped"))
        try FileManager.default.createSymbolicLink(at: source.appending(path: "link"),
                                                   withDestinationURL: URL(filePath: "/etc/hosts"))

        #expect(throws: PluginInstaller.AddError.self) {
            try PluginInstaller.update(id: "p", from: source, pluginsDirectory: plugins)
        }
        #expect(try PluginManifest.load(from: plugins.appending(path: "p")).version == "1.0.0")
    }

    @Test func notInstalledOrWrongIDIsRefused() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: "plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let source = try makePlugin("p", version: "2.0.0", in: root.appending(path: "shipped"))
        #expect(throws: PluginInstaller.AddError.self) {
            try PluginInstaller.update(id: "p", from: source, pluginsDirectory: plugins)
        }
        #expect(throws: PluginInstaller.AddError.self) {
            try PluginInstaller.update(id: "q", from: source, pluginsDirectory: plugins)
        }
        #expect(!FileManager.default.fileExists(atPath: plugins.appending(path: "p").path))
    }
}
