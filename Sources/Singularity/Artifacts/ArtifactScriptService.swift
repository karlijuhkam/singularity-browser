import Foundation
import SingularityCore

/// Compiles artifact scripts (TypeScript, TSX, JSX) for the artifact servers and remembers the
/// results, so a page that imports twenty modules compiles each once until it changes.
///
/// One for the whole app. The cache is in memory only: it is keyed by the file's path and tied
/// to its modification time and size, and is gone when the app quits.
final class ArtifactScriptService: @unchecked Sendable {
    private let runtime: URL
    private let hostFolder: URL

    private struct Entry {
        let modified: Date
        let size: Int
        let result: Result<String, ArtifactCompiler.Failure>
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private static let maxEntries = 500

    /// - Parameters:
    ///   - runtime: the bundled Bun (`Contents/Helpers/bun`).
    ///   - hostFolder: `Contents/Resources/plugin-host` (transpile-artifact.ts, bunfig.toml).
    init(runtime: URL, hostFolder: URL) {
        self.runtime = runtime
        self.hostFolder = hostFolder
    }

    /// The JavaScript for `file`, compiling it if it changed since last time.
    func javascript(for file: URL) async -> Result<String, ArtifactCompiler.Failure> {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = attributes?[.size] as? Int ?? -1
        if let entry = cached(file.path), entry.modified == modified, entry.size == size { return entry.result }

        let runtime = runtime, hostFolder = hostFolder
        // Running Bun blocks for a moment; keep that off the server's cooperative threads.
        let result = await Task.detached(priority: .userInitiated) {
            ArtifactCompiler.compile(file: file, runtime: runtime, hostFolder: hostFolder)
        }.value
        // "Bun couldn't run" may be over in a moment; only real answers are remembered.
        if case .failure(.unavailable) = result { return result }
        store(file.path, Entry(modified: modified, size: size, result: result))
        return result
    }

    private func cached(_ path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    private func store(_ path: String, _ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count >= Self.maxEntries { cache.removeAll() } // crude, and enough: it refills on demand
        cache[path] = entry
    }
}
