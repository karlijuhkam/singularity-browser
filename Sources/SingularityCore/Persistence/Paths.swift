import Foundation

/// The on-disk layout under `~/Singularity/`:
///
///     ~/Singularity/
///     ├─ state.json                 Space order + selected Space
///     └─ spaces/<slug>/
///        ├─ space.json              the Space, its folders and tabs
///        ├─ history.jsonl           one visited page per line
///        ├─ artifacts/              HTML artifacts, served by the Space's local server
///        └─ favicons/<host>.png
///
/// `root` is injectable so tests can use a temporary directory.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: Paths {
        Paths(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Singularity", directoryHint: .isDirectory))
    }

    public var stateFile: URL { root.appending(path: "state.json") }
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

    public func artifactsDirectory(_ slug: String) -> URL {
        spaceDirectory(slug).appending(path: "artifacts", directoryHint: .isDirectory)
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
