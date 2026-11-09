import Foundation
import Testing
@testable import SingularityCore

/// Core pieces behind the app's PluginManager, Settings → Plugins and the approval sheet.
@Suite struct PluginManagerLogicTests {
    private var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/plugins")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sing-pm-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func copyFixture(_ name: String, as folderName: String? = nil) throws -> URL {
        let dest = try tempDir().appending(path: folderName ?? name, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtures.appending(path: name, directoryHint: .isDirectory), to: dest)
        return dest
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func approval(for scan: PluginScan, spaces: Set<UUID> = [UUID()], dev: Bool = false,
                          paths: [String: String] = [:]) throws -> PluginApproval {
        let manifest = try #require(scan.validManifest)
        let snapshot = try scan.files.get()
        return PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions, commandPaths: paths,
                              enabledSpaces: spaces, developmentMode: dev, approvedAt: Date(),
                              fileHashes: snapshot.fileHashes)
    }

    // MARK: fileHashes

    @Test func fileHashesMatchTheFingerprintWalk() throws {
        let folder = try copyFixture("ok-1password")
        try write("x", folder.appending(path: "node_modules/a/index.js"))
        try write("y", folder.appending(path: ".hidden.js"))
        try write("z", folder.appending(path: ".DS_Store"))
        try write("g", folder.appending(path: ".git/HEAD"))
        let hashes = try PluginFingerprint.fileHashes(folder: folder)
        #expect(Set(hashes.keys) == ["plugin.json", "page.ts", "background.ts", "node_modules/a/index.js", ".hidden.js"])
        // SHA-256 of "x".
        #expect(hashes["node_modules/a/index.js"] == "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
        let snapshot = try PluginFingerprint.snapshot(folder: folder)
        #expect(snapshot.fingerprint == (try PluginFingerprint.compute(folder: folder)))
        #expect(snapshot.fileHashes == hashes)
    }

    @Test func fileHashesRefuseSymlinksLikeCompute() throws {
        let folder = try copyFixture("ok-1password")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link.ts").path, withDestinationPath: "/etc/hosts")
        #expect(throws: PluginError.symlinkNotAllowed("link.ts")) { try PluginFingerprint.fileHashes(folder: folder) }
    }

    @Test func approvalFileHashesDefaultToEmptyAndRoundTrip() throws {
        let dir = try tempDir()
        let file = dir.appending(path: "plugins-state.json")
        // A state file written before fileHashes existed.
        let old = """
        {"echo":{"approvedAt":"2026-11-01T10:00:00.000Z","commandPaths":{},"developmentMode":false,
        "enabledSpaces":[],"fingerprint":"ab","permissions":{"commands":{},"fillForms":[],"network":[],"pageAdditions":[]}}}
        """
        try old.write(to: file, atomically: true, encoding: .utf8)
        let store = PluginStateStore(file: file)
        let loaded = try #require(store.load()["echo"])
        #expect(loaded.fileHashes == [:])
        #expect(loaded.fingerprint == "ab")

        var updated = loaded
        updated.fileHashes = ["a.ts": "11", "b/c.ts": "22"]
        try store.save(["echo": updated])
        #expect(store.load()["echo"]?.fileHashes == ["a.ts": "11", "b/c.ts": "22"])
    }

    @Test func corruptStateFileIsSetAside() throws {
        let dir = try tempDir()
        let file = dir.appending(path: "plugins-state.json")
        let store = PluginStateStore(file: file)
        #expect(store.read() == .missing)
        #expect(store.loadSettingAsideCorrupt().wasCorrupt == false)

        try store.save([:])
        #expect(store.read() == .loaded([:]))

        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(store.read() == .corrupt)
        let result = store.loadSettingAsideCorrupt(now: Date(timeIntervalSince1970: 0))
        #expect(result.wasCorrupt && result.approvals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = dir.appending(path: "plugins-state.corrupt-1970-01-01T00-00-00.000Z.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
        #expect(store.read() == .missing)
    }

    // MARK: Refresh plan

    @Test func refreshPlan() {
        let onDisk: Set = ["a", "b", "new"], known: Set = ["a", "b", "gone"]
        #expect(PluginRefreshPlan.ids(changedPaths: ["a/x.ts", "a/y.ts", ".staging/z"], onDisk: onDisk, known: known)
                == ["a", "new", "gone"])
        // Dropped or unmappable events: everything.
        #expect(PluginRefreshPlan.ids(changedPaths: [], onDisk: onDisk, known: known) == ["a", "b", "new", "gone"])
        #expect(PluginRefreshPlan.ids(changedPaths: [], onDisk: [".hidden"], known: []) == [])
    }

    // MARK: Changed files

    @Test func fileChangesListAddedRemovedChanged() {
        let changes = PluginFileChanges(approved: ["a": "1", "b": "2", "c": "3"], current: ["a": "1", "b": "9", "d": "4", "e": "5"])
        #expect(changes.added == ["d", "e"])
        #expect(changes.removed == ["c"])
        #expect(changes.changed == ["b"])
        #expect(!changes.isEmpty)
        #expect(PluginFileChanges(approved: ["a": "1"], current: ["a": "1"]).isEmpty)
    }

    // MARK: Scan and status

    @Test func scanStatusFollowsTheApproval() throws {
        let folder = try copyFixture("echo")
        let scan = PluginScan.scan(folder: folder)
        #expect(scan.status(approval: nil) == .new)
        let approved = try approval(for: scan)
        #expect(scan.status(approval: approved) == .approved)

        try write("// edited", folder.appending(path: "background.ts"))
        let edited = PluginScan.scan(folder: folder)
        #expect(edited.status(approval: approved) == .changed)
        var dev = approved; dev.developmentMode = true
        #expect(edited.status(approval: dev) == .approved)
    }

    @Test func scanReportsBrokenManifestBeforeBrokenFiles() throws {
        let folder = try copyFixture("echo")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "x").path, withDestinationPath: "/etc")
        #expect(PluginScan.scan(folder: folder).status(approval: nil) == .invalid(.symlinkNotAllowed("x")))
        try write("{", folder.appending(path: "plugin.json"))
        guard case .invalid(.invalidJSON) = PluginScan.scan(folder: folder).status(approval: nil) else {
            Issue.record("expected invalidJSON"); return
        }
    }

    // MARK: Launch decision

    @Test func launchDecision() throws {
        let scan = PluginScan.scan(folder: try copyFixture("echo"))
        let manifest = try #require(scan.validManifest)
        let ok = try approval(for: scan, paths: ["echo": "/bin/echo"])
        let yes: (String) -> Bool = { _ in true }

        #expect(PluginLaunch.decide(status: .approved, approval: ok, manifest: manifest, isExecutable: yes) == .launch)
        for status in [PluginStatus.new, .changed, .permissionsWidened, .invalid(.missingLockfile)] {
            #expect(PluginLaunch.decide(status: status, approval: ok, manifest: manifest, isExecutable: yes) == .notApproved)
        }
        #expect(PluginLaunch.decide(status: .approved, approval: nil, manifest: manifest, isExecutable: yes) == .notApproved)

        var off = ok; off.enabledSpaces = []
        #expect(PluginLaunch.decide(status: .approved, approval: off, manifest: manifest, isExecutable: yes) == .switchedOff)

        var pageOnly = manifest; pageOnly.background = nil
        #expect(PluginLaunch.decide(status: .approved, approval: ok, manifest: pageOnly, isExecutable: yes) == .nothingToRun)

        #expect(PluginLaunch.decide(status: .approved, approval: ok, manifest: manifest, isExecutable: { _ in false })
                == .blocked("echo isn't at /bin/echo any more — review to re-approve"))
        // Re-vetted at every launch: a pinned path that is (now) a refused program, or a link to one.
        var shell = ok; shell.commandPaths = ["echo": "/bin/zsh"]
        #expect(PluginLaunch.decide(status: .approved, approval: shell, manifest: manifest)
                == .blocked("/bin/zsh is now a program plugins may not run — review to re-approve"))
        let link = try tempDir().appending(path: "echo")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/echo")
        var linked = ok; linked.commandPaths = ["echo": link.path]
        #expect(PluginLaunch.decide(status: .approved, approval: linked, manifest: manifest) == .launch)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
        #expect(PluginLaunch.decide(status: .approved, approval: linked, manifest: manifest)
                == .blocked("\(link.path) is now a program plugins may not run — review to re-approve"))
        #expect(PluginLaunch.decide(status: .approved, approval: ok, manifest: manifest, isExecutable: yes,
                                    isAllowedProgram: { _ in false })
                == .blocked("/bin/echo is now a program plugins may not run — review to re-approve"))
        var unpinned = ok; unpinned.commandPaths = [:]
        #expect(PluginLaunch.decide(status: .approved, approval: unpinned, manifest: manifest, isExecutable: yes)
                == .blocked("no approved path for echo — review to re-approve"))
    }

    @Test func executableRegularFileCheck() throws {
        #expect(PluginLaunch.isExecutableRegularFile("/bin/echo"))
        #expect(!PluginLaunch.isExecutableRegularFile("/bin"))              // a folder
        #expect(!PluginLaunch.isExecutableRegularFile("/etc/hosts"))        // not executable
        #expect(!PluginLaunch.isExecutableRegularFile("/nonexistent/op"))
        #expect(!PluginLaunch.isExecutableRegularFile("echo"))              // not absolute
        let dir = try tempDir()
        let link = dir.appending(path: "op")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/echo")
        #expect(PluginLaunch.isExecutableRegularFile(link.path))           // links are followed
    }

    // MARK: Status text

    @Test func statusTexts() {
        func text(_ s: PluginStatus, _ d: PluginLaunch.Decision = .launch, _ r: PluginSupervisor.State = .running) -> String {
            PluginStatusText.describe(status: s, decision: d, run: r).text
        }
        #expect(text(.new) == "Waiting for your approval")
        #expect(text(.changed) == "Changed since you approved it")
        #expect(text(.permissionsWidened) == "Asks for more permissions")
        #expect(text(.invalid(.invalidJSON("keyNotFound(CodingKeys(...))"))) == "Problem: plugin.json isn't valid JSON")
        #expect(text(.approved) == "On")
        #expect(text(.approved, .launch, .stopped) == "On")
        #expect(text(.approved, .nothingToRun) == "On")
        #expect(text(.approved, .switchedOff) == "Off in every Space")
        #expect(text(.approved, .blocked("op isn't at /x any more — review to re-approve"))
                == "Problem: op isn't at /x any more — review to re-approve")
        #expect(text(.approved, .launch, .crashedRepeatedly).hasPrefix("Problem: "))
        #expect(text(.approved, .launch, .failedToStart("x")).hasPrefix("Problem: "))
        #expect(PluginStatusText.describe(status: .approved, decision: .launch, run: .running).tone == .on)
        #expect(PluginStatusText.describe(status: .new, decision: .notApproved, run: .stopped).tone == .attention)
    }

    @Test func reviewNotice() {
        func needs(_ s: PluginStatus, _ d: PluginLaunch.Decision = .launch, _ r: PluginSupervisor.State = .running,
                   page: Bool = false) -> Bool {
            PluginStatusText.needsReview(status: s, decision: d, run: r, hasPageProblem: page)
        }
        #expect(needs(.new, .notApproved, .stopped))
        #expect(needs(.changed, .notApproved, .stopped))
        #expect(needs(.permissionsWidened, .notApproved, .stopped))
        #expect(needs(.invalid(.missingFile("background.ts")), .notApproved, .stopped))
        #expect(needs(.approved, .blocked("op isn't at /x any more — review to re-approve")))
        #expect(needs(.approved, .launch, .crashedRepeatedly))
        #expect(needs(.approved, .launch, .failedToStart("x")))
        #expect(needs(.approved, page: true))
        #expect(!needs(.approved))
        #expect(!needs(.approved, .switchedOff, .stopped))
        #expect(!needs(.approved, .nothingToRun, .stopped))

        #expect(PluginStatusText.reviewTitle(count: 0) == nil)
        #expect(PluginStatusText.reviewTitle(count: 1) == "Plugins: 1 needs your review")
        #expect(PluginStatusText.reviewTitle(count: 3) == "Plugins: 3 need your review")
    }

    @Test func developmentModeCanOnlyBeSwitchedOnWhileApproved() {
        #expect(PluginStatusText.canSetDevelopmentMode(to: true, status: .approved))
        #expect(!PluginStatusText.canSetDevelopmentMode(to: true, status: .changed))
        #expect(!PluginStatusText.canSetDevelopmentMode(to: true, status: .permissionsWidened))
        #expect(PluginStatusText.canSetDevelopmentMode(to: false, status: .changed))
    }

    @Test func errorMessagesArePlainSentences() {
        let dump = "keyNotFound(CodingKeys(stringValue: \"version\", intValue: nil), Swift.DecodingError.Context(...))"
        #expect(PluginError.invalidJSON(dump).userMessage == "plugin.json isn't valid JSON")
        #expect(PluginError.invalidJSON(dump).detail == dump)
        #expect(PluginError.invalidJSON("package.json: not an object").userMessage == "package.json isn't valid")
        #expect(PluginError.symlinkNotAllowed(".").userMessage == "its folder is a symbolic link")
        #expect(PluginError.symlinkNotAllowed("a/b").userMessage == "it contains a symbolic link (a/b)")
        #expect(PluginError.missingLockfile.userMessage == "it uses packages but has no bun.lock")
    }

    // MARK: Review

    @Test func reviewSnapshotsAndMatches() throws {
        let folder = try copyFixture("echo")
        try write("# Echo\nSays things back.", folder.appending(path: "README.md"))
        let scan = PluginScan.scan(folder: folder)
        let review = try PluginReview.prepare(scan: scan, resolve: { $0 == "echo" ? "/bin/echo" : nil }).get()
        #expect(review.id == "echo")
        #expect(review.readme == "# Echo\nSays things back.")
        #expect(review.commandPaths == ["echo": "/bin/echo"])
        #expect(review.missingCommands.isEmpty && review.canApprove)
        #expect(review.permissionLines.contains("Runs /bin/echo (only: hello — plus any further arguments)"))
        #expect(review.changes(since: nil) == nil)
        #expect(review.matches(scan))
        #expect(review.matches(PluginScan.scan(folder: folder)))

        // Edited while the sheet was open: no longer matches.
        try write("// edited", folder.appending(path: "background.ts"))
        #expect(!review.matches(PluginScan.scan(folder: folder)))

        let missing = try PluginReview.prepare(scan: scan, resolve: { _ in nil }).get()
        #expect(missing.missingCommands == ["echo"])
        #expect(!missing.canApprove)
    }

    @Test func reviewListsChangedFilesSinceApproval() throws {
        let folder = try copyFixture("echo")
        let approved = try approval(for: PluginScan.scan(folder: folder))
        try write("// edited", folder.appending(path: "background.ts"))
        try write("new", folder.appending(path: "lib/util.ts"))
        let review = try PluginReview.prepare(scan: PluginScan.scan(folder: folder), resolve: { _ in "/bin/echo" }).get()
        let changes = try #require(review.changes(since: approved))
        #expect(changes.added == ["lib/util.ts"])
        #expect(changes.changed == ["background.ts"])
        #expect(changes.removed.isEmpty)
        var legacy = approved; legacy.fileHashes = [:]
        #expect(review.changes(since: legacy) == nil)
    }

    @Test func reviewFailsForBrokenPlugins() throws {
        let folder = try copyFixture("echo")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "README.md").path, withDestinationPath: "/etc/hosts")
        let result = PluginReview.prepare(scan: PluginScan.scan(folder: folder), resolve: { _ in "/bin/echo" })
        #expect(throws: PluginError.symlinkNotAllowed("README.md")) { try result.get() }
    }

    @Test func readmeIsCutAndNotFollowedThroughLinks() throws {
        let folder = try copyFixture("echo")
        try write(String(repeating: "a", count: PluginReview.readmeLimit + 50), folder.appending(path: "README.md"))
        let text = try #require(PluginReview.readReadme(in: folder))
        #expect(text.count == PluginReview.readmeLimit)
        #expect(text.hasSuffix("…"))
    }

    // MARK: Plain text

    @Test func pluginTextIsCleanedAndCut() {
        #expect(PluginText.line("Evil\nName\t!", max: 50) == "Evil Name !")
        #expect(PluginText.line("abc\u{202E}def", max: 50) == "abcdef")
        #expect(PluginText.line("abcdef", max: 4) == "abc…")
        #expect(PluginText.line("abc", max: 3) == "abc")
        #expect(PluginText.block("a\nb\u{0007}c\u{2066}", max: 50) == "a\nbc")
    }

    // MARK: Add Plugin

    @Test func addCopiesIntoAFolderNamedAfterTheID() throws {
        let source = try copyFixture("echo", as: "echo-main")   // folder name differs from the id
        let plugins = try tempDir().appending(path: "plugins", directoryHint: .isDirectory)
        let id = try PluginInstaller.add(from: source, pluginsDirectory: plugins)
        #expect(id == "echo")
        let installed = plugins.appending(path: "echo")
        #expect(try PluginManifest.load(from: installed).id == "echo")
        #expect(try PluginFingerprint.compute(folder: installed) != "")
        // Only the plugin ends up in the plugins folder (the staging folder is elsewhere and gone).
        #expect(try FileManager.default.contentsOfDirectory(atPath: plugins.path) == ["echo"])

        // A second copy with the same id is refused, and the installed one is untouched.
        #expect(throws: PluginInstaller.AddError.alreadyInstalled("echo")) {
            try PluginInstaller.add(from: source, pluginsDirectory: plugins)
        }
    }

    @Test func addRefusesBrokenOrLinkedFolders() throws {
        let plugins = try tempDir().appending(path: "plugins", directoryHint: .isDirectory)

        #expect(throws: PluginInstaller.AddError.invalid(.networkNotAvailable)) {
            try PluginInstaller.add(from: fixtures.appending(path: "bad-network"), pluginsDirectory: plugins)
        }
        let linked = try copyFixture("echo")
        try FileManager.default.createSymbolicLink(atPath: linked.appending(path: "secret").path, withDestinationPath: "/etc/hosts")
        #expect(throws: PluginInstaller.AddError.invalid(.symlinkNotAllowed("secret"))) {
            try PluginInstaller.add(from: linked, pluginsDirectory: plugins)
        }
        let target = try copyFixture("echo")
        let link = try tempDir().appending(path: "echo")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        #expect(throws: PluginInstaller.AddError.invalid(.symlinkNotAllowed("."))) {
            try PluginInstaller.add(from: link, pluginsDirectory: plugins)
        }
        let installed = try PluginInstaller.add(from: target, pluginsDirectory: plugins)
        #expect(throws: PluginInstaller.AddError.alreadyInPluginsFolder) {
            try PluginInstaller.add(from: plugins.appending(path: installed), pluginsDirectory: plugins)
        }
        // Another spelling of the same folder (realpath: /var is /private/var; a symlinked parent).
        let alias = try tempDir().appending(path: "alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: plugins.path)
        #expect(throws: PluginInstaller.AddError.alreadyInPluginsFolder) {
            try PluginInstaller.add(from: plugins.appending(path: installed), pluginsDirectory: alias)
        }
        if plugins.path.hasPrefix("/var/") {
            #expect(throws: PluginInstaller.AddError.alreadyInPluginsFolder) {
                try PluginInstaller.add(from: URL(filePath: "/private" + plugins.appending(path: installed).path),
                                        pluginsDirectory: plugins)
            }
        }
    }

    @Test func dataFolderIsOwnerOnly() throws {
        let root = try tempDir()
        let data = root.appending(path: "plugins-data/echo", directoryHint: .isDirectory)
        try PluginInstaller.makeDataFolder(data)
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode(data) == 0o700)
        #expect(try mode(data.deletingLastPathComponent()) == 0o700)
        // An existing folder with looser permissions is tightened.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
        try PluginInstaller.makeDataFolder(data)
        #expect(try mode(data) == 0o700)
    }

    // MARK: Login shell

    @Test func loginShellIsAnExecutable() {
        let shell = LoginShell.path()
        #expect(shell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
    }
}
