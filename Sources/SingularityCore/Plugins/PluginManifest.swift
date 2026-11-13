import Foundation

/// The parsed `plugin.json` of one plugin. `load(from:)` also validates it (see below).
public struct PluginManifest: Codable, Equatable, Sendable {
    /// What the plugin adds to web pages: a script and the sites it runs on.
    public struct Page: Codable, Equatable, Sendable {
        public var script: String
        public var sites: [String]
    }

    /// A panel the plugin shows as its own tab: a page file inside the plugin folder and the title
    /// the sidebar shows.
    public struct Panel: Codable, Equatable, Sendable {
        public var page: String
        public var title: String
    }

    /// The manifest's only powers. Missing keys mean "none".
    public struct Permissions: Codable, Equatable, Sendable {
        public var pageAdditions: [String]
        public var fillForms: [String]
        /// Program name -> allowed sub-commands (e.g. "op": ["item list", "item get"]).
        public var commands: [String: [String]]
        /// Always empty in round 1.
        public var network: [String]
        /// Names of programs the background program keeps running (not sandboxed). Resolved and
        /// pinned like commands, but `singularity.run` never runs them: only `commands` does.
        public var programs: [String]
        /// Names of settings Singularity passes on to those programs.
        public var programEnv: [String]

        public init(pageAdditions: [String] = [], fillForms: [String] = [],
                    commands: [String: [String]] = [:], network: [String] = [],
                    programs: [String] = [], programEnv: [String] = []) {
            self.pageAdditions = pageAdditions
            self.fillForms = fillForms
            self.commands = commands
            self.network = network
            self.programs = programs
            self.programEnv = programEnv
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
            let known: Set<String> = ["pageAdditions", "fillForms", "commands", "network", "programs", "programEnv"]
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
            programs = try field("programs", [String]())
            programEnv = try field("programEnv", [String]())
        }
    }

    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    public var background: String?
    public var page: Page?
    public var panel: Panel?
    public var permissions: Permissions

    /// True when the plugin has a page script (the per-Space switches only matter then).
    public var hasPageScript: Bool { page != nil }

    /// The Space switches are about page scripts, so only a plugin with one shows them.
    public var showsSpaceSwitches: Bool { page != nil }

    // MARK: Loading

    /// Reads and validates `<folder>/plugin.json`. Check order: JSON shape, id format, id equals
    /// folder name, permission keys (during decoding), site patterns, network, commands, files,
    /// packages (.npmrc, package.json, bun.lock). The first problem found is thrown.
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

        try validatePrograms()
        try validatePanel()

        for path in [background, page?.script, panel?.page].compactMap({ $0 }) {
            guard Self.isRegularFile(path, inside: folder) else { throw .missingFile(path) }
        }

        try Self.checkPackages(in: folder)
    }

    /// Program names for `programs` (at most 4, no duplicates, only with a background program) and
    /// the settings passed to them.
    private func validatePrograms() throws(PluginError) {
        let programs = permissions.programs
        for name in programs where CommandPolicy.isRefused(name) || !CommandPolicy.isValidName(name) {
            throw .refusedProgram(name)
        }
        if Set(programs).count != programs.count || programs.count > 4 {
            throw .refusedProgram(programs.first { name in programs.filter { $0 == name }.count > 1 } ?? programs[4])
        }
        if !programs.isEmpty, background == nil { throw .programsNeedBackground }
        for name in permissions.programEnv where !Self.isAllowedProgramEnv(name) { throw .invalidProgramEnv(name) }
        // Settings with no program to receive them make no sense.
        if !permissions.programEnv.isEmpty, programs.isEmpty { throw .invalidProgramEnv(permissions.programEnv[0]) }
    }

    /// `^[A-Z][A-Z0-9_]{0,63}$`, minus the names that change how a program starts or where it looks.
    static func isAllowedProgramEnv(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        for (i, b) in name.utf8.enumerated() {
            let isUpper = b >= 65 && b <= 90
            let isDigitOrUnderscore = (b >= 48 && b <= 57) || b == 95
            if !(isUpper || (i > 0 && isDigitOrUnderscore)) { return false }
        }
        let refused: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL", "PWD"]
        return !refused.contains(name) && !name.hasPrefix("DYLD_") && !name.hasPrefix("LD_")
            && !name.hasPrefix("SINGULARITY_")
    }

    /// The panel's title is one line of 1 to 40 characters once trimmed.
    private func validatePanel() throws(PluginError) {
        guard let panel else { return }
        let title = panel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(1...40).contains(title.count) || panel.title.contains(where: \.isNewline) { throw .invalidPanelTitle }
    }

    /// No `.npmrc`; packages only as exact npm registry versions, pinned by a matching `bun.lock`
    /// (see `PluginPackages.check`). Anything that can't be understood is an error (fail closed).
    private static func checkPackages(in folder: URL) throws(PluginError) {
        _ = try PluginPackages.check(folder: folder)
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
