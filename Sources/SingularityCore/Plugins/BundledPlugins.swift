import Foundation

/// A ready-made plugin that ships inside the app bundle (the welcome flow and Settings → Plugins
/// offer to add it).
public struct BundledPlugin: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The manifest's `description`.
    public let summary: String
    /// The plugin's folder inside the app bundle (what "Add" copies from).
    public let folder: URL
    /// The manifest's `panel.title`; nil for a plugin without its own page.
    public let panelTitle: String?
    /// The manifest's `version` (what an installed copy is compared with for "Update available").
    public let version: String

    public init(id: String, name: String, summary: String, folder: URL, panelTitle: String? = nil,
                version: String = "") {
        self.version = version
        self.id = id
        self.name = name
        self.summary = summary
        self.folder = folder
        self.panelTitle = panelTitle
    }
}

/// The plugins and the authoring guide that the build scripts copy into the app bundle:
/// `Contents/Resources/Plugins/<id>/…` and `Contents/Resources/plugin-guide/{AUTHORING.md, template/}`.
public enum BundledPlugins {
    /// `<app>/Contents/Resources/Plugins`
    public static func pluginsFolder(resources: URL) -> URL {
        resources.appending(path: "Plugins", directoryHint: .isDirectory)
    }

    /// `<app>/Contents/Resources/plugin-guide` (holds AUTHORING.md and template/)
    public static func guideFolder(resources: URL) -> URL {
        resources.appending(path: "plugin-guide", directoryHint: .isDirectory)
    }

    /// Valid plugins in `folder`, sorted by name. A missing folder or a broken plugin is skipped.
    /// "Valid" is what `PluginManifest.load(from:)` accepts, so a manifest whose id differs from its
    /// folder name is skipped too (bundled folders are named after their ids).
    public static func list(in folder: URL) -> [BundledPlugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var plugins: [BundledPlugin] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let manifest = try? PluginManifest.load(from: entry) else { continue }
            plugins.append(BundledPlugin(id: manifest.id, name: manifest.name, summary: manifest.description,
                                         folder: entry, panelTitle: manifest.panel?.title,
                                         version: manifest.version))
        }
        return plugins.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// The ones not installed yet (no folder with that id in the plugins folder), in list order:
    /// what Settings → Plugins offers under "Included with Singularity".
    public static func notInstalled(_ bundled: [BundledPlugin], installedIDs: Set<String>) -> [BundledPlugin] {
        bundled.filter { !installedIDs.contains($0.id) }
    }

    /// The shipped plugin to offer as an update for an installed one: same id, different `version`,
    /// and the installed copy is not in development mode and its files are the approved ones (or it
    /// was never approved). Edited files must never be overwritten by an update.
    public static func updateOffer(installedID: String, installedVersion: String, developmentMode: Bool,
                                   filesMatchApproval: Bool, bundled: [BundledPlugin]) -> BundledPlugin? {
        guard !developmentMode, filesMatchApproval else { return nil }
        return bundled.first { $0.id == installedID && !$0.version.isEmpty && $0.version != installedVersion }
    }

    /// The page title of the first shipped plugin with a panel ("Assistant"), which View →
    /// Show <title> (⌃⌘J) offers while no installed plugin has a panel: it opens Settings →
    /// Plugins, where the plugin can be added. nil when none has a panel (a bare debug binary
    /// ships none at all).
    public static func offeredPanelTitle(_ bundled: [BundledPlugin]) -> String? {
        bundled.lazy.compactMap(\.panelTitle).first
    }

    /// The prompt the user copies into their agent. The guide path is given in full (it is inside
    /// the app); the plugins folder is shown with `~` for the home folder. `<id>` and `…` are left
    /// for the user to fill in.
    public static func authoringPrompt(guide: URL, pluginsDirectory: URL) -> String {
        let guidePath = guide.path
        let plugins = HomePath.abbreviate(pluginsDirectory.path)
        return "Read \(guidePath)/AUTHORING.md (a template is in \(guidePath)/template), "
            + "then write a Singularity plugin in \(plugins)/<id> that …"
    }
}
