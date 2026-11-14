import Foundation
@testable import Singularity
import SingularityCore

/// A real `AppState` for tests, on a temporary data folder. Every app test that needs one builds
/// it here and stops it with `shutDown`.
///
/// It can never reach the user's real Trash: `deleteSpace` (also called by an Arc import during
/// the welcome flow) removes the Space's folder inside the temporary folder instead, and refuses
/// any folder outside it.
@MainActor
enum TestAppState {
    /// A short path: the agent socket lives under it, and Unix sockets allow ~100 characters.
    static func makeRoot() -> URL {
        URL(filePath: "/private/tmp/sg-t-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    /// `plugins`: a manager of the test's own (with the repository's Bun), instead of the app
    /// bundle's, which a test run doesn't have.
    /// Apps' Workers run with the repository's Bun and host scripts (a test run has no app
    /// bundle), and their keys live in `keys` (memory), never in the keychain.
    static func make(root: URL, plugins: PluginManager? = nil, keys: AppKeyStore = MemoryAppKeyStore()) -> AppState {
        AppState(paths: Paths(root: root), discardFolder: removeInside(root), pluginManager: plugins,
                 appRuntime: (repositoryBun, repositoryHostFolder), appKeyStore: keys)
    }

    /// The repository's root, found from this file's location.
    nonisolated static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    nonisolated static let repositoryBun = repositoryRoot.appending(path: "Vendor/bun/bun")
    nonisolated static let repositoryHostFolder = repositoryRoot.appending(path: "Resources/plugin-host", directoryHint: .isDirectory)
    nonisolated static var hasBun: Bool { FileManager.default.isExecutableFile(atPath: repositoryBun.path) }

    /// Stops what `AppState.init` started (agent socket, plugin watcher, artifact servers). Pending
    /// saves are written now and no server starts afterwards (`stopAll`), so nothing recreates the
    /// data folder after the test has removed it (the debounced save and a queued server start both
    /// run later on the main actor).
    static func shutDown(_ state: AppState) {
        state.flushSaves()
        state.mcp?.stop()
        state.hookSocket?.stop()
        state.plugins.terminateAll()
        state.artifacts.stopAll()
    }

    private struct OutsideTheTestFolder: Error, CustomStringConvertible {
        let folder: URL
        var description: String { "refused to remove \(folder.path): not inside the test's folder" }
    }

    /// Removes a folder for good, but only one inside `root`. Compared as written, without
    /// standardizing (Foundation may drop the "/private" of one path and not the other); the
    /// app builds Space folders by appending to `root`, and ".." is refused.
    private static func removeInside(_ root: URL) -> SpaceStore.DiscardFolder {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return { folder in
            guard folder.path.hasPrefix(prefix), !folder.pathComponents.contains("..") else {
                throw OutsideTheTestFolder(folder: folder)
            }
            try FileManager.default.removeItem(at: folder)
        }
    }
}

private struct TimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` every 20 ms until it holds; throws (failing the test) after `limit`.
@MainActor
func waitUntil(_ what: String, limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut(description: "waited \(limit) for \(what)") }
        try await Task.sleep(for: .milliseconds(20))
    }
}
