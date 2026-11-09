import CryptoKit
import Foundation

/// A hash of everything in a plugin folder that could change what it does.
public enum PluginFingerprint {
    /// Skipped at any depth: installed packages (pinned by bun.lock, which IS hashed), git data, Finder noise.
    private static let skipped: Set<String> = ["node_modules", ".git", ".DS_Store"]

    /// SHA-256 (lowercase hex) over every file, sorted by relative path (byte order).
    /// Each file contributes: path length, path bytes, content length, content bytes (lengths are
    /// 8-byte big-endian), so no two different folders can produce the same byte stream.
    /// Dotfiles (.npmrc, bunfig.toml...) count. Throws `symlinkNotAllowed` for any symlink,
    /// because it could point outside the plugin.
    public static func compute(folder: URL) throws -> String {
        let fm = FileManager.default
        var files: [(path: String, url: URL)] = []

        func walk(_ dir: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path) where !skipped.contains(name) {
                let url = dir.appending(path: name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                // attributesOfItem does not follow symlinks, so a link reports .typeSymbolicLink.
                let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                switch type {
                case .typeSymbolicLink: throw PluginError.symlinkNotAllowed(rel)
                case .typeDirectory: try walk(url, rel)
                default: files.append((rel, url))
                }
            }
        }
        try walk(folder, "")

        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var hasher = SHA256()
        func putLength(_ n: Int) {
            var be = UInt64(n).bigEndian
            withUnsafeBytes(of: &be) { hasher.update(bufferPointer: $0) }
        }
        for file in files {
            let pathBytes = Data(file.path.utf8)
            let content = try Data(contentsOf: file.url)
            putLength(pathBytes.count); hasher.update(data: pathBytes)
            putLength(content.count); hasher.update(data: content)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    public init(fingerprint: String, permissions: PluginManifest.Permissions, commandPaths: [String: String],
                enabledSpaces: Set<UUID>, developmentMode: Bool, approvedAt: Date) {
        self.fingerprint = fingerprint
        self.permissions = permissions
        self.commandPaths = commandPaths
        self.enabledSpaces = enabledSpaces
        self.developmentMode = developmentMode
        self.approvedAt = approvedAt
    }
}

/// `~/Singularity/plugins-state.json`: plugin id -> approval.
public struct PluginStateStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }

    /// Empty for a missing, unreadable or corrupt file: plugins then show as new and are re-approved.
    public func load() -> [String: PluginApproval] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: PluginApproval].self, from: data)) ?? [:]
    }

    public func save(_ approvals: [String: PluginApproval]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
