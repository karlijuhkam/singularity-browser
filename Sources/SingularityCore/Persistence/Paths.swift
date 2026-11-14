import Foundation

/// The on-disk layout under `~/Singularity/`:
///
///     ~/Singularity/
///     ├─ state.json                 Space order + selected Space
///     ├─ settings.json              preferences from the Settings window
///     ├─ .run/mcp.sock              socket for agents (singularity-mcp), while the app runs
///     ├─ .run/hook.sock             socket for Claude Code's hook (singularity-hook), while the app runs
///     ├─ plugins/<id>/              one folder per plugin (plugin.json, sources)
///     ├─ plugins-data/<id>/         a plugin's own data folder
///     ├─ plugins-state.json         plugin approvals and per-Space switches
///     ├─ .cache/plugin-install/     staging folders while plugins' npm packages install
///     └─ spaces/<slug>/
///        ├─ space.json              the Space, its folders and tabs
///        ├─ history.jsonl           one visited page per line
///        ├─ artifacts/              HTML artifacts, served by the Space's local server
///        ├─ app-data/<app>/         an app's database files and worker.log (see ArtifactApps.swift)
///        ├─ agent-log.jsonl         one line per agent action
///        └─ favicons/<host>.png
///
/// `root` is injectable so tests can use a temporary directory.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: Paths {
        // For trying a build next to the copy you use every day: SINGULARITY_HOME=/some/folder
        // gives that run its own Spaces, settings, plugins and agent socket.
        if let override = ProcessInfo.processInfo.environment["SINGULARITY_HOME"], override.hasPrefix("/") {
            return Paths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        return Paths(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Singularity", directoryHint: .isDirectory))
    }

    public var stateFile: URL { root.appending(path: "state.json") }
    /// App-wide preferences (Settings window).
    public var settingsFile: URL { root.appending(path: "settings.json") }
    /// The Unix socket `singularity-mcp` connects to (folder 0700, socket 0600).
    public var mcpSocket: URL { root.appending(path: ".run/mcp.sock") }
    /// The Unix socket `singularity-hook` connects to (same rules as `mcpSocket`). Terminal tabs
    /// export its path as SINGULARITY_HOOK_SOCKET, so a test copy's terminals reach that copy.
    public var hookSocket: URL { root.appending(path: ".run/hook.sock") }
    /// Installed plugins, one folder per plugin id.
    public var pluginsDirectory: URL { root.appending(path: "plugins", directoryHint: .isDirectory) }
    /// Plugin approvals and per-Space switches.
    public var pluginStateFile: URL { root.appending(path: "plugins-state.json") }

    /// Where `bun install` runs at plugin approval: one private `install-<uuid>` folder per install
    /// (with its own package cache), deleted afterwards. Not inside any plugin's data folder.
    public var pluginInstallDirectory: URL {
        root.appending(path: ".cache/plugin-install", directoryHint: .isDirectory)
    }

    /// The one folder a plugin's background program may write to.
    public func pluginsDataDirectory(_ id: String) -> URL {
        root.appending(path: "plugins-data", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
    }

    public var spacesDirectory: URL { root.appending(path: "spaces", directoryHint: .isDirectory) }

    public func spaceDirectory(_ slug: String) -> URL {
        spacesDirectory.appending(path: slug, directoryHint: .isDirectory)
    }

    public func spaceFile(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "space.json")
    }

    public func historyFile(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "history.jsonl")
    }

    /// One JSON line per agent action in this Space (see AgentLog.swift).
    public func agentLogFile(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "agent-log.jsonl")
    }

    public func artifactsDirectory(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "artifacts", directoryHint: .isDirectory)
    }

    /// The data of the Space's apps (see ArtifactApps.swift): one folder per app, named after the
    /// app's path inside `artifacts/`. Outside `artifacts/`, so the server can never serve it.
    public func appDataDirectory(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "app-data", directoryHint: .isDirectory)
    }

    /// One app's data folder: its SQLite files and `worker.log`. Always directly inside
    /// `app-data/`, also for an app in a subfolder (`ArtifactApps.dataFolderName`).
    public func appDataDirectory(_ slug: String, app: String) -> URL {
        appDataDirectory(slug).appending(path: ArtifactApps.dataFolderName(for: app), directoryHint: .isDirectory)
    }

    public func faviconsDirectory(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "favicons", directoryHint: .isDirectory)
    }

    public func faviconFile(_ slug: String, host: String) -> URL {
        // Hosts only contain [a-z0-9.-], but guard against anything odd becoming a path.
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
        return faviconsDirectory(slug).appending(path: "\(safeHost).png")
    }
}
