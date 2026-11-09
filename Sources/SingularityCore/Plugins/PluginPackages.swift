import CryptoKit
import Foundation

/// One npm package a plugin declares in its `package.json` (`dependencies` only).
public struct PluginPackage: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// A plugin's npm packages: checking them (at every manifest load) and installing them (at
/// approval, by Singularity, with the bundled Bun).
///
/// The install runs **outside** the plugin sandbox, so `package.json` and `bun.lock` are untrusted
/// input to a privileged step. What is accepted:
/// - `package.json`: only `dependencies` (the other groups must be absent or empty); every value an
///   exact version (`1.2.3`, optional `-prerelease` / `+build`): no ranges, tags, `file:`, `link:`,
///   `workspace:`, git, GitHub, URLs or `npm:` aliases. A `file:../../..` dependency would make the
///   unsandboxed install copy any folder into the plugin folder, where the plugin can read it.
///   Keys that steer resolution (`overrides`, `resolutions`, `workspaces`, …) are refused too.
/// - `bun.lock`: every package entry is a package from the default registry (see `checkLockfile`
///   for the shapes Bun 1.4.4 writes), and each declared dependency is locked at exactly the
///   version `package.json` names.
/// - No `.npmrc` in the plugin folder: Bun reads it even with `--config` (registry, auth tokens,
///   TLS settings), see `forbiddenFile`.
public enum PluginPackages {
    /// What `check` found.
    public struct Summary: Equatable, Sendable {
        /// `dependencies` from package.json, sorted by name.
        public let packages: [PluginPackage]
        /// How many packages bun.lock lists in all (the declared ones plus the packages they need;
        /// Bun skips optional ones for other platforms, so it may install fewer); 0 when there are
        /// no dependencies.
        public let lockedCount: Int

        public init(packages: [PluginPackage], lockedCount: Int) {
            self.packages = packages
            self.lockedCount = lockedCount
        }
    }

    /// The registry every package comes from; also passed to Bun so nothing else can choose one.
    public static let registry = "https://registry.npmjs.org/"
    /// How long `bun install` may take.
    public static let installTimeout: Duration = .seconds(180)
    /// bun.lock bigger than this is refused (a real one for dozens of packages is a few hundred KB).
    static let maxLockfileBytes = 10 << 20

    /// The declared packages (`dependencies`), sorted by name. `[]` without a package.json.
    /// Throws like `check`.
    public static func list(folder: URL) throws(PluginError) -> [PluginPackage] {
        try check(folder: folder).packages
    }

    /// Validates `.npmrc` (must not exist), `package.json` and `bun.lock` as described above.
    /// Errors: `forbiddenFile(".npmrc")`, `invalidJSON("package.json: …" / "bun.lock: …")`,
    /// `unsupportedPackage(…)`, `missingLockfile` (dependencies but no bun.lock file).
    public static func check(folder: URL) throws(PluginError) -> Summary {
        // attributesOfItem doesn't follow links: a link named .npmrc counts as one too.
        if (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: ".npmrc").path)) != nil {
            throw .forbiddenFile(".npmrc")
        }
        let files = try PackageFiles.read(folder: folder)
        return try check(files)
    }

    /// The two files that decide what gets installed, as read once from a plugin folder.
    struct PackageFiles {
        /// nil when there is no package.json.
        var packageJSON: Data?
        /// nil when there is no bun.lock regular file (a folder of that name counts as none).
        var lockfile: Data?

        static func read(folder: URL) throws(PluginError) -> PackageFiles {
            let fm = FileManager.default
            var files = PackageFiles()
            let packageURL = folder.appending(path: "package.json")
            if (try? fm.attributesOfItem(atPath: packageURL.path)) != nil {
                guard let data = try? Data(contentsOf: packageURL) else { throw .invalidJSON("package.json: not readable") }
                files.packageJSON = data
            }
            var isDir: ObjCBool = false
            let lock = folder.appending(path: "bun.lock")
            if fm.fileExists(atPath: lock.path, isDirectory: &isDir), !isDir.boolValue {
                do {
                    let handle = try FileHandle(forReadingFrom: lock)
                    defer { try? handle.close() }
                    files.lockfile = try handle.read(upToCount: maxLockfileBytes + 1) ?? Data()
                } catch {
                    throw .invalidJSON("bun.lock: not readable")
                }
            }
            return files
        }
    }

    /// `check(folder:)` for files already read.
    static func check(_ files: PackageFiles) throws(PluginError) -> Summary {
        guard let packageJSON = files.packageJSON else { return Summary(packages: [], lockedCount: 0) }
        let dependencies = try readPackageJSON(packageJSON)
        guard !dependencies.isEmpty else { return Summary(packages: [], lockedCount: 0) }
        let packages = dependencies.map { PluginPackage(name: $0.key, version: $0.value) }.sorted { $0.name < $1.name }
        guard let lockfile = files.lockfile else { throw .missingLockfile }
        guard lockfile.count <= maxLockfileBytes else { throw .invalidJSON("bun.lock: larger than 10 MB") }
        let count = try checkLockfile(lockfile, dependencies: dependencies)
        return Summary(packages: packages, lockedCount: count)
    }

    // MARK: - package.json

    /// package.json keys that change how packages are resolved or where they come from. Refused
    /// when present and not empty (`null`, `{}` and `[]` are fine).
    static let refusedPackageKeys = ["devDependencies", "optionalDependencies", "peerDependencies",
                                     "bundleDependencies", "bundledDependencies", "overrides", "resolutions",
                                     "workspaces", "patchedDependencies", "catalog", "catalogs"]

    /// Name -> exact version from `dependencies`. Strict JSON (no trailing commas, no duplicate keys).
    static func readPackageJSON(_ data: Data) throws(PluginError) -> [String: String] {
        let root: [String: JSONValue]
        do {
            guard case .object(let object) = try JSONText.parse(data) else { throw PluginError.invalidJSON("package.json: not an object") }
            root = object
        } catch let error as PluginError {
            throw error
        } catch {
            throw .invalidJSON("package.json: \(error)")
        }
        for key in refusedPackageKeys {
            switch root[key] {
            case nil, .null?: continue
            case .object(let o)? where o.isEmpty: continue
            case .array(let a)? where a.isEmpty: continue
            default: throw .unsupportedPackage(key)
            }
        }
        var result: [String: String] = [:]
        switch root["dependencies"] {
        case nil, .null?: return [:]
        case .object(let group)?:
            for (name, value) in group {
                guard isValidName(name), case .string(let version) = value, isExactVersion(version) else {
                    throw .unsupportedPackage(name)
                }
                result[name] = version
            }
            return result
        default:
            throw .invalidJSON("package.json: dependencies is not an object")
        }
    }

    /// An exact semantic version: `MAJOR.MINOR.PATCH` (no leading zeros), optional
    /// `-prerelease` and `+build` made of dot-separated `[0-9A-Za-z-]` identifiers. Anything a
    /// range, tag or protocol could look like (`^1.2.3`, `latest`, `1.x`, `v1.2.3`, `file:…`) fails.
    public static func isExactVersion(_ text: String) -> Bool {
        var rest = Substring(text)
        var build: Substring?
        if let plus = rest.firstIndex(of: "+") { build = rest[rest.index(after: plus)...]; rest = rest[..<plus] }
        var pre: Substring?
        if let dash = rest.firstIndex(of: "-") { pre = rest[rest.index(after: dash)...]; rest = rest[..<dash] }

        func isNumber(_ s: Substring) -> Bool {
            !s.isEmpty && s.utf8.allSatisfy { (48...57).contains($0) } && (s == "0" || s.first != "0")
        }
        func identifiers(_ s: Substring, numericNoLeadingZero: Bool) -> Bool {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            return parts.allSatisfy { part in
                guard !part.isEmpty, part.utf8.allSatisfy({ isAlnum($0) || $0 == 45 }) else { return false }
                let numeric = part.utf8.allSatisfy { (48...57).contains($0) }
                return !(numericNoLeadingZero && numeric && part.count > 1 && part.first == "0")
            }
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy(isNumber) else { return false }
        if let pre, !identifiers(pre, numericNoLeadingZero: true) { return false }
        if let build, !identifiers(build, numericNoLeadingZero: false) { return false }
        return true
    }

    /// An npm package name: `name` or `@scope/name`, made of `[A-Za-z0-9._~-]`, not starting with
    /// "." or "_" (so never "." or ".."), at most 214 bytes. bun.lock keys are paths built from such
    /// names, so this also keeps a key from pointing outside node_modules.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...214).contains(name.utf8.count) else { return false }
        func part(_ s: Substring) -> Bool {
            guard let first = s.utf8.first, first != 46, first != 95 else { return false }   // "." "_"
            return s.utf8.allSatisfy { isAlnum($0) || $0 == 46 || $0 == 95 || $0 == 126 || $0 == 45 }
        }
        if name.hasPrefix("@") {
            let pieces = name.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            return pieces.count == 2 && part(pieces[0]) && part(pieces[1])
        }
        return !name.contains("/") && part(Substring(name))
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b)
    }

    // MARK: - bun.lock

    /// Checks a bun.lock (Bun 1.4.4's text format, JSONC) against `dependencies` and returns how
    /// many packages it installs. The shapes Bun writes for each kind of package (generated with
    /// Bun 1.4.4; see Tests/…/Fixtures/bun-lock):
    ///
    ///     registry   "chalk": ["chalk@4.1.2", "", { …meta }, "sha512-…"]
    ///     other reg. "x": ["x@1.0.0", "https://registry.npmmirror.com/x/-/x-1.0.0.tgz", { … }, "sha512-…"]
    ///     tarball    "x": ["x@https://…/x-1.0.0.tgz", { … }, "sha512-…"]   (local: "x@../x.tgz")
    ///     github     "x": ["x@github:owner/repo#abc1234", { … }, "owner-repo-abc1234", "sha512-…"]
    ///     git        "x": ["x@git+https://…#<commit>", { … }, "<commit>"]
    ///     file/link  "x": ["x@file:../x", { … }]   /   ["x@link:../x", { … }]
    ///     workspace  "x": ["x@workspace:packages/x"]
    ///     npm alias  "alias": ["real-name@1.0.0", "", { … }, "sha512-…"]   (key ≠ name)
    ///     nested     "is-odd/is-number": ["is-number@6.0.0", "", { … }, "sha512-…"]
    ///
    /// Accepted: exactly the first shape — four elements; `"<name>@<exact version>"` whose name is
    /// the key's last package name; an empty second element (the default registry, which Singularity
    /// sets to registry.npmjs.org); an object; an integrity string. Everything else is
    /// `unsupportedPackage(<key>)`. Also refused: top-level keys other than lockfileVersion,
    /// configVersion, workspaces and packages (e.g. overrides, patchedDependencies), workspaces
    /// other than the root, and root dependency groups other than `dependencies`. Each declared
    /// dependency must be locked at the root (key = its name) at exactly its package.json version.
    static func checkLockfile(_ data: Data, dependencies: [String: String]) throws(PluginError) -> Int {
        let root: [String: JSONValue]
        do {
            guard case .object(let object) = try JSONText.parse(data, allowJSONC: true) else {
                throw PluginError.invalidJSON("bun.lock: not an object")
            }
            root = object
        } catch let error as PluginError {
            throw error
        } catch {
            throw .invalidJSON("bun.lock: \(error)")
        }

        // Format version: 1 and 2 have the shapes above (1.4.4 writes 2). Unknown ones fail closed.
        guard case .number(let version)? = root["lockfileVersion"], version == 1 || version == 2 else {
            throw .invalidJSON("bun.lock: unsupported lockfileVersion")
        }
        for key in root.keys.sorted() where !["lockfileVersion", "configVersion", "workspaces", "packages"].contains(key) {
            throw .unsupportedPackage("bun.lock: \(key)")
        }
        guard case .object(let packages)? = root["packages"] else { throw .invalidJSON("bun.lock: no packages") }

        // 1. Every entry is a registry package (sorted so the error is deterministic).
        var locked: [String: String] = [:]   // key -> version
        for key in packages.keys.sorted() {
            guard let names = packagePath(key), let leaf = names.last,
                  case .array(let entry)? = packages[key], entry.count == 4,
                  case .string(let spec) = entry[0], case .string(let registryURL) = entry[1], registryURL.isEmpty,
                  case .object = entry[2], case .string(let integrity) = entry[3], !integrity.isEmpty,
                  let parts = splitSpec(spec), parts.name == leaf, isExactVersion(parts.version) else {
                throw .unsupportedPackage(key)
            }
            locked[key] = parts.version
        }

        // 2. Only the root workspace, with only `dependencies`, equal to package.json's.
        guard case .object(let workspaces)? = root["workspaces"], case .object(let rootWorkspace)? = workspaces[""] else {
            throw .invalidJSON("bun.lock: no root workspace")
        }
        for key in workspaces.keys.sorted() where !key.isEmpty { throw .unsupportedPackage("bun.lock: workspace \(key)") }
        for key in ["devDependencies", "optionalDependencies", "peerDependencies"] {
            if case .object(let group)? = rootWorkspace[key], group.isEmpty { continue }
            if rootWorkspace[key] != nil { throw .unsupportedPackage(key) }
        }
        var rootDependencies: [String: String] = [:]
        if case .object(let group)? = rootWorkspace["dependencies"] {
            for (name, value) in group {
                guard case .string(let spec) = value else { throw .unsupportedPackage(name) }
                rootDependencies[name] = spec
            }
        }
        for name in Set(rootDependencies.keys).union(dependencies.keys).sorted()
        where rootDependencies[name] != dependencies[name] {
            throw .unsupportedPackage(name)
        }

        // 3. Each declared dependency is installed at the top level at exactly that version.
        for (name, version) in dependencies.sorted(by: { $0.key < $1.key }) where locked[name] != version {
            throw .unsupportedPackage(name)
        }
        return packages.count
    }

    /// "a/@s/b/c" -> ["a", "@s/b", "c"]: the package names along a bun.lock key (each package's
    /// node_modules parent). nil if any of them isn't a valid name.
    static func packagePath(_ key: String) -> [String]? {
        var names: [String] = []
        var pieces = key.split(separator: "/", omittingEmptySubsequences: false)[...]
        while let first = pieces.popFirst() {
            var name = String(first)
            if first.hasPrefix("@") {
                guard let second = pieces.popFirst() else { return nil }
                name += "/" + second
            }
            guard isValidName(name) else { return nil }
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }

    /// "@scope/name@1.2.3" -> ("@scope/name", "1.2.3"): split at the last "@" that isn't the first
    /// character.
    static func splitSpec(_ spec: String) -> (name: String, version: String)? {
        guard let at = spec.dropFirst().lastIndex(of: "@") else { return nil }
        return (String(spec[..<at]), String(spec[spec.index(after: at)...]))
    }

    // MARK: - Development mode

    /// True for the files that make up a plugin's packages: package.json, bun.lock, and anything
    /// under a `node_modules` folder (at any depth: Bun resolves those too). These need a new
    /// approval even in development mode, which only covers edits to the plugin's own code.
    public static func isPackagePath(_ path: String) -> Bool {
        if path == "package.json" || path == "bun.lock" { return true }
        return path.split(separator: "/").dropLast().contains("node_modules")
    }

    /// True when any package file (`isPackagePath`) was added, removed or changed between the two
    /// per-file hash lists.
    public static func packageFilesDiffer(approved: [String: String], current: [String: String]) -> Bool {
        let paths = Set(approved.keys).union(current.keys).filter(isPackagePath)
        return paths.contains { approved[$0] != current[$0] }
    }

    /// True when the two per-file hash lists agree on everything outside the top-level
    /// `node_modules`. `approve` uses it to make sure that, apart from what the install wrote, the
    /// folder after installing is exactly what the approval sheet showed.
    public static func sameOutsideNodeModules(_ a: [String: String], _ b: [String: String]) -> Bool {
        func outside(_ hashes: [String: String]) -> [String: String] {
            hashes.filter { !$0.key.hasPrefix("node_modules/") }
        }
        return outside(a) == outside(b)
    }

    // MARK: - Installing

    /// Bun's arguments, flags first (Bun 1.4.4 takes global flags before the command):
    /// - `--config=<host>/bunfig.toml`: our own empty config, so no project bunfig.toml
    ///   (`[install] registry`, `cache`, `scopes`, `linker`…) is read. Verified with 1.4.4.
    /// - `--no-env-file`: `bun install` otherwise loads `.env` files from its working folder,
    ///   which can set BUN_CONFIG_REGISTRY or proxies (verified with 1.4.4).
    /// - `--frozen-lockfile`: install exactly bun.lock, fail if package.json disagrees.
    /// - `--ignore-scripts`: no package install scripts, ever (they would run unsandboxed).
    /// - `--production`: no devDependencies (they are refused anyway).
    /// - `--registry`: overrides .npmrc, bunfig and the environment.
    /// - `--linker=hoisted`: a plain node_modules tree. The isolated linker is made of symlinks,
    ///   which plugin folders may not contain.
    /// - `--backend=clonefile`: real files (APFS clones), never symlinks or hard links into the cache.
    /// (The install runs in a staging folder holding only package.json and bun.lock, see
    /// `install`, so the first two are a second line of defence.)
    public static func installArguments(hostFolder: String) -> [String] {
        ["--config=" + hostFolder + "/bunfig.toml", "--no-env-file",
         "install", "--frozen-lockfile", "--ignore-scripts", "--production",
         "--registry=" + registry, "--linker=hoisted", "--backend=clonefile", "--no-progress"]
    }

    /// Exactly what `bun install` gets; nothing is inherited from the app (no NPM_TOKEN, proxies,
    /// XDG_CONFIG_HOME…). `home` is a fresh, empty folder, so no ~/.npmrc or ~/.bunfig.toml is read.
    /// The cache lives under `~/Singularity/.cache/`, not in the plugin's data folder (which the
    /// plugin can write to, so it could plant files in the cache).
    public static func installEnvironment(home: String, cache: String) -> [String: String] {
        [
            "HOME": home,
            "TMPDIR": home,
            "LANG": "en_US.UTF-8",
            "NO_COLOR": "1",
            "BUN_INSTALL_CACHE_DIR": cache,
            "BUN_CONFIG_REGISTRY": registry,
        ]
    }

    /// The result of `install`.
    public struct InstallResult: Sendable {
        public enum Outcome: Equatable, Sendable {
            /// node_modules now holds the packages bun.lock pins.
            case installed
            /// The plugin declares no packages (any node_modules it shipped was deleted).
            case nothingToInstall
            /// package.json or bun.lock aren't the ones the approval sheet showed.
            case filesChanged
            case failed
        }
        public let outcome: Outcome
        /// One plain sentence (for the approval sheet when it failed).
        public let message: String
        /// Bun's output (stdout then stderr), for the plugin's log.
        public let output: String

        public var succeeded: Bool { outcome == .installed || outcome == .nothingToInstall }
    }

    /// Deletes `<folder>/node_modules` (a plugin may not ship its own); then, if the plugin
    /// declares packages, installs them and puts the result in `<folder>/node_modules`.
    ///
    /// How: package.json and bun.lock are read once. If `expectedFileHashes` is given (the
    /// per-file hashes the approval sheet showed), both must still have those hashes (or both be
    /// missing), else `.filesChanged`. The bytes read are validated (`check`), copied into a fresh
    /// staging folder next to the cache, and `bun install` runs there (`installArguments`,
    /// `installEnvironment`, `timeout`). So Bun reads exactly the files that were checked, and
    /// nothing else from the plugin folder (no .env, .npmrc, bunfig.toml, nothing swapped in
    /// after the check). The `.bin` folders Bun makes are deleted (they hold symlinks, which plugin
    /// folders may not contain; nothing in a plugin can run them anyway), and node_modules is moved
    /// into the plugin folder. On any failure the plugin folder is left without node_modules.
    /// Slow: never call it on the main thread.
    /// - Parameters:
    ///   - runtime: the bundled Bun executable.
    ///   - hostFolder: the app's `plugin-host` folder (its bunfig.toml is empty).
    ///   - cacheFolder: Bun's package cache (`~/Singularity/.cache/bun-install`). Staging folders
    ///     are made next to it and deleted afterwards.
    public static func install(folder: URL, expectedFileHashes: [String: String]? = nil, runtime: URL, hostFolder: URL,
                               cacheFolder: URL, timeout: Duration = installTimeout) async -> InstallResult {
        let fm = FileManager.default
        func result(_ outcome: InstallResult.Outcome, _ message: String, _ output: String = "") -> InstallResult {
            if outcome == .failed || outcome == .filesChanged { removeNodeModules(in: folder) }
            return InstallResult(outcome: outcome, message: message, output: output)
        }
        guard removeNodeModules(in: folder) else { return result(.failed, "Couldn't delete the plugin's node_modules folder.") }

        let files: PackageFiles
        let summary: Summary
        do {
            files = try PackageFiles.read(folder: folder)
            if let expected = expectedFileHashes {
                guard files.packageJSON.map(sha256) == expected["package.json"],
                      files.lockfile.map(sha256) == expected["bun.lock"] else {
                    return result(.filesChanged, "Its package.json or bun.lock changed.")
                }
            }
            summary = try check(files)
        } catch {
            return result(.failed, "Its packages can't be installed: \(error.userMessage).")
        }
        let count = summary.packages.count
        guard count > 0, let packageJSON = files.packageJSON, let lockfile = files.lockfile else {
            return result(.nothingToInstall, "No packages")
        }

        // <cache>/../install-<uuid>/{project,home}: project holds only package.json and bun.lock;
        // home is Bun's empty HOME and TMPDIR. Private to this user, deleted afterwards.
        let staging = cacheFolder.deletingLastPathComponent()
            .appending(path: "install-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let project = staging.appending(path: "project", directoryHint: .isDirectory)
        let home = staging.appending(path: "home", directoryHint: .isDirectory)
        let runtimePath: String, hostPath: String, projectPath: String, homePath: String
        do {
            for dir in [cacheFolder, project, home] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try packageJSON.write(to: project.appending(path: "package.json"))
            try lockfile.write(to: project.appending(path: "bun.lock"))
            runtimePath = try PluginProcess.realPath(runtime)
            hostPath = try PluginProcess.realPath(hostFolder)
            projectPath = try PluginProcess.realPath(project)
            homePath = try PluginProcess.realPath(home)
        } catch {
            return result(.failed, "Couldn't prepare the package install: \(error.localizedDescription)")
        }

        let run = await CommandBroker.run(
            path: runtimePath, arguments: installArguments(hostFolder: hostPath), timeout: timeout,
            environment: installEnvironment(home: homePath, cache: cacheFolder.path),
            currentDirectory: URL(filePath: projectPath, directoryHint: .isDirectory))
        let output = [run.stdout, run.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if run.timedOut {
            return result(.failed, "Installing its packages took longer than \(timeout.components.seconds) seconds.", output)
        }
        guard run.status == 0 else {
            return result(.failed, "Installing its packages failed (bun install exited with \(run.status)). See the plugin's log.", output)
        }
        do {
            let installed = project.appending(path: "node_modules", directoryHint: .isDirectory)
            try removeBinFolders(in: installed)
            // Something may have created node_modules meanwhile; ours replaces it.
            guard removeNodeModules(in: folder) else { throw CocoaError(.fileWriteNoPermission) }
            try fm.moveItem(at: installed, to: folder.appending(path: "node_modules", directoryHint: .isDirectory))
        } catch {
            return result(.failed, "Couldn't put the installed packages in place: \(error.localizedDescription)", output)
        }
        return result(.installed, count == 1 ? "Installed 1 package" : "Installed \(count) packages", output)
    }

    /// Lowercase hex SHA-256, as in `PluginFingerprint.fileHashes`.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes `<folder>/node_modules` if there is one; false if it is still there afterwards.
    /// `removeItem` deletes a symlink itself, never what it points to.
    @discardableResult
    public static func removeNodeModules(in folder: URL) -> Bool {
        let fm = FileManager.default
        let nodeModules = folder.appending(path: "node_modules")
        guard (try? fm.attributesOfItem(atPath: nodeModules.path)) != nil else { return true }
        return (try? fm.removeItem(at: nodeModules)) != nil
    }

    /// Deletes every `.bin` folder directly inside a `node_modules` folder, at any depth under
    /// `nodeModules`. Walks without following symlinks.
    static func removeBinFolders(in nodeModules: URL) throws {
        let fm = FileManager.default
        func walk(_ dir: URL) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path) {
                let url = dir.appending(path: name)
                guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { continue }
                if name == ".bin" && dir.lastPathComponent == "node_modules" {
                    try fm.removeItem(at: url)
                } else {
                    try walk(url)
                }
            }
        }
        guard (try? fm.attributesOfItem(atPath: nodeModules.path)[.type] as? FileAttributeType) == .typeDirectory else { return }
        try walk(nodeModules)
    }
}
