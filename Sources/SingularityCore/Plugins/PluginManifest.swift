import Foundation

/// The parsed `plugin.json` of one plugin. `load(from:)` also validates it (see below).
public struct PluginManifest: Codable, Equatable, Sendable {
    /// What the plugin adds to web pages: a script and the sites it runs on.
    public struct Page: Codable, Equatable, Sendable {
        public var script: String
        public var sites: [String]
    }

    /// The manifest's only powers. Missing keys mean "none".
    public struct Permissions: Codable, Equatable, Sendable {
        public var pageAdditions: [String]
        public var fillForms: [String]
        /// Program name -> allowed sub-commands (e.g. "op": ["item list", "item get"]).
        public var commands: [String: [String]]
        /// Always empty in round 1.
        public var network: [String]

        public init(pageAdditions: [String] = [], fillForms: [String] = [],
                    commands: [String: [String]] = [:], network: [String] = []) {
            self.pageAdditions = pageAdditions
            self.fillForms = fillForms
            self.commands = commands
            self.network = network
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        /// Decodes by hand so an unknown key (e.g. "cookies") is an error, not silently ignored.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let known: Set<String> = ["pageAdditions", "fillForms", "commands", "network"]
            for key in c.allKeys where !known.contains(key.stringValue) {
                throw PluginError.unknownPermission(key.stringValue)
            }
            func field<T: Decodable>(_ name: String, _ empty: T) throws -> T {
                try c.decodeIfPresent(T.self, forKey: Key(stringValue: name)) ?? empty
            }
            pageAdditions = try field("pageAdditions", [String]())
            fillForms = try field("fillForms", [String]())
            commands = try field("commands", [String: [String]]())
            network = try field("network", [String]())
        }
    }

    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    public var background: String?
    public var page: Page?
    public var permissions: Permissions

    // MARK: Loading

    /// Reads and validates `<folder>/plugin.json`. Check order: JSON shape, id format, id equals
    /// folder name, permission keys (during decoding), site patterns, network, commands, files,
    /// lockfile. The first problem found is thrown.
    public static func load(from folder: URL) throws(PluginError) -> PluginManifest {
        let manifest: PluginManifest
        do {
            let data = try Data(contentsOf: folder.appending(path: "plugin.json"))
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as PluginError {
            throw error // e.g. unknownPermission from Permissions.init(from:)
        } catch {
            throw .invalidJSON(String(describing: error))
        }
        try manifest.validate(folder: folder)
        return manifest
    }

    /// Plugin ids: `^[a-z0-9][a-z0-9-]{0,39}$`.
    static func isValidID(_ id: String) -> Bool {
        guard (1...40).contains(id.utf8.count) else { return false }
        for (i, b) in id.utf8.enumerated() {
            let isLowerOrDigit = (b >= 97 && b <= 122) || (b >= 48 && b <= 57)
            if !(isLowerOrDigit || (i > 0 && b == 45)) { return false }
        }
        return true
    }

    private func validate(folder: URL) throws(PluginError) {
        guard Self.isValidID(id) else { throw .invalidID(id) }
        let folderName = folder.lastPathComponent
        guard id == folderName else { throw .idDoesNotMatchFolder(id: id, folder: folderName) }

        for site in (page?.sites ?? []) + permissions.pageAdditions + permissions.fillForms {
            _ = try SitePattern(site) // throws invalidSitePattern
        }
        // A page script may only run where pageAdditions allows it.
        if !permissions.pageAdditions.contains("<all_urls>") {
            for site in page?.sites ?? [] where !permissions.pageAdditions.contains(site) {
                throw .pageSiteNotPermitted(site)
            }
        }
        guard permissions.network.isEmpty else { throw .networkNotAvailable }

        // Sorted so the error for a manifest with several bad commands is deterministic.
        for (name, subcommands) in permissions.commands.sorted(by: { $0.key < $1.key }) {
            // An empty list or an empty sub-command would otherwise allow every argument.
            let hasEmptySub = subcommands.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if CommandPolicy.isRefused(name) || !CommandPolicy.isValidName(name)
                || subcommands.isEmpty || hasEmptySub {
                throw .refusedCommand(name)
            }
        }

        for path in [background, page?.script].compactMap({ $0 }) {
            guard Self.isRegularFile(path, inside: folder) else { throw .missingFile(path) }
        }

        try Self.checkPackages(in: folder)
    }

    /// Packages must be pinned: any non-empty dependency group needs a `bun.lock` file.
    /// A package.json that can't be understood is an error (fail closed).
    private static func checkPackages(in folder: URL) throws(PluginError) {
        let url = folder.appending(path: "package.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let object: Any
        do {
            let data = try Data(contentsOf: url)
            // Foundation's parser tolerates trailing commas; real JSON (and Bun) does not.
            if hasTrailingComma(data) { throw CocoaError(.propertyListReadCorrupt) }
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .invalidJSON("package.json: not readable or not valid JSON")
        }
        guard let root = object as? [String: Any] else { throw .invalidJSON("package.json: not an object") }
        var hasDependencies = false
        for key in ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"] {
            guard let value = root[key] else { continue }
            guard let group = value as? [String: Any] else { throw .invalidJSON("package.json: \(key) is not an object") }
            if !group.isEmpty { hasDependencies = true }
        }
        guard hasDependencies else { return }
        var isDir: ObjCBool = false
        let lock = folder.appending(path: "bun.lock").path
        guard FileManager.default.fileExists(atPath: lock, isDirectory: &isDir), !isDir.boolValue else {
            throw .missingLockfile
        }
    }

    /// True when a "," is followed (ignoring whitespace) by "}" or "]", outside of strings.
    private static func hasTrailingComma(_ data: Data) -> Bool {
        var inString = false, escaped = false, pendingComma = false
        for b in data {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case 0x7D, 0x5D: if pendingComma { return true }
            default: break
            }
            pendingComma = (b == 0x2C)
            if b == 0x22 { inString = true }
        }
        return false
    }

    /// A relative path, no `..` component, that is a regular file still inside `folder`
    /// after symlinks are resolved.
    private static func isRegularFile(_ path: String, inside folder: URL) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains("..") else { return false }
        let file = folder.appending(path: path).resolvingSymlinksInPath()
        let root = folder.resolvingSymlinksInPath().path
        guard file.path.hasPrefix(root + "/") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && !isDir.boolValue
    }
}
