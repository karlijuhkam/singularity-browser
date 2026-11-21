import Foundation

/// One installed browser extension, as approved by the owner (`~/Singularity/extensions-state.json`).
///
/// The extension's files are in `~/Singularity/extensions/<id>/`; `fingerprint` is
/// `PluginFingerprint` of that folder at approval. If the folder no longer matches, the extension
/// is paused until approved again (`ExtensionRules.status`).
public struct ExtensionRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// From Chrome Web Store (its id is `id`); "Check for Update" downloads it again.
        case store
        /// From a file or folder the owner chose (a .zip, .crx, .xpi or an unpacked folder).
        case file
    }

    /// The owner's run-time answers to an extension's requests for optional permissions, in one Space.
    public struct Grants: Codable, Equatable, Sendable {
        public var permissions: Set<String> = []
        public var patterns: Set<String> = []
        public var deniedPermissions: Set<String> = []
        public var deniedPatterns: Set<String> = []
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            permissions = Set((try? c.decodeIfPresent([String].self, forKey: .permissions)) ?? [])
            patterns = Set((try? c.decodeIfPresent([String].self, forKey: .patterns)) ?? [])
            deniedPermissions = Set((try? c.decodeIfPresent([String].self, forKey: .deniedPermissions)) ?? [])
            deniedPatterns = Set((try? c.decodeIfPresent([String].self, forKey: .deniedPatterns)) ?? [])
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(permissions.sorted(), forKey: .permissions)
            try c.encode(patterns.sorted(), forKey: .patterns)
            try c.encode(deniedPermissions.sorted(), forKey: .deniedPermissions)
            try c.encode(deniedPatterns.sorted(), forKey: .deniedPatterns)
        }

        private enum CodingKeys: String, CodingKey { case permissions, patterns, deniedPermissions, deniedPatterns }
    }

    /// The folder name: a Chrome id (32 letters a…p) or `local-<8 hex>`.
    public let id: String
    public var name: String
    public var version: String
    public var source: Source
    /// `PluginFingerprint` of the folder when the owner approved it.
    public var fingerprint: String
    /// Permissions and match patterns granted at approval (what the manifest asks for).
    public var permissions: Set<String>
    public var patterns: Set<String>
    /// The Spaces it runs in.
    public var enabledSpaces: Set<UUID>
    /// WebKit's context identifier per Space, kept so the extension finds its storage again.
    public var contextIDs: [UUID: String]
    /// Run-time answers per Space.
    public var grants: [UUID: Grants]
    public var installedAt: Date
    /// The `CompatAdapter.version` this extension was last checked (and, if needed, adapted) with;
    /// nil = never checked. With `adaptedFingerprint` nil it needed nothing and loads from its
    /// original folder.
    public var adaptation: Int?
    /// `PluginFingerprint` of `extensions-adapted/<id>/` when an adapted copy was built.
    public var adaptedFingerprint: String?
    /// What the adapter did (shown in Settings).
    public var adaptationSummary: CompatSummary?

    public init(id: String, name: String, version: String, source: Source, fingerprint: String,
                permissions: Set<String>, patterns: Set<String>, enabledSpaces: Set<UUID>,
                contextIDs: [UUID: String] = [:], grants: [UUID: Grants] = [:], installedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.fingerprint = fingerprint
        self.permissions = permissions
        self.patterns = patterns
        self.enabledSpaces = enabledSpaces
        self.contextIDs = contextIDs
        self.grants = grants
        self.installedAt = installedAt
    }

    /// Tolerant decoding: unknown or broken optional parts fall back to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .file
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        permissions = Set((try? c.decodeIfPresent([String].self, forKey: .permissions)) ?? [])
        patterns = Set((try? c.decodeIfPresent([String].self, forKey: .patterns)) ?? [])
        enabledSpaces = Set(((try? c.decodeIfPresent([String].self, forKey: .enabledSpaces)) ?? []).compactMap(UUID.init(uuidString:)))
        let ids = (try? c.decodeIfPresent([String: String].self, forKey: .contextIDs)) ?? [:]
        contextIDs = Dictionary(uniqueKeysWithValues: ids.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        let grantList = (try? c.decodeIfPresent([String: Grants].self, forKey: .grants)) ?? [:]
        grants = Dictionary(uniqueKeysWithValues: grantList.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        installedAt = (try? c.decodeIfPresent(Date.self, forKey: .installedAt)) ?? Date(timeIntervalSince1970: 0)
        adaptation = try? c.decodeIfPresent(Int.self, forKey: .adaptation)
        adaptedFingerprint = try? c.decodeIfPresent(String.self, forKey: .adaptedFingerprint)
        adaptationSummary = try? c.decodeIfPresent(CompatSummary.self, forKey: .adaptationSummary)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(permissions.sorted(), forKey: .permissions)
        try c.encode(patterns.sorted(), forKey: .patterns)
        try c.encode(enabledSpaces.map(\.uuidString).sorted(), forKey: .enabledSpaces)
        try c.encode(Dictionary(uniqueKeysWithValues: contextIDs.map { ($0.key.uuidString, $0.value) }), forKey: .contextIDs)
        try c.encode(Dictionary(uniqueKeysWithValues: grants.map { ($0.key.uuidString, $0.value) }), forKey: .grants)
        try c.encode(installedAt, forKey: .installedAt)
        try c.encodeIfPresent(adaptation, forKey: .adaptation)
        try c.encodeIfPresent(adaptedFingerprint, forKey: .adaptedFingerprint)
        try c.encodeIfPresent(adaptationSummary, forKey: .adaptationSummary)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, source, fingerprint, permissions, patterns, enabledSpaces, contextIDs, grants, installedAt
        case adaptation, adaptedFingerprint, adaptationSummary
    }
}

/// Reads and writes `extensions-state.json`: `[id: ExtensionRecord]`.
public struct ExtensionStateStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }

    /// The records, and whether a file that exists couldn't be read (it is then renamed to
    /// `extensions-state.corrupt-<date>.json` and every extension needs approving again).
    public func loadSettingAsideCorrupt(now: Date = Date()) -> (records: [String: ExtensionRecord], wasCorrupt: Bool) {
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil else { return ([:], false) }
        if let data = try? Data(contentsOf: file), let records = try? Self.decoder.decode([String: ExtensionRecord].self, from: data) {
            return (records, false)
        }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appending(path: "extensions-state.corrupt-\(stamp).json"))
        return ([:], true)
    }

    public func save(_ records: [String: ExtensionRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(records).write(to: file, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

/// The rules about installed extensions that need no WebKit.
public enum ExtensionRules {
    public enum Status: Equatable, Sendable {
        /// Approved and its files are the approved ones.
        case ready
        /// Its files changed since approval (or can't be read): paused until approved again.
        case changed
        /// Its folder is gone.
        case missing
        /// It needs an adapted copy, and neither a new one could be built nor an old one is usable.
        case cannotAdapt
    }

    /// What to load at launch (spec 2026-11-21, "When adapting happens").
    public enum AdaptationStep: Equatable, Sendable {
        /// The original folder: checked with this adapter and nothing was needed.
        case original
        /// The adapted copy, which still matches its recorded fingerprint.
        case adapted
        /// Run the adapter again (new adapter version, never checked, or the copy changed or is gone).
        case rebuild
    }

    public static func adaptationStep(_ record: ExtensionRecord, adaptedFingerprintNow: String?,
                                      adapterVersion: Int = CompatAdapter.version) -> AdaptationStep {
        guard record.adaptation == adapterVersion else { return .rebuild }
        guard let recorded = record.adaptedFingerprint else { return .original }
        return adaptedFingerprintNow == recorded ? .adapted : .rebuild
    }

    /// After a failed rebuild: the old adapted copy if it still matches its fingerprint, else nil
    /// (the extension is paused, `.cannotAdapt`).
    public static func afterFailedRebuild(_ record: ExtensionRecord, adaptedFingerprintNow: String?) -> AdaptationStep? {
        guard let recorded = record.adaptedFingerprint, adaptedFingerprintNow == recorded else { return nil }
        return .adapted
    }

    /// `currentFingerprint` nil = the folder couldn't be fingerprinted (gone, or holds a symlink).
    public static func status(record: ExtensionRecord, folderExists: Bool, currentFingerprint: String?) -> Status {
        guard folderExists else { return .missing }
        return currentFingerprint == record.fingerprint ? .ready : .changed
    }

    /// Whether the extension runs in `spaceID`.
    public static func runs(_ record: ExtensionRecord, status: Status, in spaceID: UUID) -> Bool {
        status == .ready && record.enabledSpaces.contains(spaceID)
    }

    /// A new local id: `local-` and 8 hex digits not used yet.
    public static func newLocalID(taken: Set<String>) -> String {
        while true {
            let id = "local-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            if !taken.contains(id) { return id }
        }
    }

    /// Whether `id` may be a folder name under `extensions/`.
    public static func isValidID(_ id: String) -> Bool {
        if ChromeWebStore.isValidID(id) { return true }
        guard id.hasPrefix("local-") else { return false }
        let rest = id.dropFirst(6)
        return rest.count == 8 && rest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The match pattern that covers one site ("https://example.com" → "https://example.com/*").
    /// Used to deny an extension a site the owner switched it off for.
    public static func pattern(forSite site: String) -> String? {
        guard let url = URL(string: site), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)/*"
    }

    /// Whether version `a` is newer than `b` (Chrome's form: up to four dot-separated numbers;
    /// anything else compares as text and only counts when different).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let parse: (String) -> [Int]? = { text in
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return parts.contains(nil) || parts.isEmpty ? nil : parts.compactMap { $0 }
        }
        guard let x = parse(a), let y = parse(b) else { return a != b && !a.isEmpty }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Whether a new version asks for anything the approved one didn't (then the owner is asked).
    public static func widens(_ record: ExtensionRecord, permissions: Set<String>, patterns: Set<String>) -> Bool {
        !permissions.isSubset(of: record.permissions) || !patterns.isSubset(of: record.patterns)
    }

    /// The download names that are extensions to offer for installing.
    public static func isExtensionFile(_ url: URL) -> Bool {
        ["crx", "xpi"].contains(url.pathExtension.lowercased())
    }
}
