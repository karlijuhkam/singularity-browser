import CryptoKit
import Foundation

/// A hash of everything in a plugin folder that could change what it does.
public enum PluginFingerprint {
    /// The fingerprint and the per-file hashes of one folder, from a single read of its files.
    public struct Snapshot: Equatable, Sendable {
        /// What `compute(folder:)` returns.
        public let fingerprint: String
        /// What `fileHashes(folder:)` returns.
        public let fileHashes: [String: String]

        public init(fingerprint: String, fileHashes: [String: String]) {
            self.fingerprint = fingerprint
            self.fileHashes = fileHashes
        }
    }

    /// SHA-256 (lowercase hex) over every file, sorted by relative path (byte order).
    /// Everything counts, including dotfiles, bun.lock and `node_modules` at every depth: Bun
    /// resolves `lib/node_modules/x` and imports `./.git/p.js`, so skipping them would let
    /// unreviewed code run. (Singularity records the fingerprint after installing packages, so
    /// tampering with installed packages counts as a change.) Only a top-level `.git/` and
    /// `.DS_Store` files at any depth are skipped.
    /// Each file contributes: path length, path bytes, content length, content bytes (lengths are
    /// 8-byte big-endian), so no two different folders can produce the same byte stream.
    /// Throws `symlinkNotAllowed` for a symlink (also the folder itself, reported as "."), and
    /// `unsupportedFile` for anything but regular files and directories (a FIFO would hang the read).
    public static func compute(folder: URL) throws -> String {
        try snapshot(folder: folder).fingerprint
    }

    /// Relative path -> SHA-256 (lowercase hex) of that file's content, for the same files as
    /// `compute` (same walk, same skips, same errors). The approval screen compares these with the
    /// ones recorded at approval to list which files changed.
    public static func fileHashes(folder: URL) throws -> [String: String] {
        try snapshot(folder: folder).fileHashes
    }

    /// Both values from one pass over the files (each file is read once).
    public static func snapshot(folder: URL) throws -> Snapshot {
        let files = try listFiles(folder: folder)
        var hasher = SHA256()
        func putLength(_ n: Int) {
            var be = UInt64(n).bigEndian
            withUnsafeBytes(of: &be) { hasher.update(bufferPointer: $0) }
        }
        var hashes: [String: String] = [:]
        for file in files {
            let pathBytes = Data(file.path.utf8)
            let content = try Data(contentsOf: file.url)
            putLength(pathBytes.count); hasher.update(data: pathBytes)
            putLength(content.count); hasher.update(data: content)
            hashes[file.path] = hex(SHA256.hash(data: content))
        }
        return Snapshot(fingerprint: hex(hasher.finalize()), fileHashes: hashes)
    }

    /// The files that count, sorted by relative path (byte order), without reading them.
    /// Throws like `compute`. Also used to check a folder before copying it (Add Plugin).
    public static func listFiles(folder: URL) throws -> [(path: String, url: URL)] {
        let fm = FileManager.default
        var files: [(path: String, url: URL)] = []

        // attributesOfItem does not follow symlinks, so a link reports .typeSymbolicLink.
        if try fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeSymbolicLink {
            throw PluginError.symlinkNotAllowed(".")
        }
        func walk(_ dir: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path) {
                if name == ".DS_Store" || (prefix.isEmpty && name == ".git") { continue }
                let url = dir.appending(path: name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                switch type {
                case .typeSymbolicLink: throw PluginError.symlinkNotAllowed(rel)
                case .typeDirectory: try walk(url, rel)
                case .typeRegular: files.append((rel, url))
                default: throw PluginError.unsupportedFile(rel)
                }
            }
        }
        try walk(folder, "")
        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        return files
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// What the user approved for one plugin.
public struct PluginApproval: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var permissions: PluginManifest.Permissions
    /// Program name -> absolute path the user approved (e.g. "op" -> "/opt/homebrew/bin/op").
    public var commandPaths: [String: String]
    public var enabledSpaces: Set<UUID>
    /// While on, edited files do not pause the plugin (permission widening still does).
    public var developmentMode: Bool
    public var approvedAt: Date
    /// Relative path -> SHA-256 of each file at approval (`PluginFingerprint.fileHashes`), so the
    /// approval screen can list what changed since. Empty in state files written before this existed.
    public var fileHashes: [String: String]

    public init(fingerprint: String, permissions: PluginManifest.Permissions, commandPaths: [String: String],
                enabledSpaces: Set<UUID>, developmentMode: Bool, approvedAt: Date, fileHashes: [String: String] = [:]) {
        self.fingerprint = fingerprint
        self.fileHashes = fileHashes
        self.permissions = permissions
        self.commandPaths = commandPaths
        self.enabledSpaces = enabledSpaces
        self.developmentMode = developmentMode
        // Stored with millisecond precision, so round here to make a saved value read back equal.
        self.approvedAt = Date(timeIntervalSince1970: (approvedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint, permissions, commandPaths, enabledSpaces, developmentMode, approvedAt, fileHashes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        permissions = try c.decode(PluginManifest.Permissions.self, forKey: .permissions)
        commandPaths = try c.decode([String: String].self, forKey: .commandPaths)
        enabledSpaces = Set(try c.decode([UUID].self, forKey: .enabledSpaces))
        developmentMode = try c.decode(Bool.self, forKey: .developmentMode)
        approvedAt = try c.decode(Date.self, forKey: .approvedAt)
        fileHashes = try c.decodeIfPresent([String: String].self, forKey: .fileHashes) ?? [:]
    }

    /// `enabledSpaces` is written sorted so the file is stable between saves.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(commandPaths, forKey: .commandPaths)
        try c.encode(enabledSpaces.sorted { $0.uuidString < $1.uuidString }, forKey: .enabledSpaces)
        try c.encode(developmentMode, forKey: .developmentMode)
        try c.encode(approvedAt, forKey: .approvedAt)
        try c.encode(fileHashes, forKey: .fileHashes)
    }
}

/// ISO-8601 with fractional seconds, so a saved date round-trips.
private enum StateDates {
    static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// `~/Singularity/plugins-state.json`: plugin id -> approval.
public struct PluginStateStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }

    /// What reading the state file found.
    public enum Loaded: Equatable, Sendable {
        case missing
        case loaded([String: PluginApproval])
        /// The file exists but can't be read or decoded.
        case corrupt
    }

    /// Empty for a missing, unreadable or corrupt file: plugins then show as new and are re-approved.
    public func load() -> [String: PluginApproval] {
        if case .loaded(let approvals) = read() { return approvals }
        return [:]
    }

    /// Like `load`, but tells a missing file from a corrupt one.
    public func read() -> Loaded {
        // attributesOfItem doesn't follow links; any kind of item at the path counts as "there".
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil else { return .missing }
        guard let data = try? Data(contentsOf: file), let approvals = decode(data) else { return .corrupt }
        return .loaded(approvals)
    }

    /// For app start: reads the file; a corrupt one is renamed to
    /// `plugins-state.corrupt-<date>.json` next to it (kept for inspection, and so the next save
    /// doesn't overwrite it). Returns the approvals (empty unless loaded) and whether a corrupt file
    /// was found.
    public func loadSettingAsideCorrupt(now: Date = Date()) -> (approvals: [String: PluginApproval], wasCorrupt: Bool) {
        switch read() {
        case .missing: return ([:], false)
        case .loaded(let approvals): return (approvals, false)
        case .corrupt:
            // ISO 8601 date and time, with "-" instead of ":" so the name is friendly everywhere.
            let stamp = StateDates.formatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let aside = file.deletingLastPathComponent().appending(path: "plugins-state.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            return ([:], true)
        }
    }

    private func decode(_ data: Data) -> [String: PluginApproval]? {
        let decoder = JSONDecoder()
        let formatter = StateDates.formatter()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date"))
            }
            return date
        }
        return try? decoder.decode([String: PluginApproval].self, from: data)
    }

    public func save(_ approvals: [String: PluginApproval]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = StateDates.formatter()
        encoder.dateEncodingStrategy = .custom { date, e in
            var c = e.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(approvals).write(to: file, options: .atomic)
    }
}

public enum PluginStatus: Equatable, Sendable {
    case new, approved, changed, permissionsWidened
    case invalid(PluginError)

    /// Precedence: broken manifest, never approved, wider permissions (even in development
    /// mode), edited files (unless development mode), otherwise approved.
    public static func evaluate(manifest: Result<PluginManifest, PluginError>, fingerprint: String,
                                approval: PluginApproval?) -> PluginStatus {
        let m: PluginManifest
        switch manifest {
        case .failure(let error): return .invalid(error)
        case .success(let value): m = value
        }
        guard let approval else { return .new }
        if m.permissions.widens(approval.permissions) { return .permissionsWidened }
        if fingerprint != approval.fingerprint && !approval.developmentMode { return .changed }
        return .approved
    }
}

extension PluginManifest.Permissions {
    /// True when `self` asks for anything `approved` did not cover. Removing things never widens.
    /// Sites compare as exact text; `<all_urls>` in the approved list covers any site.
    public func widens(_ approved: Self) -> Bool {
        func newSite(_ now: [String], _ was: [String]) -> Bool {
            !was.contains("<all_urls>") && now.contains { !was.contains($0) }
        }
        if newSite(pageAdditions, approved.pageAdditions) { return true }
        if newSite(fillForms, approved.fillForms) { return true }
        if network.contains(where: { !approved.network.contains($0) }) { return true }
        for (name, subs) in commands {
            guard let was = approved.commands[name] else { return true }
            if subs.contains(where: { !was.contains($0) }) { return true }
        }
        return false
    }
}
