import Foundation

/// What one plugin folder looks like at one moment: its manifest and its files' hashes.
/// Every status decision is made from a fresh scan (see `PluginManager` in the app).
public struct PluginScan: Sendable {
    public let folder: URL
    public let manifest: Result<PluginManifest, PluginError>
    public let files: Result<PluginFingerprint.Snapshot, PluginError>

    public init(folder: URL, manifest: Result<PluginManifest, PluginError>,
                files: Result<PluginFingerprint.Snapshot, PluginError>) {
        self.folder = folder
        self.manifest = manifest
        self.files = files
    }

    /// Reads the manifest and every file. Blocking and possibly slow (node_modules): never call
    /// it on the main thread.
    public static func scan(folder: URL) -> PluginScan {
        let manifest: Result<PluginManifest, PluginError>
        do { manifest = .success(try PluginManifest.load(from: folder)) } catch { manifest = .failure(error) }
        let files: Result<PluginFingerprint.Snapshot, PluginError>
        do {
            files = .success(try PluginFingerprint.snapshot(folder: folder))
        } catch let error as PluginError {
            files = .failure(error)
        } catch {
            files = .failure(.unreadable(error.localizedDescription))
        }
        return PluginScan(folder: folder, manifest: manifest, files: files)
    }

    /// The manifest when both it and the files are fine.
    public var validManifest: PluginManifest? {
        guard case .success(let m) = manifest, case .success = files else { return nil }
        return m
    }

    /// The fingerprint and per-file hashes, when the files could be read.
    public var snapshot: PluginFingerprint.Snapshot? {
        if case .success(let snapshot) = files { return snapshot }
        return nil
    }

    public var fingerprint: String? {
        if case .success(let snapshot) = files { return snapshot.fingerprint }
        return nil
    }

    /// A broken manifest wins over unreadable files; otherwise `PluginStatus.evaluate`.
    public func status(approval: PluginApproval?) -> PluginStatus {
        if case .failure(let error) = manifest { return .invalid(error) }
        switch files {
        case .failure(let error): return .invalid(error)
        case .success(let snapshot):
            return PluginStatus.evaluate(manifest: manifest, fingerprint: snapshot.fingerprint,
                                         fileHashes: snapshot.fileHashes, approval: approval)
        }
    }
}

// MARK: - Launching

/// Whether a plugin's background program should be running right now.
public enum PluginLaunch {
    public enum Decision: Equatable, Sendable {
        case launch
        /// New, changed, asking for more, or broken: the status says why.
        case notApproved
        /// Approved, but not switched on in any Space.
        case switchedOff
        /// Approved and on, but it has no background program (page script only).
        case nothingToRun
        /// Approved and on, but something it needs is gone. The text is shown after "Problem: ".
        case blocked(String)
    }

    /// Run only when the plugin is approved, switched on in at least one Space, has a background
    /// program, and every pinned command path is still an executable file.
    public static func decide(status: PluginStatus, approval: PluginApproval?, manifest: PluginManifest?,
                              isExecutable: (String) -> Bool = isExecutableRegularFile) -> Decision {
        guard status == .approved, let approval, let manifest else { return .notApproved }
        guard !approval.enabledSpaces.isEmpty else { return .switchedOff }
        guard manifest.background != nil else { return .nothingToRun }
        for (name, path) in approval.commandPaths.sorted(by: { $0.key < $1.key }) where !isExecutable(path) {
            return .blocked("\(name) isn't at \(path) any more — review to re-approve")
        }
        for name in manifest.permissions.commands.keys.sorted() where approval.commandPaths[name] == nil {
            return .blocked("no approved path for \(name) — review to re-approve")
        }
        return .launch
    }

    /// An existing regular file (after following symlinks: Homebrew's `op` is a link) that we may
    /// execute.
    public static func isExecutableRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

// MARK: - Which plugins to look at again

public enum PluginRefreshPlan {
    /// Plugin ids to refresh after file events. `changedPaths` are relative to the plugins folder
    /// (first component = plugin id); an empty list means "events arrived that couldn't be tied
    /// to a plugin, or some were dropped" and refreshes every plugin on disk or known. Folders
    /// that appeared or disappeared are always included. Names starting with "." are never plugins.
    public static func ids(changedPaths: [String], onDisk: Set<String>, known: Set<String>) -> Set<String> {
        var ids: Set<String>
        if changedPaths.isEmpty {
            ids = onDisk.union(known)
        } else {
            ids = Set(changedPaths.compactMap { $0.split(separator: "/").first.map(String.init) })
            ids.formUnion(onDisk.symmetricDifference(known))
        }
        return ids.filter { !$0.hasPrefix(".") }
    }
}

// MARK: - Status in plain words

public enum PluginStatusText {
    public enum Tone: Equatable, Sendable { case on, off, attention, problem }

    /// The status line in Settings → Plugins. `run` is the supervisor's state (`.stopped` while
    /// not running at all).
    public static func describe(status: PluginStatus, decision: PluginLaunch.Decision,
                                run: PluginSupervisor.State) -> (text: String, tone: Tone) {
        switch status {
        case .new: return ("Waiting for your approval", .attention)
        case .changed: return ("Changed since you approved it", .attention)
        case .permissionsWidened: return ("Asks for more permissions", .attention)
        case .invalid(let error): return ("Problem: " + error.userMessage, .problem)
        case .approved: break
        }
        switch decision {
        case .notApproved: return ("Waiting for your approval", .attention)   // not reached: status is approved
        case .switchedOff: return ("Off in every Space", .off)
        case .nothingToRun: return ("On", .on)
        case .blocked(let why): return ("Problem: " + why, .problem)
        case .launch: break
        }
        switch run {
        case .crashedRepeatedly: return ("Problem: it keeps crashing — see its log", .problem)
        case .failedToStart: return ("Problem: it couldn't start — see its log", .problem)
        case .running, .stopped: return ("On", .on)
        }
    }

    /// Whether the plugin needs the user to look at it: never approved, changed, asking for more,
    /// or with a problem (broken manifest, blocked launch, crashing, or a page script that can't
    /// be used). Drives the palette's "Plugins: N need your review" item.
    public static func needsReview(status: PluginStatus, decision: PluginLaunch.Decision,
                                   run: PluginSupervisor.State, hasPageProblem: Bool) -> Bool {
        switch status {
        case .new, .changed, .permissionsWidened, .invalid: return true
        case .approved: break
        }
        return hasPageProblem || describe(status: status, decision: decision, run: run).tone == .problem
    }

    /// The palette item's title for `count` plugins needing review; nil when there are none.
    public static func reviewTitle(count: Int) -> String? {
        switch count {
        case ...0: return nil
        case 1: return "Plugins: 1 needs your review"
        default: return "Plugins: \(count) need your review"
        }
    }

    /// Development mode can always be switched off, but only switched on while the plugin is
    /// approved as it is now: switching it on for a changed plugin would run the changes unreviewed.
    public static func canSetDevelopmentMode(to on: Bool, status: PluginStatus) -> Bool {
        !on || status == .approved
    }
}

// MARK: - What changed

/// Which files differ between the approved version and now (relative paths, sorted).
public struct PluginFileChanges: Equatable, Sendable {
    public let added: [String]
    public let removed: [String]
    public let changed: [String]

    public init(approved: [String: String], current: [String: String]) {
        added = current.keys.filter { approved[$0] == nil }.sorted()
        removed = approved.keys.filter { current[$0] == nil }.sorted()
        changed = current.keys.filter { approved[$0] != nil && approved[$0] != current[$0] }.sorted()
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

// MARK: - The approval sheet's snapshot

/// Exactly what the approval sheet shows. `approve` only records an approval when a fresh scan
/// still matches it (same fingerprint, same permissions), so the user never approves something
/// they weren't shown.
public struct PluginReview: Equatable, Sendable {
    public let id: String
    public let manifest: PluginManifest
    public let fingerprint: String
    public let fileHashes: [String: String]
    /// README.md, cut to `readmeLimit` characters; nil when there is none.
    public let readme: String?
    /// Program name -> the path found now; these are pinned on approval.
    public let commandPaths: [String: String]
    /// Declared programs that couldn't be found (approval is impossible until they are installed).
    public let missingCommands: [String]
    /// The npm packages Singularity installs on approval (`PluginPackages.check`).
    public let packages: PluginPackages.Summary

    public static let readmeLimit = 20_000

    public init(id: String, manifest: PluginManifest, fingerprint: String, fileHashes: [String: String],
                readme: String?, commandPaths: [String: String], missingCommands: [String],
                packages: PluginPackages.Summary = PluginPackages.Summary(packages: [], lockedCount: 0)) {
        self.id = id
        self.manifest = manifest
        self.fingerprint = fingerprint
        self.fileHashes = fileHashes
        self.readme = readme
        self.commandPaths = commandPaths
        self.missingCommands = missingCommands
        self.packages = packages
    }

    /// Builds the review from a scan. `resolve` finds a program's path (blocking; the app passes
    /// `CommandBroker.resolve` with the login shell). Fails with the scan's error for a broken plugin.
    public static func prepare(scan: PluginScan, resolve: (String) -> String?) -> Result<PluginReview, PluginError> {
        let manifest: PluginManifest
        switch scan.manifest {
        case .failure(let error): return .failure(error)
        case .success(let m): manifest = m
        }
        let snapshot: PluginFingerprint.Snapshot
        switch scan.files {
        case .failure(let error): return .failure(error)
        case .success(let s): snapshot = s
        }
        // The manifest check already validated these. The list on the sheet is built from
        // package.json and bun.lock with exactly the hashes in this snapshot (what approve will
        // install), not from whatever is on disk by now.
        let packages: PluginPackages.Summary
        do {
            guard let summary = try PluginPackages.check(folder: scan.folder, matching: snapshot.fileHashes) else {
                return .failure(.unreadable("package.json or bun.lock changed while being read; review again"))
            }
            packages = summary
        } catch { return .failure(error) }
        var paths: [String: String] = [:]
        var missing: [String] = []
        for name in manifest.permissions.commands.keys.sorted() {
            if let path = resolve(name) { paths[name] = path } else { missing.append(name) }
        }
        return .success(PluginReview(
            id: manifest.id, manifest: manifest, fingerprint: snapshot.fingerprint, fileHashes: snapshot.fileHashes,
            readme: readReadme(in: scan.folder), commandPaths: paths, missingCommands: missing, packages: packages))
    }

    public var canApprove: Bool { missingCommands.isEmpty }

    public var permissionLines: [String] {
        PermissionDescriptions.lines(for: manifest.permissions, commandPaths: commandPaths, packages: packages,
                                     hasPageScript: manifest.page != nil, hasBackground: manifest.background != nil)
    }

    /// Files changed since `approval`; nil for a first approval, or for an approval recorded
    /// before Singularity kept per-file hashes.
    public func changes(since approval: PluginApproval?) -> PluginFileChanges? {
        guard let approval, !approval.fileHashes.isEmpty else { return nil }
        return PluginFileChanges(approved: approval.fileHashes, current: fileHashes)
    }

    /// True when `scan` shows the same files and the same permissions as this review.
    public func matches(_ scan: PluginScan) -> Bool {
        guard let current = scan.validManifest, let fingerprint = scan.fingerprint else { return false }
        return fingerprint == self.fingerprint && current.permissions == manifest.permissions && current.id == id
    }

    /// README.md as text, only if it is a regular file (not a link), read up to 256 KB.
    static func readReadme(in folder: URL) -> String? {
        let url = folder.appending(path: "README.md")
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return PluginText.block(String(decoding: data, as: UTF8.self), max: readmeLimit)
    }
}

// MARK: - Showing plugin-supplied text

/// Plugin-supplied text (name, author, README, log lines, error texts) is shown as plain text,
/// never rendered as Markdown or links, and cut to a sensible length.
public enum PluginText {
    /// Characters that reorder text on screen (bidirectional overrides): dropped, so a name
    /// can't display as something it isn't.
    private static let bidiControls: Set<Unicode.Scalar> = Set(
        (0x202A...0x202E).compactMap(Unicode.Scalar.init) + (0x2066...0x2069).compactMap(Unicode.Scalar.init))

    /// One line: control characters (newlines, tabs, …) become spaces, cut to `max` characters.
    public static func line(_ text: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !bidiControls.contains(scalar) {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return cut(String(scalars).trimmingCharacters(in: .whitespaces), max: max)
    }

    /// Several lines: newlines and tabs kept, other control characters dropped, cut to `max` characters.
    public static func block(_ text: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !bidiControls.contains(scalar) {
            if scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" { continue }
            scalars.append(scalar)
        }
        return cut(String(scalars), max: max)
    }

    private static func cut(_ text: String, max: Int) -> String {
        text.count > max ? String(text.prefix(Swift.max(0, max - 1))) + "…" : text
    }
}
