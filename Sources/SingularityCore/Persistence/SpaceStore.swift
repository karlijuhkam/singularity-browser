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
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
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
        for folder in folders {
            let file = folder.appending(path: "space.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let space = try JSONDecoder().decode(Space.self, from: Data(contentsOf: file))
                spaces.append(space)
            } catch {
                errors.append("\(folder.lastPathComponent)/space.json: \(error)")
            }
        }

        let position = Dictionary(uniqueKeysWithValues: state.spaceOrder.enumerated().map { ($1, $0) })
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

    /// Moves a Space's folder to the Trash (recoverable) rather than deleting it.
    public func trashSpaceFolder(slug: String) throws {
        let folder = paths.spaceDirectory(slug)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }
}
