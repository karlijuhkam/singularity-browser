import Foundation

/// Contents of `~/Singularity/state.json`.
public struct AppStateFile: Codable, Equatable, Sendable {
    public var spaceOrder: [UUID]
    public var selectedSpaceID: UUID?

    public init(spaceOrder: [UUID] = [], selectedSpaceID: UUID? = nil) {
        self.spaceOrder = spaceOrder
        self.selectedSpaceID = selectedSpaceID
    }
}

/// Reads and writes Spaces as JSON files. Every write is atomic (written to a temp file,
/// then renamed into place), so a crash never leaves a half-written file.
public struct SpaceStore: Sendable {
    /// What happens to a deleted Space's folder. The app moves it to the Trash (`moveToTrash`);
    /// tests pass a closure that removes it inside their temporary folder, so a test can never
    /// put anything in the user's real Trash.
    public typealias DiscardFolder = @Sendable (URL) throws -> Void

    public let paths: Paths
    private let discardFolder: DiscardFolder

    public init(paths: Paths, discardFolder: @escaping DiscardFolder = SpaceStore.moveToTrash) {
        self.paths = paths
        self.discardFolder = discardFolder
    }

    /// The app's way to discard a folder: into the user's Trash, so it can be recovered.
    public static let moveToTrash: DiscardFolder = { folder in
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Loads every `spaces/*/space.json`, ordered by `state.json`. Spaces missing from the
    /// order list are appended (sorted by name). Unreadable files are skipped and reported.
    public func load() -> (spaces: [Space], state: AppStateFile, errors: [String]) {
        var errors: [String] = []
        var state = AppStateFile()
        if let data = try? Data(contentsOf: paths.stateFile) {
            do {
                state = try JSONDecoder().decode(AppStateFile.self, from: data)
            } catch {
                errors.append("state.json: \(error)")
            }
        }

        var spaces: [Space] = []
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: paths.spacesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = folder.appending(path: "space.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let space = try JSONDecoder().decode(Space.self, from: Data(contentsOf: file))
                // A copied Space folder carries the same id; two Spaces with one id would share
                // tabs and logins and confuse every lookup. The first one (by folder name) wins.
                if let twin = spaces.first(where: { $0.id == space.id }) {
                    errors.append("\(folder.lastPathComponent)/space.json: skipped, it is a copy of the Space “\(twin.name)” (same id)")
                    continue
                }
                spaces.append(space)
            } catch {
                errors.append("\(folder.lastPathComponent)/space.json: \(error)")
            }
        }

        // `uniquingKeysWith`: a repeated id in a hand-edited state.json must not crash the launch.
        let position = Dictionary(state.spaceOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        spaces.sort { a, b in
            switch (position[a.id], position[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return (spaces, state, errors)
    }

    public func save(_ space: Space) throws {
        try FileManager.default.createDirectory(at: paths.spaceDirectory(space.slug), withIntermediateDirectories: true)
        try Self.encoder.encode(space).write(to: paths.spaceFile(space.slug), options: .atomic)
    }

    public func save(_ state: AppStateFile) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: paths.stateFile, options: .atomic)
    }

    /// Settings; defaults if the file is missing or unreadable.
    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Self.encoder.encode(settings).write(to: paths.settingsFile, options: .atomic)
    }

    /// Moves a Space's folder to the Trash (recoverable) rather than deleting it; in tests, does
    /// whatever `discardFolder` was given at init. Does nothing when the folder doesn't exist.
    public func trashSpaceFolder(slug: String) throws {
        let folder = paths.spaceDirectory(slug)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try discardFolder(folder)
    }

    /// Renames a Space's folder. Does nothing (and succeeds) when the old folder doesn't exist
    /// yet; throws when the new one already exists. Only for the welcome flow's one-time rename
    /// of a brand-new install's first Space (see `FirstRun.mayReslug`).
    public func moveSpaceFolder(fromSlug: String, toSlug: String) throws {
        let source = paths.spaceDirectory(fromSlug)
        let destination = paths.spaceDirectory(toSlug)
        // Checked first, so a Space never ends up pointing at a folder that holds something else.
        if FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
