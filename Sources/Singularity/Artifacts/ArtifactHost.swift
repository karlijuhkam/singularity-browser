import Foundation
import Observation
import SingularityCore

/// Everything artifact-related for one Space: its token, its server, its folder watcher,
/// and the list of artifact pages in the folder (for the command palette).
@MainActor
@Observable
final class ArtifactHost {
    let spaceID: UUID
    let root: URL
    @ObservationIgnored let token = ArtifactAuth.makeToken()
    private(set) var port: UInt16?
    /// Artifact pages in the folder, relative paths, sorted.
    private(set) var pages: [String] = []

    @ObservationIgnored private var server: ArtifactServer?
    @ObservationIgnored private var watcher: ArtifactWatcher?
    @ObservationIgnored private let onChange: @MainActor ([ArtifactWatcher.Change]) -> Void
    @ObservationIgnored private let scripts: ArtifactScriptService?

    init(spaceID: UUID, root: URL, scripts: ArtifactScriptService?, onChange: @escaping @MainActor ([ArtifactWatcher.Change]) -> Void) {
        self.spaceID = spaceID
        self.root = root
        self.scripts = scripts
        self.onChange = onChange
    }

    /// The server's origin, e.g. http://127.0.0.1:54321 (nil until started).
    var origin: URL? {
        port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
    }

    func url(for path: String) -> URL? {
        origin?.appending(path: path)
    }

    /// The request that opens an artifact page in a tab. It carries the token as a header; the
    /// server answers with the auth cookie, which the page's scripts, styles and fetch() calls
    /// then send automatically. See ArtifactAuth.
    func request(for path: String) -> URLRequest? {
        guard let url = url(for: path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The artifact path a URL points to, if the URL is on this Space's server.
    func artifactPath(for url: URL) -> String? {
        guard let port, url.host() == "127.0.0.1", url.port == Int(port) else { return nil }
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        return path
    }

    /// Creates the folder, starts the server and starts watching the folder.
    func start() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = try ArtifactServer(root: root, token: token, scripts: scripts)
        let port = try await server.start()
        self.server = server

        self.port = port
        pages = ArtifactFiles.listPages(in: root)

        let watcher = ArtifactWatcher(root: root) { [weak self] changes in
            guard let self else { return }
            self.pages = ArtifactFiles.listPages(in: self.root)
            self.onChange(changes)
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        if let server {
            Task { await server.stop() }
        }
        server = nil
        port = nil
    }
}

/// One `ArtifactHost` per Space, started the first time the Space is opened.
@MainActor
@Observable
final class ArtifactHosts {
    @ObservationIgnored weak var state: AppState?
    /// Compiles TypeScript/TSX artifacts (set by AppState; shared by all Spaces).
    @ObservationIgnored var scripts: ArtifactScriptService?
    private var hosts: [UUID: ArtifactHost] = [:]
    @ObservationIgnored private var starting: [UUID: Task<ArtifactHost?, Never>] = [:]

    func host(_ spaceID: UUID) -> ArtifactHost? {
        hosts[spaceID]
    }

    /// Returns the Space's running host, starting it first if needed. Concurrent callers share
    /// one start-up.
    func ensureStarted(_ space: Space, root: URL) async -> ArtifactHost? {
        if let host = hosts[space.id] { return host }
        if let pending = starting[space.id] { return await pending.value }

        let spaceID = space.id
        let scripts = scripts
        let task = Task { [weak self] () -> ArtifactHost? in
            let host = ArtifactHost(spaceID: spaceID, root: root, scripts: scripts) { [weak self] changes in
                self?.state?.artifactsDidChange(spaceID: spaceID, changes: changes)
            }
            do {
                try await host.start()
            } catch {
                NSLog("Singularity: could not start artifact server for \(space.slug): \(error)")
                return nil
            }
            self?.hosts[spaceID] = host
            return host
        }
        starting[space.id] = task
        let host = await task.value
        starting[space.id] = nil
        return host
    }

    func stop(_ spaceID: UUID) {
        hosts.removeValue(forKey: spaceID)?.stop()
    }
}
