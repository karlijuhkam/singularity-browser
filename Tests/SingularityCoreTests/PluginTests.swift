import Foundation
import Testing
@testable import SingularityCore

@Suite struct PluginTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func sitePatterns() throws {
        let all = try SitePattern("<all_urls>")
        #expect(all.matches(url("https://a.com/x")))
        #expect(all.matches(url("http://b.org")))
        #expect(!all.matches(url("about:blank")))
        #expect(!all.matches(url("file:///tmp/x")))

        let gh = try SitePattern("https://*.github.com/*")
        #expect(gh.matches(url("https://github.com/login")))
        #expect(gh.matches(url("https://gist.github.com/x")))
        #expect(!gh.matches(url("http://github.com/")))
        #expect(!gh.matches(url("https://evilgithub.com/")))

        let any = try SitePattern("*://example.com/*")
        #expect(any.matches(url("http://example.com/a")))
        #expect(any.matches(url("https://example.com/a")))
        #expect(!any.matches(url("ftp://example.com/a")))

        for bad in ["ftp://x/*", "https://exa*mple.com/*", "", "https://a.com:8080/*", "https://a.com"] {
            #expect(throws: PluginError.invalidSitePattern(bad)) { _ = try SitePattern(bad) }
        }
    }

    @Test func sitePatternDetails() throws {
        let p = try SitePattern("https://example.com/*")
        #expect(p.matches(url("https://EXAMPLE.com/a")))
        #expect(p.matches(url("https://example.com./a")))
        #expect(p.matches(url("https://example.com:8443/a")))
        #expect(p.matches(url("https://example.com")))

        let upper = try SitePattern("https://Example.COM./*")
        #expect(upper.matches(url("https://example.com/")))

        let path = try SitePattern("https://a.com/docs/*/edit")
        #expect(path.matches(url("https://a.com/docs/x/y/edit")))
        #expect(!path.matches(url("https://a.com/docs/x/edit/more")))

        let query = try SitePattern("https://a.com/s?q=*")
        #expect(query.matches(url("https://a.com/s?q=hi")))
        #expect(!query.matches(url("https://a.com/s")))

        let star = try SitePattern("https://*/*")
        #expect(star.matches(url("https://anything.dev/x")))
    }

    @Test func hostMatching() {
        #expect(HostMatch.isSameOrSubdomain("www.github.com", of: "github.com"))
        #expect(HostMatch.isSameOrSubdomain("github.com", of: "github.com"))
        #expect(!HostMatch.isSameOrSubdomain("github.com", of: "www.github.com"))
        #expect(!HostMatch.isSameOrSubdomain("evilgithub.com", of: "github.com"))
        #expect(HostMatch.isSameOrSubdomain("WWW.GitHub.com.", of: "github.COM"))
    }

    @Test func negativeMatches() throws {
        let gh = try SitePattern("https://*.github.com/*")
        for u in ["https://github.com.evil.com/", "https://evil.com/?x=github.com",
                  "https://github.com@evil.com/", "https://.github.com/"] {
            #expect(!gh.matches(url(u)), "\(u)")
        }
        let ex = try SitePattern("https://example.com/*")
        #expect(!ex.matches(url("https://www.example.com/")))
        #expect(!ex.matches(url("https://evilexample.com/")))
        for p in ["<all_urls>", "*://*/*"] {
            let sp = try SitePattern(p)
            #expect(!sp.matches(url("ws://a.com/")))
            #expect(!sp.matches(url("file:///etc/hosts")))
        }
        for bad in ["https://*./*", "https://*.*.com/*", "https://user@github.com/*",
                    "https://.github.com/*", "https://a..b.com/*", "https://a.com?x/*", "https://a b.com/*"] {
            #expect(throws: PluginError.invalidSitePattern(bad)) { _ = try SitePattern(bad) }
        }
        #expect(!HostMatch.isSameOrSubdomain(".github.com", of: "github.com"))
        #expect(!HostMatch.isSameOrSubdomain("a..github.com", of: "github.com"))
        #expect(!HostMatch.isSameOrSubdomain("", of: ""))
    }

    @Test func pathLiterals() throws {
        let p = try SitePattern("https://a.com/a.b+c(d)*")
        #expect(p.matches(url("https://a.com/a.b+c(d)x")))
        #expect(!p.matches(url("https://a.com/aXb+c(d)x")))
    }

    // MARK: Manifest

    private var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/plugins")
    }

    private func load(_ name: String) throws -> PluginManifest {
        try PluginManifest.load(from: fixtures.appending(path: name, directoryHint: .isDirectory))
    }

    @Test func manifestLoadsAndValidates() throws {
        let m = try load("ok-1password")
        #expect(m.id == "ok-1password")
        #expect(m.permissions.commands == ["op": ["item list", "item get"]])
        #expect(m.permissions.network.isEmpty)
        #expect(m.page?.script == "page.ts")
    }

    @Test func manifestRejections() {
        #expect(throws: PluginError.networkNotAvailable) { _ = try load("bad-network") }
        #expect(throws: PluginError.refusedCommand("sh")) { _ = try load("bad-shell") }
        #expect(throws: PluginError.unknownPermission("cookies")) { _ = try load("bad-key") }
        #expect(throws: PluginError.invalidID("Other")) { _ = try load("bad-id") }
        #expect(throws: PluginError.missingFile("nothere.ts")) { _ = try load("missing-file") }
        #expect(throws: PluginError.missingLockfile) { _ = try load("bad-lockfile") }
        #expect(throws: PluginError.self) { _ = try load("does-not-exist") }
    }

    /// Copies ok-1password into a temp folder named `folder`, with `plugin.json` replaced by `json`.
    private func temp(folder: String, json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
        return dir
    }

    private func manifestJSON(id: String = "t", background: String = "background.ts",
                              permissions: String = "{}", extra: String = "") -> String {
        """
        {"id":"\(id)","name":"T","version":"1","description":"d","author":"a",
         "background":"\(background)","permissions":\(permissions)\(extra)}
        """
    }

    @Test func manifestEdgeCases() throws {
        func fails(_ error: PluginError, _ json: String, folder: String = "t") throws {
            let dir = try temp(folder: folder, json: json)
            #expect(throws: error) { _ = try PluginManifest.load(from: dir) }
        }
        try fails(.idDoesNotMatchFolder(id: "t", folder: "other"), manifestJSON(), folder: "other")
        try fails(.refusedCommand("../bin/op"), manifestJSON(permissions: #"{"commands":{"../bin/op":["a"]}}"#))
        try fails(.refusedCommand("my op"), manifestJSON(permissions: #"{"commands":{"my op":["a"]}}"#))
        try fails(.refusedCommand("op"), manifestJSON(permissions: #"{"commands":{"op":[]}}"#))
        try fails(.refusedCommand("op"), manifestJSON(permissions: #"{"commands":{"op":["item list"," "]}}"#))
        try fails(.missingFile("../x.ts"), manifestJSON(background: "../x.ts"))
        try fails(.missingFile("/etc/passwd"), manifestJSON(background: "/etc/passwd"))
        try fails(.invalidSitePattern("nope"), manifestJSON(permissions: #"{"fillForms":["nope"]}"#))
        
    }

    @Test func manifestMissingFieldIsInvalidJSON() throws {
        let dir = try temp(folder: "t", json: #"{"id":"t"}"#)
        do { _ = try PluginManifest.load(from: dir); Issue.record("should throw") }
        catch { if case .invalidJSON = error {} else { Issue.record("wrong error \(error)") } }
    }

    @Test func commandPolicy() {
        let declared = ["op": ["item list", "item get"]]
        #expect(CommandPolicy.allows(command: "op", arguments: ["item", "list", "--format", "json"], declared: declared))
        #expect(!CommandPolicy.allows(command: "op", arguments: ["item", "create"], declared: declared))
        #expect(!CommandPolicy.allows(command: "op", arguments: [], declared: declared))
        #expect(!CommandPolicy.allows(command: "op", arguments: ["Item", "list"], declared: declared))
        #expect(!CommandPolicy.allows(command: "other", arguments: ["item", "list"], declared: declared))
        #expect(!CommandPolicy.allows(command: "op", arguments: ["item"], declared: ["op": []]))
        for name in CommandPolicy.refused {
            #expect(!CommandPolicy.allows(command: name, arguments: ["x"], declared: [name: ["x"]]))
        }
    }

    // MARK: Fix round 1

    @Test func refusedNameVariants() throws {
        for name in ["Bash", "SH", "Python3", "python3.12", "zsh-5.9", "nodejs", "perl5.34", "ruby3.2", "php8.2"] {
            #expect(CommandPolicy.isRefused(name), "\(name)")
            #expect(!CommandPolicy.allows(command: name, arguments: ["x"], declared: [name: ["x"]]))
            let dir = try temp(folder: "t", json: manifestJSON(permissions: "{\"commands\":{\"\(name)\":[\"x\"]}}"))
            #expect(throws: PluginError.refusedCommand(name)) { _ = try PluginManifest.load(from: dir) }
        }
        // Final review: programs that run other programs.
        for name in ["arch", "caffeinate", "time", "timeout", "gtimeout", "stdbuf", "watch", "script", "sandbox-exec",
                     "taskpolicy", "ssh-agent", "xcrun", "find", "tmux", "screen", "lldb", "gdb", "sqlite3",
                     "vim", "vi", "ex", "nvim", "emacs", "Caffeinate", "sqlite3.45"] {
            #expect(CommandPolicy.isRefused(name), "\(name)")
            #expect(!CommandPolicy.allows(command: name, arguments: ["x"], declared: [name: ["x"]]))
        }
        for name in ["op", "op2"] {
            #expect(!CommandPolicy.isRefused(name))
            #expect(CommandPolicy.allows(command: name, arguments: ["x"], declared: [name: ["x"]]))
        }
        for name in ["-c", ".", ".."] {
            let dir = try temp(folder: "t", json: manifestJSON(permissions: "{\"commands\":{\"\(name)\":[\"x\"]}}"))
            #expect(throws: PluginError.refusedCommand(name)) { _ = try PluginManifest.load(from: dir) }
        }
    }

    @Test func packageJSONFailsClosed() throws {
        func load(package: String?, lockAsDirectory: Bool = false) throws -> PluginError? {
            let dir = try temp(folder: "t", json: manifestJSON())
            if let package { try Data(package.utf8).write(to: dir.appending(path: "package.json")) }
            if lockAsDirectory {
                try FileManager.default.createDirectory(at: dir.appending(path: "bun.lock"), withIntermediateDirectories: false)
            }
            do { _ = try PluginManifest.load(from: dir); return nil } catch { return error }
        }
        if case .invalidJSON? = try load(package: #"{"dependencies":{"a":"1"},}"#) {} else { Issue.record("trailing comma") }
        if case .invalidJSON? = try load(package: #"[]"#) {} else { Issue.record("not object") }
        if case .invalidJSON? = try load(package: #"{"dependencies":[]}"#) {} else { Issue.record("deps not object") }
        #expect(try load(package: #"{"devDependencies":{"a":"1.0.0"}}"#) == .unsupportedPackage("devDependencies"))
        #expect(try load(package: #"{"dependencies":{"a":"1.0.0"}}"#, lockAsDirectory: true) == .missingLockfile)
        // Duplicate keys: which one would Bun use? Refused rather than guessed.
        if case .invalidJSON? = try load(package: #"{"dependencies":{"a":"1.0.0","a":"2.0.0"}}"#) {} else { Issue.record("duplicate key") }
        #expect(try load(package: #"{"dependencies":{}}"#) == nil)
        #expect(try load(package: nil) == nil)
    }

    @Test func pageSitesMustBeCovered() throws {
        let page = #","page":{"script":"background.ts","sites":["<all_urls>"]}"#
        var dir = try temp(folder: "t", json: manifestJSON(extra: page))
        #expect(throws: PluginError.pageSiteNotPermitted("<all_urls>")) { _ = try PluginManifest.load(from: dir) }
        dir = try temp(folder: "t", json: manifestJSON(permissions: #"{"pageAdditions":["<all_urls>"]}"#, extra: page))
        _ = try PluginManifest.load(from: dir)
        let one = #","page":{"script":"background.ts","sites":["https://a.com/*"]}"#
        dir = try temp(folder: "t", json: manifestJSON(permissions: #"{"pageAdditions":["https://b.com/*"]}"#, extra: one))
        #expect(throws: PluginError.pageSiteNotPermitted("https://a.com/*")) { _ = try PluginManifest.load(from: dir) }
        dir = try temp(folder: "t", json: manifestJSON(extra: #","page":{"script":"background.ts","sites":[]}"#))
        _ = try PluginManifest.load(from: dir)
    }
}

// MARK: - Approvals, status, sandbox profile, permission texts

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")

@Suite struct PluginApprovalTests {
    private var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/plugins")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sing-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a fixture to a temp folder so tests can edit it.
    private func copyFixture(_ name: String) throws -> URL {
        let dest = try tempDir().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtures.appending(path: name, directoryHint: .isDirectory), to: dest)
        return dest
    }

    private func onePassword() throws -> PluginManifest {
        try PluginManifest.load(from: fixtures.appending(path: "ok-1password", directoryHint: .isDirectory))
    }

    private func approval(_ p: PluginManifest.Permissions, fingerprint: String = "aa", dev: Bool = false,
                          hashes: [String: String] = [:]) -> PluginApproval {
        PluginApproval(fingerprint: fingerprint, permissions: p, commandPaths: [:],
                       enabledSpaces: [], developmentMode: dev, approvedAt: Date(timeIntervalSince1970: 0),
                       fileHashes: hashes)
    }

    // MARK: Fingerprint

    @Test func fingerprintChangesWithContent() throws {
        let folder = try copyFixture("ok-1password")
        let before = try PluginFingerprint.compute(folder: folder)
        #expect(before.count == 64)
        #expect(before == (try PluginFingerprint.compute(folder: folder)))

        try "x".write(to: folder.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        try "x".write(to: folder.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appending(path: "lib"), withIntermediateDirectories: true)
        try "x".write(to: folder.appending(path: "lib/.DS_Store"), atomically: true, encoding: .utf8)
        // Top-level .git and .DS_Store files never count.
        #expect(try PluginFingerprint.compute(folder: folder) == before)

        // node_modules counts at every depth, and a nested .git counts.
        let nm = folder.appending(path: "node_modules/x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try "junk".write(to: nm.appending(path: "index.js"), atomically: true, encoding: .utf8)
        try "// edit".write(to: nm.appending(path: "index.js"), atomically: true, encoding: .utf8)
        let afterTop = try PluginFingerprint.compute(folder: folder)
        #expect(afterTop != before)
        let nested = folder.appending(path: "lib/node_modules/x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "a".write(to: nested.appending(path: "index.js"), atomically: true, encoding: .utf8)
        let afterNested = try PluginFingerprint.compute(folder: folder)
        #expect(afterNested != afterTop)
        try FileManager.default.createDirectory(at: folder.appending(path: "lib/.git"), withIntermediateDirectories: true)
        try "p".write(to: folder.appending(path: "lib/.git/p.js"), atomically: true, encoding: .utf8)
        #expect(try PluginFingerprint.compute(folder: folder) != afterNested)
        try? FileManager.default.removeItem(at: nm)
        try? FileManager.default.removeItem(at: folder.appending(path: "lib"))
        #expect(try PluginFingerprint.compute(folder: folder) == before)

        try "// edited".write(to: folder.appending(path: "page.ts"), atomically: true, encoding: .utf8)
        #expect(try PluginFingerprint.compute(folder: folder) != before)
    }

    @Test func fingerprintRefusesSymlinkedRootAndSpecialFiles() throws {
        let folder = try copyFixture("ok-1password")
        let link = try tempDir().appending(path: "ok-1password")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(throws: PluginError.symlinkNotAllowed(".")) { _ = try PluginFingerprint.compute(folder: link) }

        #expect(Darwin.mkfifo(folder.appending(path: "pipe").path, 0o600) == 0)
        #expect(throws: PluginError.unsupportedFile("pipe")) { _ = try PluginFingerprint.compute(folder: folder) }
    }

    @Test func fingerprintCountsDotfilesAndNewFiles() throws {
        let folder = try copyFixture("ok-1password")
        let base = try PluginFingerprint.compute(folder: folder)
        try "registry=evil".write(to: folder.appending(path: ".npmrc"), atomically: true, encoding: .utf8)
        let withNpmrc = try PluginFingerprint.compute(folder: folder)
        #expect(withNpmrc != base)
        try "preload=x".write(to: folder.appending(path: "bunfig.toml"), atomically: true, encoding: .utf8)
        #expect(try PluginFingerprint.compute(folder: folder) != withNpmrc)
    }

    @Test func fingerprintEncodingIsUnambiguous() throws {
        // "a"+"bc" vs "ab"+"c" must not collide, and moving content between files changes it.
        let one = try tempDir(), two = try tempDir()
        try "bc".write(to: one.appending(path: "a"), atomically: true, encoding: .utf8)
        try "c".write(to: two.appending(path: "ab"), atomically: true, encoding: .utf8)
        #expect(try PluginFingerprint.compute(folder: one) != PluginFingerprint.compute(folder: two))
    }

    @Test func fingerprintRefusesSymlinks() throws {
        let folder = try copyFixture("ok-1password")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"),
                                                   withDestinationURL: URL(filePath: "/etc/hosts"))
        #expect(throws: PluginError.symlinkNotAllowed("link")) { _ = try PluginFingerprint.compute(folder: folder) }
    }

    @Test func fingerprintRefusesHardLinks() throws {
        let folder = try copyFixture("ok-1password")
        // A file outside the folder, hard-linked in: writing it would change the plugin unseen.
        let outside = try tempDir().appending(path: "outside.ts")
        try "export {}".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: outside, to: folder.appending(path: "linked.ts"))
        #expect(throws: PluginError.hardLinkNotAllowed("linked.ts")) { _ = try PluginFingerprint.compute(folder: folder) }
        #expect(throws: PluginError.hardLinkNotAllowed("linked.ts")) { _ = try PluginFingerprint.listFiles(folder: folder) }
        #expect(PluginError.hardLinkNotAllowed("linked.ts").userMessage
                == "it contains a file with another hard link (linked.ts); copy the file instead")
        // Once the other name is gone, the file is an ordinary one again.
        try FileManager.default.removeItem(at: outside)
        _ = try PluginFingerprint.compute(folder: folder)
    }

    // MARK: Status

    @Test func statusEvaluation() throws {
        let m = try onePassword()
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "aa", approval: nil) == .new)
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "aa",
                                      approval: approval(m.permissions)) == .approved)
        #expect(PluginStatus.evaluate(manifest: .failure(.missingLockfile), fingerprint: "aa",
                                      approval: approval(m.permissions)) == .invalid(.missingLockfile))
        #expect(PluginStatus.evaluate(manifest: .failure(.missingLockfile), fingerprint: "aa", approval: nil)
                == .invalid(.missingLockfile))
    }

    @Test func changedFilesPauseWithoutDevelopmentMode() throws {
        let m = try onePassword()
        let approved = ["background.ts": "1"], edited = ["background.ts": "2"]
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb", fileHashes: edited,
                                      approval: approval(m.permissions, dev: false, hashes: approved)) == .changed)
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb", fileHashes: edited,
                                      approval: approval(m.permissions, dev: true, hashes: approved)) == .approved)
        // Without per-file hashes on either side, development mode can't tell code from packages.
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb",
                                      approval: approval(m.permissions, dev: true, hashes: approved)) == .changed)
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb", fileHashes: edited,
                                      approval: approval(m.permissions, dev: true)) == .changed)
    }

    /// Package changes need a new approval even in development mode (Singularity installed them,
    /// outside the sandbox); edits to the plugin's own code don't.
    @Test func packageChangesNeedApprovalEvenInDevelopmentMode() throws {
        let m = try onePassword()
        let approved = ["background.ts": "1", "package.json": "p", "bun.lock": "l",
                        "node_modules/a/index.js": "a", "lib/node_modules/b/index.js": "b"]
        func status(_ change: (inout [String: String]) -> Void) -> PluginStatus {
            var now = approved
            change(&now)
            return PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb", fileHashes: now,
                                         approval: approval(m.permissions, dev: true, hashes: approved))
        }
        #expect(status { $0["background.ts"] = "2" } == .approved)
        #expect(status { $0["new.ts"] = "n" } == .approved)
        #expect(status { $0["package.json"] = "p2" } == .changed)
        #expect(status { $0["bun.lock"] = "l2" } == .changed)
        #expect(status { $0["bun.lock"] = nil } == .changed)
        #expect(status { $0["package.json"] = nil } == .changed)
        #expect(status { $0["node_modules/a/index.js"] = "a2" } == .changed)
        #expect(status { $0["node_modules/b/index.js"] = "new" } == .changed)
        #expect(status { $0["node_modules/a/index.js"] = nil } == .changed)
        #expect(status { $0["lib/node_modules/b/index.js"] = "b2" } == .changed)
        // Widening still wins over a package change.
        var wider = m.permissions; wider.commands["gh"] = ["pr list"]
        var now = approved; now["bun.lock"] = "l2"
        #expect(PluginStatus.evaluate(manifest: .success(plugin(m, wider)), fingerprint: "bb", fileHashes: now,
                                      approval: approval(m.permissions, dev: true, hashes: approved)) == .permissionsWidened)
    }

    @Test func widenedPermissionsAlwaysAsk() throws {
        let m = try onePassword()
        let approved = m.permissions
        var newCommand = approved; newCommand.commands["curl2"] = ["x"]
        var newSub = approved; newSub.commands["op"] = ["item list", "item get", "item delete"]
        var narrowApproved = approved; narrowApproved.pageAdditions = ["https://a.com/*"]
        var wideNow = approved; wideNow.pageAdditions = ["https://a.com/*", "https://b.com/*"]
        for (now, was) in [(newCommand, approved), (newSub, approved), (wideNow, narrowApproved)] {
            for dev in [false, true] {
                #expect(PluginStatus.evaluate(manifest: .success(plugin(m, now)), fingerprint: "aa",
                                              approval: approval(was, dev: dev)) == .permissionsWidened)
            }
        }
        // Fewer permissions is not widening.
        var fewer = approved; fewer.commands["op"] = ["item list"]; fewer.fillForms = []
        #expect(!fewer.widens(approved))
        var none = PluginManifest.Permissions()
        #expect(!none.widens(approved))
        none.commands = [:]
        #expect(PluginStatus.evaluate(manifest: .success(plugin(m, fewer)), fingerprint: "aa",
                                      approval: approval(approved)) == .approved)
    }

    @Test func wideningDetails() {
        let base = PluginManifest.Permissions(pageAdditions: ["https://a.com/*"], fillForms: [],
                                              commands: ["op": ["item get"]], network: [])
        // <all_urls> already approved covers any site.
        let all = PluginManifest.Permissions(pageAdditions: ["<all_urls>"])
        #expect(!PluginManifest.Permissions(pageAdditions: ["https://z.com/*"]).widens(all))
        #expect(PluginManifest.Permissions(pageAdditions: ["<all_urls>"]).widens(base))
        #expect(PluginManifest.Permissions(fillForms: ["https://a.com/*"]).widens(base))
        #expect(PluginManifest.Permissions(network: ["x.com"]).widens(base))
        #expect(!PluginManifest.Permissions(network: ["x.com"]).widens(
            PluginManifest.Permissions(network: ["x.com", "y.com"])))
        #expect(PluginManifest.Permissions(commands: ["gh": ["pr list"]]).widens(base))
        #expect(!base.widens(base))
    }

    private func plugin(_ m: PluginManifest, _ p: PluginManifest.Permissions) -> PluginManifest {
        var copy = m; copy.permissions = p; return copy
    }

    // MARK: State store

    @Test func stateStoreRoundTripAndTolerance() throws {
        let dir = try tempDir()
        let file = dir.appending(path: "sub/plugins-state.json")
        let store = PluginStateStore(file: file)
        #expect(store.load().isEmpty) // missing
        let a = PluginApproval(fingerprint: "ff", permissions: try onePassword().permissions,
                               commandPaths: ["op": "/opt/homebrew/bin/op"], enabledSpaces: [UUID(), UUID(), UUID()],
                               developmentMode: true, approvedAt: Date())
        try store.save(["ok-1password": a])
        #expect(store.load() == ["ok-1password": a])
        let first = try Data(contentsOf: file)
        try store.save(store.load())
        #expect(try Data(contentsOf: file) == first) // stable bytes
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(store.load().isEmpty) // corrupt
    }

    // MARK: Sandbox profile

    @Test func sandboxProfile() {
        let p = SandboxProfile.make(pluginFolder: URL(filePath: "/tmp/sbx-test/plugins/a"),
                                    dataFolder: URL(filePath: "/tmp/sbx-test/data/a"),
                                    runtime: URL(filePath: "/Applications/S.app/Contents/Helpers/bun"),
                                    extraReadable: [URL(filePath: "/tmp/sbx-test/host")])
        #expect(p.contains("(deny default)"))
        #expect(p.contains("(deny network*)"))
        #expect(!p.contains("process-fork"))
        #expect(p.contains("(allow process-exec (literal \"/Applications/S.app/Contents/Helpers/bun\"))"))
        #expect(p.contains("(allow file-read* (subpath \"/private/tmp/sbx-test/plugins/a\"))"))
        // The plugin's .git can't be read, and that rule comes after the allow (the later rule wins).
        let deny = "(deny file-read* (subpath \"/private/tmp/sbx-test/plugins/a/.git\"))"
        #expect(p.contains(deny))
        if let allowAt = p.range(of: "(allow file-read* (subpath \"/private/tmp/sbx-test/plugins/a\"))"),
           let denyAt = p.range(of: deny) {
            #expect(allowAt.lowerBound < denyAt.lowerBound)
        }
        #expect(p.contains("(allow file-read* file-write* (subpath \"/private/tmp/sbx-test/data/a\"))"))
        #expect(p.contains("(allow file-read* (subpath \"/private/tmp/sbx-test/host\"))"))
        #expect(!p.contains("(allow sysctl-read)"))   // only named sysctls
        #expect(!p.contains("(subpath \"/usr\")") && !p.contains("(subpath \"/System\")"))
        #expect(!p.contains("file-write* (subpath \"/private/var"))
        #expect(!p.contains("~/Library"))
        #expect(!p.contains("Singularity/spaces"))
        // No write access to anything but the data folder.
        let writes = p.split(separator: "\n").filter { $0.contains("file-write*") }
        #expect(writes.count == 1)
    }

    @Test func sandboxProfileEscapesPaths() {
        let p = SandboxProfile.make(pluginFolder: URL(filePath: "/tmp/we\"ird\\name/plugin"),
                                    dataFolder: URL(filePath: "/tmp/data"), runtime: URL(filePath: "/tmp/bun"))
        #expect(p.contains("(subpath \"/private/tmp/we\\\"ird\\\\name/plugin\")"))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: bunPath.path)), .timeLimit(.minutes(1)))
    func sandboxProfileConfinesBun() throws {
        // Real path: the sandbox matches real paths, and bun opens the script by the path it is given.
        let temp = try tempDir()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(realpath(temp.path, &buffer) != nil) // not resolvingSymlinksInPath: it maps /private/var back to /var
        let root = URL(filePath: String(cString: buffer), directoryHint: .isDirectory)
        let plugin = root.appending(path: "plugin", directoryHint: .isDirectory)
        let data = root.appending(path: "data", directoryHint: .isDirectory)
        for d in [plugin, data] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // A file in the home dir outside the folders (created by us so the test does not depend on dotfiles).
        let secret = home.appending(path: ".sing-sandbox-probe-\(UUID().uuidString)")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }

        // Another program of the same user, for the KERN_PROCARGS2 probe.
        let victim = Process()
        victim.executableURL = URL(filePath: "/bin/sleep")
        victim.arguments = ["30"]
        try victim.run()
        defer { victim.terminate() }

        let script = """
        import { readdirSync, readFileSync, writeFileSync } from "node:fs";
        const out: string[] = ["ok"];
        const probe = async (name: string, fn: () => unknown) => {
          try { await fn(); out.push(name + ":allowed"); } catch { out.push(name + ":denied"); }
        };
        await probe("data", () => { writeFileSync(\(json(data.path))+"/f.txt", "hi"); if (readFileSync(\(json(data.path))+"/f.txt","utf8") !== "hi") throw 1; });
        await probe("net", async () => { await fetch("https://example.com", { signal: AbortSignal.timeout(5000) }); });
        await probe("home", () => readFileSync(\(json(secret.path)), "utf8"));
        await probe("pluginwrite", () => writeFileSync(\(json(plugin.path))+"/evil.txt", "x"));
        // The plugin's own files load, but its .git folder (skipped by the fingerprint) can't be read.
        await probe("pluginread", () => { if (readFileSync(\(json(plugin.path))+"/notes.txt", "utf8") !== "n") throw 1; });
        await probe("gitignoreread", () => { if (readFileSync(\(json(plugin.path))+"/.gitignore", "utf8") !== "g") throw 1; });
        await probe("gitread", () => readFileSync(\(json(plugin.path))+"/.git/x", "utf8"));
        await probe("gitlist", () => { if (readdirSync(\(json(plugin.path))+"/.git").length === 0) throw 1; });
        await probe("spawn", () => { const r = Bun.spawnSync(["/bin/echo", "hi"]); if (r.exitCode !== 0 || !r.success) throw 1; });
        // sysctl through bun:ffi (plain libSystem calls): the process list, the host name, and
        // another process's arguments (KERN_PROCARGS2, of a `sleep` the test starts).
        const { dlopen, FFIType, ptr } = await import("bun:ffi");
        const libc = dlopen("/usr/lib/libSystem.B.dylib", {
          sysctl: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.i32 },
          sysctlbyname: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.i32 },
        }).symbols;
        const sysctl = (mib: number[], bytes = 1 << 21) => {
          const buf = new Uint8Array(bytes);
          const size = new BigUint64Array([BigInt(bytes)]);
          if (libc.sysctl(ptr(new Int32Array(mib)), mib.length, ptr(buf), ptr(size), null, 0) !== 0) throw 1;
        };
        await probe("proclist", () => sysctl([1, 14, 0]));                 // CTL_KERN, KERN_PROC, KERN_PROC_ALL
        await probe("procargs", () => sysctl([1, 49, \(victim.processIdentifier)], 1 << 16)); // KERN_PROCARGS2
        await probe("hostname", () => {
          const buf = new Uint8Array(256);
          const size = new BigUint64Array([BigInt(buf.length)]);
          if (libc.sysctlbyname(ptr(Buffer.from("kern.hostname\\0")), ptr(buf), ptr(size), null, 0) !== 0) throw 1;
        });
        // Dates and Intl need ICU and time zone data (Bun panics without them, ending the script).
        await probe("intl", () => {
          const text = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Tallinn" }).format(new Date(0));
          if (text !== "01/01/1970") throw 1;
        });
        await probe("locale", () => { if (new Date().toLocaleString().length === 0) throw 1; });
        out.push("tz:" + Intl.DateTimeFormat().resolvedOptions().timeZone);
        console.log(out.join("\\n"));
        """
        try script.write(to: plugin.appending(path: "t.ts"), atomically: true, encoding: .utf8)
        try "n".write(to: plugin.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try "g".write(to: plugin.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: plugin.appending(path: ".git"), withIntermediateDirectories: true)
        try "x".write(to: plugin.appending(path: ".git/x"), atomically: true, encoding: .utf8)

        func run(_ exe: String, _ args: [String]) throws -> String {
            let proc = Process()
            proc.executableURL = URL(filePath: exe)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            proc.currentDirectoryURL = data
            try proc.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            proc.waitUntilExit()
            return text
        }
        let scriptPath = plugin.appending(path: "t.ts").path
        // Control: the same script without a sandbox proves the probes work (network is not asserted: may be offline).
        let control = Set(try run(bunPath.path, ["run", scriptPath]).split(separator: "\n").map(String.init))
        #expect(control.contains("home:allowed") && control.contains("spawn:allowed"), Comment(rawValue: "\(control)"))
        #expect(control.contains("gitread:allowed") && control.contains("gitlist:allowed"), Comment(rawValue: "\(control)"))
        #expect(control.contains("intl:allowed") && control.contains("locale:allowed"), Comment(rawValue: "\(control)"))
        #expect(control.contains("proclist:allowed") && control.contains("procargs:allowed")
                && control.contains("hostname:allowed"), Comment(rawValue: "\(control)"))
        try? FileManager.default.removeItem(at: plugin.appending(path: "evil.txt"))

        let profile = SandboxProfile.make(pluginFolder: plugin, dataFolder: data, runtime: bunPath)
        let output = try run("/usr/bin/sandbox-exec", ["-p", profile, bunPath.path, "run", scriptPath])
        let lines = Set(output.split(separator: "\n").map(String.init))
        #expect(lines.contains("ok"), Comment(rawValue: output))
        #expect(lines.contains("data:allowed"), Comment(rawValue: output))
        #expect(lines.contains("net:denied"), Comment(rawValue: output))
        #expect(lines.contains("home:denied"), Comment(rawValue: output))
        #expect(lines.contains("pluginwrite:denied"), Comment(rawValue: output))
        #expect(lines.contains("pluginread:allowed"), Comment(rawValue: output))
        #expect(lines.contains("gitignoreread:allowed"), Comment(rawValue: output))
        #expect(lines.contains("gitread:denied"), Comment(rawValue: output))
        #expect(lines.contains("gitlist:denied"), Comment(rawValue: output))
        #expect(lines.contains("spawn:denied"), Comment(rawValue: output))
        #expect(lines.contains("intl:allowed"), Comment(rawValue: output))
        #expect(lines.contains("locale:allowed"), Comment(rawValue: output))
        // The local time zone (via /etc/localtime) is the same as outside the sandbox.
        #expect(lines.filter { $0.hasPrefix("tz:") } == control.filter { $0.hasPrefix("tz:") }, Comment(rawValue: output))
        #expect(lines.contains("proclist:denied"), Comment(rawValue: output))
        #expect(lines.contains("hostname:denied"), Comment(rawValue: output))
        // macOS checks named sysctls against the profile, but KERN_PROCARGS2 (another process's
        // argv, same user) is not routed through that check: even `(deny default)` with no
        // sysctl-read rule at all lets it through, so no SBPL rule can block it. Kept as a known
        // issue so this test tells us if a macOS update ever closes it.
        withKnownIssue("KERN_PROCARGS2 is not covered by sysctl-read rules") {
            #expect(lines.contains("procargs:denied"), Comment(rawValue: output))
        }
    }

    private func json(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data(), as: UTF8.self)
    }

    // MARK: Permission texts

    @Test func permissionDescriptions() throws {
        let manifest = try onePassword()
        let lines = PermissionDescriptions.lines(for: manifest.permissions,
                                                 commandPaths: ["op": "/opt/homebrew/bin/op"],
                                                 hasPageScript: manifest.page != nil)
        #expect(lines == ["Reads and changes pages on all sites, including what you type",
                          "Its page script could pass what it reads to other websites; review it before approving",
                          "Fills login forms on all sites",
                          "Runs /opt/homebrew/bin/op (only: item list, item get — plus any further arguments)",
                          "Its background program never uses the internet; the programs it runs can"])
        let mixed = PermissionDescriptions.lines(for: .init(pageAdditions: ["https://a.com/*", "<all_urls>"]), commandPaths: [:])
        #expect(mixed.first == "Reads and changes pages on all sites, including what you type")
        let some = PermissionDescriptions.lines(
            for: .init(pageAdditions: ["https://a.com/*", "https://b.com/*"], commands: ["gh": ["pr list"]], network: ["x.com"]),
            commandPaths: [:])
        #expect(some == ["Reads and changes pages on https://a.com/*, https://b.com/*, including what you type",
                         "Its page script could pass what it reads to other websites; review it before approving",
                         "Runs gh (only: pr list — plus any further arguments)", "Connects to x.com"])
        // A page script without pageAdditions still gets the warning; a page-only plugin has no
        // background program, so no network line.
        #expect(PermissionDescriptions.lines(for: .init(), commandPaths: [:], hasPageScript: true, hasBackground: false)
                == ["Its page script could pass what it reads to other websites; review it before approving"])
        #expect(PermissionDescriptions.lines(for: .init(), commandPaths: [:])
                == ["Its background program never uses the internet"])
    }

    // MARK: Command broker

    @Test func resolveFindsCommands() {
        #expect(CommandBroker.resolve("uptime", loginShell: "/bin/zsh") == "/usr/bin/uptime")
        // A zsh builtin, but PluginProcess execs files, so the file is what counts.
        #expect(CommandBroker.resolve("echo", loginShell: "/bin/zsh") == "/bin/echo")
        #expect(CommandBroker.resolve("definitely-not-a-real-command-xyz", loginShell: "/bin/zsh") == nil)
    }

    @Test func resolveRejectsBadNamesWithoutRunningAShell() {
        // The login shell is a path that does not exist: a nil result proves it was never needed.
        let nope = "/nonexistent/shell"
        #expect(CommandBroker.resolve("ls; touch /tmp/x", loginShell: nope) == nil)
        #expect(CommandBroker.resolve("$(id)", loginShell: nope) == nil)
        #expect(CommandBroker.resolve("-c", loginShell: nope) == nil)
        #expect(CommandBroker.resolve("python3", loginShell: nope) == nil)
        #expect(CommandBroker.resolve("bash", loginShell: nope) == nil)
    }

    @Test func loginPathIsTheLineAfterTheMarker() {
        #expect(CommandBroker.loginPath(fromShellOutput: "Welcome!\nnoise __SINGULARITY_PATH__\n__SINGULARITY_PATH__\n/a:/b\n") == "/a:/b")
        #expect(CommandBroker.loginPath(fromShellOutput: "/a:/b\n") == nil)                     // no marker
        #expect(CommandBroker.loginPath(fromShellOutput: "__SINGULARITY_PATH__\n") == nil)      // nothing after it
        #expect(CommandBroker.loginPath(fromShellOutput: "__SINGULARITY_PATH__\n\n/a\n") == nil)
    }

    @Test func findWalksThePathInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func dir(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        func make(_ dir: String, _ name: String, mode: Int) -> String {
            let path = dir + "/" + name
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: mode])
            return path
        }
        let a = try dir("a"), b = try dir("b"), c = try dir("c"), d = try dir("d")
        _ = make(a, "mytool", mode: 0o644)                                   // not executable: skipped
        try FileManager.default.createDirectory(atPath: b + "/mytool", withIntermediateDirectories: true) // folder: skipped
        let inC = make(c, "mytool", mode: 0o755)
        _ = make(d, "mytool", mode: 0o755)
        // Empty and relative entries are skipped; order decides between c and d.
        #expect(CommandBroker.find("mytool", inPath: "::relative:./x:\(a):\(b):\(c)/:\(d)") == inC)
        #expect(CommandBroker.find("mytool", inPath: "\(d):\(c)") == d + "/mytool")
        #expect(CommandBroker.find("mytool", inPath: "relative:\(a)") == nil)
        #expect(CommandBroker.find("missing", inPath: "\(c):\(d)") == nil)

        // A harmless-looking name that points at an interpreter is refused, by either name;
        // the walk then goes on to the next entry.
        let e = try dir("e")
        try FileManager.default.createSymbolicLink(atPath: e + "/mytool", withDestinationPath: "/usr/bin/python3")
        #expect(CommandBroker.find("mytool", inPath: "\(e)") == nil)
        #expect(CommandBroker.find("mytool", inPath: "\(e):\(d)") == d + "/mytool")
        let f = try dir("f")
        try FileManager.default.createSymbolicLink(atPath: f + "/friendly", withDestinationPath: "/bin/sh")
        #expect(CommandBroker.find("friendly", inPath: f) == nil)
        // A symlink to something harmless is fine and returned as joined, not as its target.
        try FileManager.default.createSymbolicLink(atPath: f + "/ok", withDestinationPath: inC)
        #expect(CommandBroker.find("ok", inPath: f) == f + "/ok")
        // Refused names never get looked up.
        _ = make(c, "bash", mode: 0o755)
        #expect(CommandBroker.find("bash", inPath: c) == nil)
    }

    @Test func runReturnsOutput() async {
        let result = await CommandBroker.run(path: "/bin/echo", arguments: ["hi"], timeout: .seconds(5))
        #expect(result.status == 0)
        #expect(result.stdout == "hi\n")
        #expect(!result.timedOut)
        let failed = await CommandBroker.run(path: "/bin/sh", arguments: ["-c", "echo err >&2; exit 3"], timeout: .seconds(5))
        #expect(failed.status == 3)
        #expect(failed.stderr == "err\n")
        let missing = await CommandBroker.run(path: "/nonexistent/tool", arguments: [], timeout: .seconds(5))
        #expect(missing.status != 0)
    }

    @Test func runGivesEmptyStdinAndHandlesLargeOutput() async {
        let cat = await CommandBroker.run(path: "/bin/cat", arguments: [], timeout: .seconds(5))
        #expect(cat.status == 0 && cat.stdout.isEmpty && !cat.timedOut)
        // 20 MB on stdout and stderr at once: must not deadlock, and is capped at 10 MB each.
        let big = await CommandBroker.run(path: "/bin/sh", arguments: ["-c",
            "head -c 20000000 /dev/zero | tr '\\0' a; head -c 20000000 /dev/zero | tr '\\0' b >&2"], timeout: .seconds(30))
        #expect(big.status == 0)
        #expect(big.stdout.utf8.count == 10_000_000)
        #expect(big.stderr.utf8.count == 10_000_000)
    }

    @Test func runTimesOutAndReportsIt() async throws {
        // The script prints its pid, then sleeps; we check that pid is gone afterwards.
        let started = ContinuousClock.now
        let result = await CommandBroker.run(path: "/bin/sh", arguments: ["-c", "echo $$; exec sleep 5"],
                                             timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(4))
        let pid = try #require(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func runKillsProcessesThatIgnoreSigterm() async throws {
        let started = ContinuousClock.now
        let result = await CommandBroker.run(path: "/bin/sh", arguments: ["-c", "trap '' TERM; echo $$; while :; do sleep 1; done"],
                                             timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(6))
        let pid = try #require(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}

// MARK: - npm packages (Task 9)

/// `Fixtures/bun-lock/*.lock` were generated by Bun 1.4.4 (`bun install`) for one dependency of
/// each kind: registry (registry.lock: @types/node, chalk, is-number), file:, link:, github:,
/// git+file: (git.lock; path shortened), remote tarball URL, local tarball, npm: alias,
/// workspace:, and a registry other than npmjs (mirror.lock, BUN_CONFIG_REGISTRY=npmmirror).
@Suite struct PluginPackagesTests {
    private var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    }

    private func tempPlugin(id: String = "t") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sing-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        try Data("""
        {"id":"\(id)","name":"T","version":"1","description":"d","author":"a","background":"background.ts","permissions":{}}
        """.utf8).write(to: dir.appending(path: "plugin.json"))
        return dir
    }

    private func copyWithDeps() throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "sing-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "with-deps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "plugins/with-deps"), to: dest)
        return dest
    }

    /// A plugin folder with `dependencies` and, optionally, a lockfile from the fixtures.
    private func error(dependencies: String, lock: String?) throws -> PluginError? {
        let dir = try tempPlugin()
        try Data(#"{"name":"t","dependencies":\#(dependencies)}"#.utf8).write(to: dir.appending(path: "package.json"))
        if let lock {
            try FileManager.default.copyItem(at: fixtures.appending(path: "bun-lock/\(lock).lock"),
                                             to: dir.appending(path: "bun.lock"))
        }
        do { _ = try PluginManifest.load(from: dir); return nil } catch { return error }
    }

    @Test func packagesListed() throws {
        let folder = fixtures.appending(path: "plugins/with-deps", directoryHint: .isDirectory)
        #expect(try PluginPackages.list(folder: folder) == [PluginPackage(name: "is-number", version: "7.0.0"),
                                                             PluginPackage(name: "is-odd", version: "3.0.1")])
        // is-odd brings its own is-number 6.0.0 (nested "is-odd/is-number").
        #expect(try PluginPackages.check(folder: folder).lockedCount == 3)
        #expect(try PluginManifest.load(from: folder).id == "with-deps")
    }

    @Test func lockfileRequired() throws {
        let folder = try copyWithDeps()
        try FileManager.default.removeItem(at: folder.appending(path: "bun.lock"))
        #expect(throws: PluginError.missingLockfile) { try PluginPackages.list(folder: folder) }
        #expect(throws: PluginError.missingLockfile) { _ = try PluginManifest.load(from: folder) }
    }

    @Test func noPackageJSONMeansNoPackages() throws {
        let folder = try tempPlugin()
        #expect(try PluginPackages.list(folder: folder) == [])
        #expect(try PluginPackages.check(folder: folder) == PluginPackages.Summary(packages: [], lockedCount: 0))
        try Data(#"{"name":"t","dependencies":{}}"#.utf8).write(to: folder.appending(path: "package.json"))
        #expect(try PluginPackages.list(folder: folder) == [])
    }

    @Test func onlyExactRegistryVersions() throws {
        for spec in ["^7.0.0", "~7.0.0", ">=7.0.0", "7.x", "7", "7.0", "*", "", "latest", "next", "v7.0.0", "=7.0.0",
                     "7.0.0 - 8.0.0", "7.0.0 || 8.0.0", "07.0.0", "7.0.0-", "7.0.0-01",
                     "file:../../..", "link:../x", "workspace:*", "git+https://github.com/a/b.git", "git://x/y",
                     "github:a/b", "a/b", "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz",
                     "npm:is-number@7.0.0", "catalog:", "portal:../x"] {
            #expect(try error(dependencies: #"{"is-number":"\#(spec)"}"#, lock: "registry") == .unsupportedPackage("is-number"),
                    "\(spec)")
        }
        for version in ["7.0.0", "0.0.1", "10.20.30", "1.0.0-beta.1", "1.0.0-rc.0+build.5", "1.0.0+20130313144700"] {
            #expect(PluginPackages.isExactVersion(version), "\(version)")
        }
        // Not a string, or not a package name.
        #expect(try error(dependencies: #"{"is-number":7}"#, lock: "registry") == .unsupportedPackage("is-number"))
        for name in ["../x", "a/b", ".x", "_x", "@s", "@s/", "@/x", "@s/x/y", "a b"] {
            #expect(try error(dependencies: #"{"\#(name)":"1.0.0"}"#, lock: "registry") == .unsupportedPackage(name), "\(name)")
        }
    }

    @Test func otherDependencyGroupsRefused() throws {
        for key in ["devDependencies", "optionalDependencies", "peerDependencies", "overrides", "resolutions",
                    "patchedDependencies"] {
            let dir = try tempPlugin()
            try Data(#"{"name":"t","\#(key)":{"is-number":"7.0.0"}}"#.utf8).write(to: dir.appending(path: "package.json"))
            #expect(throws: PluginError.unsupportedPackage(key)) { _ = try PluginManifest.load(from: dir) }
        }
        let dir = try tempPlugin()
        try Data(#"{"name":"t","workspaces":["packages/*"]}"#.utf8).write(to: dir.appending(path: "package.json"))
        #expect(throws: PluginError.unsupportedPackage("workspaces")) { _ = try PluginManifest.load(from: dir) }
        // Empty groups are fine.
        try Data(#"{"name":"t","devDependencies":{},"workspaces":[],"dependencies":null}"#.utf8)
            .write(to: dir.appending(path: "package.json"))
        #expect(try PluginPackages.list(folder: dir) == [])
    }

    @Test func npmrcForbidden() throws {
        let folder = try copyWithDeps()
        try Data("registry=https://evil.example/\n".utf8).write(to: folder.appending(path: ".npmrc"))
        #expect(throws: PluginError.forbiddenFile(".npmrc")) { _ = try PluginManifest.load(from: folder) }
        // Even without any packages, and even as a link.
        let plain = try tempPlugin()
        try FileManager.default.createSymbolicLink(atPath: plain.appending(path: ".npmrc").path, withDestinationPath: "/nonexistent")
        #expect(throws: PluginError.forbiddenFile(".npmrc")) { _ = try PluginManifest.load(from: plain) }
        #expect(PluginError.forbiddenFile(".npmrc").userMessage.contains(".npmrc"))
    }

    @Test func registryLockfileAccepted() throws {
        #expect(try error(dependencies: #"{"@types/node":"20.11.0","chalk":"4.1.2","is-number":"7.0.0"}"#,
                          lock: "registry") == nil)
    }

    /// Each lockfile has one non-registry entry; package.json names an exact version so only the
    /// lockfile check can catch it.
    @Test func nonRegistryLockfileEntriesRefused() throws {
        let cases: [(lock: String, name: String, key: String)] = [
            ("file", "localpkg", "localpkg"), ("link", "localpkg", "localpkg"), ("github", "is-number", "is-number"),
            ("git", "gitpkg", "gitpkg"), ("tarball", "is-number", "is-number"), ("local-tarball", "gitpkg", "gitpkg"),
            ("alias", "isnum", "isnum"), ("workspace", "inner", "inner"), ("mirror", "is-number", "is-number"),
        ]
        for c in cases {
            #expect(try error(dependencies: #"{"\#(c.name)":"7.0.0"}"#, lock: c.lock) == .unsupportedPackage(c.key), "\(c.lock)")
        }
    }

    @Test func lockfileMustMatchPackageJSON() throws {
        let deps = #"{"@types/node":"20.11.0","chalk":"4.1.2","is-number":"7.0.0"}"#
        // package.json asks for another version than the lockfile has.
        #expect(try error(dependencies: #"{"@types/node":"20.11.0","chalk":"4.1.1","is-number":"7.0.0"}"#,
                          lock: "registry") == .unsupportedPackage("chalk"))
        // A dependency the lockfile doesn't have, or one it has that package.json doesn't.
        #expect(try error(dependencies: #"{"@types/node":"20.11.0","chalk":"4.1.2","is-number":"7.0.0","x":"1.0.0"}"#,
                          lock: "registry") == .unsupportedPackage("x"))
        #expect(try error(dependencies: #"{"chalk":"4.1.2","is-number":"7.0.0"}"#, lock: "registry")
                == .unsupportedPackage("@types/node"))

        // Root section agrees with package.json, but the package entry is locked at another version.
        func edited(_ change: (String) -> String) throws -> PluginError? {
            let dir = try tempPlugin()
            try Data(#"{"name":"t","dependencies":\#(deps)}"#.utf8).write(to: dir.appending(path: "package.json"))
            let text = try String(contentsOf: fixtures.appending(path: "bun-lock/registry.lock"), encoding: .utf8)
            try Data(change(text).utf8).write(to: dir.appending(path: "bun.lock"))
            do { _ = try PluginManifest.load(from: dir); return nil } catch { return error }
        }
        #expect(try edited { $0.replacingOccurrences(of: #""chalk@4.1.2""#, with: #""chalk@4.1.3""#) } == .unsupportedPackage("chalk"))
        // A key that doesn't name a package, or names a path out of node_modules.
        #expect(try edited { $0.replacingOccurrences(of: #""has-flag": ["has-flag@4.0.0""#, with: #""../../x": ["has-flag@4.0.0""#) }
                == .unsupportedPackage("../../x"))
        #expect(try edited { $0.replacingOccurrences(of: #""has-flag": ["#, with: #""supports-color/../has-flag": ["#) }
                == .unsupportedPackage("supports-color/../has-flag"))
        // Extra top-level sections and extra workspaces.
        #expect(try edited { $0.replacingOccurrences(of: #""packages": {"#, with: #""overrides": { "x": "1.0.0" }, "packages": {"#) }
                == .unsupportedPackage("bun.lock: overrides"))
        #expect(try edited { $0.replacingOccurrences(of: #""workspaces": {"#, with: #""workspaces": { "../other": { "name": "o" },"#) }
                == .unsupportedPackage("bun.lock: workspace ../other"))
        #expect(try edited { $0.replacingOccurrences(of: #""name": "registry","#, with: #""name": "registry", "devDependencies": { "a": "1.0.0" },"#) }
                == .unsupportedPackage("devDependencies"))
        // Not parseable, or a format version we don't know.
        if case .invalidJSON(let text)? = try edited({ String($0.dropLast(3)) }) {
            #expect(text.hasPrefix("bun.lock:"))
            #expect(PluginError.invalidJSON(text).userMessage == "bun.lock isn't valid")
        } else { Issue.record("truncated lockfile") }
        if case .invalidJSON? = try edited({ $0.replacingOccurrences(of: #""lockfileVersion": 2"#, with: #""lockfileVersion": 9"#) }) {} else {
            Issue.record("unknown version")
        }
        // A duplicate key: Singularity could check one entry while Bun installs the other.
        if case .invalidJSON? = try edited({ $0.replacingOccurrences(of: #""packages": {"#, with: #""packages": { "chalk": ["chalk@9.9.9", "", {}, "sha512-x"],"#) }) {} else {
            Issue.record("duplicate key")
        }
        #expect(try edited { $0 } == nil)
    }

    // MARK: Fix round 1: lockfiles crafted to parse differently in Bun

    /// The with-deps lockfile text.
    private func withDepsLock() throws -> String {
        try String(contentsOf: fixtures.appending(path: "plugins/with-deps/bun.lock"), encoding: .utf8)
    }

    private func lockError(_ lock: String) throws -> PluginError? {
        let folder = try copyWithDeps()
        try Data(lock.utf8).write(to: folder.appending(path: "bun.lock"))
        do { _ = try PluginManifest.load(from: folder); return nil } catch { return error }
    }

    /// The reviewer's attack: Bun ends a `//` comment at \r, U+2028 or U+2029 (not only \n) and
    /// keeps the first of two duplicate keys. So `// note<CR>"packages": {evil}, //<LF>"packages":
    /// {benign}` is, to Bun, the evil map. Every variant must be refused while parsing, so the
    /// benign-looking map is never what gets checked.
    @Test func commentTricksRefused() throws {
        let benign = try withDepsLock()
        let evil = #""packages": { "is-number": ["is-number@7.0.0", "", {}, "sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng=="], "is-odd": ["is-odd@3.0.1", "", { "dependencies": { "is-number": "*" } }, "sha512-CQpnWPrDwmP1+SMHXZhtLtJv90yiyVfluGsX5iNCVkrhQtU3TQHsUWPG9wkdk9Lgd5yNpAg9jQEo90CBaXgWMA=="], "is-odd/is-number": ["is-number@/tmp/local.tgz", {}] }"#
        let comment = "\"workspaces\": {"
        for end in ["\r", "\u{2028}", "\u{2029}"] {
            let crafted = benign.replacingOccurrences(of: "  \"packages\": {", with: " // reviewed by Singularity\(end)\(evil), //\n  \"packages\": {")
            #expect(crafted != benign)
            if case .invalidJSON(let text)? = try lockError(crafted) {
                #expect(text == "bun.lock: comments aren't allowed")
            } else { Issue.record("comment ending in \(end.unicodeScalars.first!.value) accepted") }
        }
        // /* */ hiding the evil map from one parser and not the other.
        let block = benign.replacingOccurrences(of: comment, with: "/* x */ " + comment)
        #expect(try lockError(block) == .invalidJSON("bun.lock: comments aren't allowed"))
        // A bare \r, U+2028, a BOM or NUL anywhere outside strings.
        for odd in ["\r", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{0}"] {
            if case .invalidJSON? = try lockError(benign.replacingOccurrences(of: "\n  \"packages\"", with: "\n\(odd)  \"packages\"")) {} else {
                Issue.record("\(odd.unicodeScalars.first!.value) accepted")
            }
        }
        if case .invalidJSON? = try lockError("\u{FEFF}" + benign) {} else { Issue.record("BOM accepted") }
        if case .invalidJSON? = try lockError(benign.replacingOccurrences(of: "\n", with: "\r\n")) {} else { Issue.record("CRLF accepted") }
        // Without any trick, the evil map itself is refused (its third entry is a local tarball).
        let start = try #require(benign.range(of: "  \"packages\": {"))
        let plainEvil = String(benign[..<start.lowerBound]) + "  " + evil + "\n}\n"
        #expect(try lockError(plainEvil) == .unsupportedPackage("is-odd/is-number"))
        #expect(try lockError(benign) == nil)
    }

    /// Entry shape: the URL slot must be exactly "", the integrity a real sha512.
    @Test func strictRegistryEntries() throws {
        let lock = try withDepsLock()
        let goodNested = #""is-number@6.0.0", "", {}, "sha512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfDzg==""#
        func with(_ entry: String) throws -> PluginError? {
            try lockError(lock.replacingOccurrences(of: goodNested, with: entry))
        }
        #expect(lock.contains(goodNested))
        // The reviewer's cache-poisoning entry: registry-shaped, but with a download URL.
        #expect(try with(#""is-number@6.0.0", "https://registry.npmjs.org/is-even/-/is-even-1.0.0.tgz", {}, "sha512-LEhnkAdJqic4Dbqn58A0y52IXoHWlsueqQkKfMfdEnIYG8A1sm/GHidKkS6yvXlMoRrkM34csHnXQtOqcb+Jzg==""#)
                == .unsupportedPackage("is-odd/is-number"))
        for url in ["https://registry.npmjs.org/", "/tmp/x.tgz", " ", "0"] {
            #expect(try with(#""is-number@6.0.0", "\#(url)", {}, "sha512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfDzg==""#)
                    == .unsupportedPackage("is-odd/is-number"), "\(url)")
        }
        #expect(try with(#""is-number@6.0.0", null, {}, "sha512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfDzg==""#)
                == .unsupportedPackage("is-odd/is-number"))
        // Tarball URL with no integrity at all (reviewer's p5), and malformed integrities.
        #expect(try with(#""is-number@https://registry.npmjs.org/is-even/-/is-even-1.0.0.tgz", {}"#)
                == .unsupportedPackage("is-odd/is-number"))
        for integrity in ["", "sha512-", "sha1-Wu1VHeILBK8KAWJUAiSZQX94GmM=", "sha512-abc", "sha512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfDzg",
                          "sha512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfD*g==",
                          "SHA512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfDzg=="] {
            #expect(try with(#""is-number@6.0.0", "", {}, "\#(integrity)""#) == .unsupportedPackage("is-odd/is-number"), "\(integrity)")
        }
        #expect(try with(#""is-number@6.0.0", "", {}"#) == .unsupportedPackage("is-odd/is-number"))
        // Metadata pointing elsewhere (the reviewer's p2/p3/p13 forms).
        let isOdd = #"{ "dependencies": { "is-number": "^6.0.0" } }"#
        for spec in ["npm:is-even@1.0.0", "link:/tmp/secret", "github:jonschlinkert/is-number", "file:/tmp/secret",
                     "https://registry.npmjs.org/is-even/-/is-even-1.0.0.tgz", "a/b", "..\\\\x"] {
            #expect(try lockError(lock.replacingOccurrences(of: isOdd, with: #"{ "dependencies": { "is-number": "\#(spec)" } }"#))
                    == .unsupportedPackage("is-odd"), "\(spec)")
        }
        #expect(try lockError(lock.replacingOccurrences(of: isOdd, with: #"{ "dependencies": { "is-number": ">=6.0.0 <7 || latest" } }"#)) == nil)
        for bin in [#""../../../outside.txt""#, #""/tmp/outside.txt""#, #"{ "pw": "bin/../../x" }"#, #"{ "pw": 1 }"#] {
            #expect(try lockError(lock.replacingOccurrences(of: isOdd, with: #"{ "bin": \#(bin) }"#)) == .unsupportedPackage("is-odd"), "\(bin)")
        }
        #expect(try lockError(lock.replacingOccurrences(of: isOdd, with: #"{ "bin": { "is-odd": "cli.js" }, "os": "darwin" }"#)) == nil)
        #expect(PluginPackages.isSHA512Integrity("sha512-Wu1VHeILBK8KAWJUAiSZQX94GmOE45Rg6/538fKwiloUu21KncEkYGPqob2oSZ5mUT73vLGrHQjKw3KMPwfDzg=="))
        // Every entry of every generated registry lockfile passes.
        #expect(try with(goodNested) == nil)
    }

    /// package.json and bun.lock must be regular files of at most 1 MB; a FIFO must not hang.
    @Test(.timeLimit(.minutes(1))) func packageFilesMustBeRegularAndSmall() throws {
        let fm = FileManager.default
        let fifo = try copyWithDeps()
        try fm.removeItem(at: fifo.appending(path: "bun.lock"))
        #expect(mkfifo(fifo.appending(path: "bun.lock").path, 0o600) == 0)
        #expect(throws: PluginError.invalidJSON("bun.lock: not a regular file")) { try PluginPackages.check(folder: fifo) }
        let fifoPackage = try tempPlugin()
        #expect(mkfifo(fifoPackage.appending(path: "package.json").path, 0o600) == 0)
        #expect(throws: PluginError.invalidJSON("package.json: not a regular file")) { try PluginPackages.check(folder: fifoPackage) }

        let link = try copyWithDeps()
        try fm.moveItem(at: link.appending(path: "bun.lock"), to: link.appending(path: "real.lock"))
        try fm.createSymbolicLink(atPath: link.appending(path: "bun.lock").path, withDestinationPath: "real.lock")
        #expect(throws: PluginError.invalidJSON("bun.lock: not a regular file")) { try PluginPackages.check(folder: link) }

        let big = try copyWithDeps()
        let text = try withDepsLock()
        try Data((text + String(repeating: " ", count: 1 << 20)).utf8).write(to: big.appending(path: "bun.lock"))
        #expect(throws: PluginError.invalidJSON("bun.lock: larger than 1 MB")) { try PluginPackages.check(folder: big) }
        try Data(String(repeating: " ", count: (1 << 20) + 1).utf8).write(to: big.appending(path: "package.json"))
        #expect(throws: PluginError.invalidJSON("package.json: larger than 1 MB")) { try PluginPackages.check(folder: big) }
    }

    /// The sheet's package list comes from the bytes the snapshot hashed.
    @Test func reviewListsTheSnapshotsPackages() throws {
        let folder = try copyWithDeps()
        let hashes = try PluginFingerprint.fileHashes(folder: folder)
        #expect(try PluginPackages.check(folder: folder, matching: hashes)?.packages.count == 2)
        let lock = folder.appending(path: "bun.lock")
        try Data((try String(contentsOf: lock, encoding: .utf8) + "\n").utf8).write(to: lock)
        #expect(try PluginPackages.check(folder: folder, matching: hashes) == nil)
        // A scan taken before the change, prepared after it: refused, not listed from the new file.
        let scan = PluginScan(folder: folder, manifest: .success(try PluginManifest.load(from: folder)),
                              files: .success(PluginFingerprint.Snapshot(fingerprint: "old", fileHashes: hashes)))
        if case .failure(.unreadable) = PluginReview.prepare(scan: scan, resolve: { _ in nil }) {} else {
            Issue.record("prepared from changed files")
        }
    }

    @Test func packagePathsIgnoreCase() {
        for path in ["package.json", "Package.JSON", "BUN.LOCK", "node_modules/a/i.js", "Node_Modules/a/i.js", "lib/NODE_MODULES/b/i.js"] {
            #expect(PluginPackages.isPackagePath(path), "\(path)")
        }
        for path in ["background.ts", "lib/package.json", "node_modules", "my_node_modules/x.js"] {
            #expect(!PluginPackages.isPackagePath(path), "\(path)")
        }
        #expect(PluginPackages.sameOutsideNodeModules(["a.ts": "1"], ["a.ts": "1", "Node_Modules/x/i.js": "2"]))
        #expect(!PluginPackages.sameOutsideNodeModules(["a.ts": "1"], ["a.ts": "1", "lib/node_modules/x/i.js": "2"]))
    }

    @Test func leftoverStagingFoldersRemoved() throws {
        let root = try tempPlugin().appending(path: "plugin-install", directoryHint: .isDirectory)
        let fm = FileManager.default
        for name in ["install-1/project", "install-2", "keep"] {
            try fm.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        PluginPackages.removeLeftoverStaging(in: root)
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["keep"])
        PluginPackages.removeLeftoverStaging(in: root.appending(path: "missing"))   // no folder: nothing happens
    }

    @Test func jsonText() throws {
        #expect(try JSONText.parse(Data(#"{"a":[1,-2.5e3,true,false,null,"é😀\n"]}"#.utf8))
                == .object(["a": .array([.number(1), .number(-2500), .bool(true), .bool(false), .null, .string("é😀\n")])]))
        // Lockfile mode: trailing commas, only when allowed.
        let trailing = Data("{\n \"a\": [1, 2,],\t\"b\": {},\n}".utf8)
        #expect(try JSONText.parse(trailing, lockfile: true) == .object(["a": .array([.number(1), .number(2)]), "b": .object([:])]))
        #expect(throws: JSONText.ParseError.self) { try JSONText.parse(trailing) }
        #expect(throws: JSONText.ParseError.self) { try JSONText.parse(Data(#"{"a":1,}"#.utf8)) }
        // \r is JSON whitespace (package.json), but not in a lockfile (Bun ends a // comment there).
        #expect(try JSONText.parse(Data("{\"a\":\r\n1}".utf8)) == .object(["a": .number(1)]))
        #expect(throws: JSONText.ParseError.self) { try JSONText.parse(Data("{\"a\":\r\n1}".utf8), lockfile: true) }
        // Inside strings, \r escapes and U+2028 are just text.
        #expect(try JSONText.parse(Data("\"a\\r\u{2028}b\"".utf8), lockfile: true) == .string("a\r\u{2028}b"))
        for bad in [#"{"a":1,"a":2}"#, #"{"a":{"b":1,"b":1}}"#, #"{"a":01}"#, #"{'a':1}"#, #"{a:1}"#, #"[1 2]"#, #""\x""#,
                    "\"a\u{1}\"", #""\ud800""#, #"{"a":1} x"#, "", "/* open", #"[,]"#, #"{,}"#, "NaN",
                    "{ // c\n \"a\": 1 }", "{ /* c */ \"a\": 1 }", "{\"a\": 1 // c\n}", "{\u{2028}\"a\":1}",
                    "{\u{2029}\"a\":1}", "\u{FEFF}{\"a\":1}", "{\"a\":1}\u{0}", "{\u{A0}\"a\":1}", "{\u{B}\"a\":1}"] {
            for lockfile in [false, true] {
                #expect(throws: JSONText.ParseError.self, "\(bad)") { try JSONText.parse(Data(bad.utf8), lockfile: lockfile) }
            }
        }
        #expect(throws: JSONText.ParseError(message: JSONText.commentMessage, offset: 2)) {
            try JSONText.parse(Data("{ // c\n}".utf8), lockfile: true)
        }
        #expect(throws: JSONText.ParseError.self) { try JSONText.parse(Data([0x22, 0xFF, 0x22])) }  // invalid UTF-8
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: JSONText.ParseError.self) { try JSONText.parse(Data(deep.utf8)) }
        // Every generated lockfile parses.
        for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.appending(path: "bun-lock").path) {
            _ = try JSONText.parse(Data(contentsOf: fixtures.appending(path: "bun-lock/\(name)")), lockfile: true)
        }
    }

    @Test func sheetLinesMentionPackages() throws {
        let folder = fixtures.appending(path: "plugins/with-deps", directoryHint: .isDirectory)
        let review = try PluginReview.prepare(scan: PluginScan.scan(folder: folder)) { _ in nil }.get()
        #expect(review.packages.packages.map(\.name) == ["is-number", "is-odd"])
        #expect(review.permissionLines == ["Installs 2 packages from the npm registry (3 with the packages they use)",
                                           "Its background program never uses the internet"])
        let one = PluginPackages.Summary(packages: [PluginPackage(name: "a", version: "1.0.0")], lockedCount: 1)
        #expect(PermissionDescriptions.lines(for: .init(), commandPaths: [:], packages: one)
                == ["Installs 1 package from the npm registry", "Its background program never uses the internet"])
        #expect(PermissionDescriptions.lines(for: .init(), commandPaths: [:]) == ["Its background program never uses the internet"])
    }

    /// What `PluginManager.approve` relies on: the approval records the folder as it is after the
    /// install, so the refresh the file watcher queues for the install's own writes (it runs after
    /// approve, in the plugin's queue) finds it approved, in or out of development mode; the
    /// folder before the install no longer matches; and code edited while installing is noticed.
    @Test func approvalRecordsTheInstalledFolder() throws {
        let folder = try copyWithDeps()
        let before = PluginScan.scan(folder: folder)
        let pre = try before.files.get()
        // Pretend to install.
        for (path, text) in ["node_modules/is-number/index.js": "n", "node_modules/is-odd/index.js": "o",
                             "node_modules/is-odd/node_modules/is-number/index.js": "n6"] {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let after = PluginScan.scan(folder: folder)
        let post = try after.files.get()
        #expect(PluginPackages.sameOutsideNodeModules(pre.fileHashes, post.fileHashes))
        let manifest = try #require(after.validManifest)
        for dev in [false, true] {
            let approval = PluginApproval(fingerprint: post.fingerprint, permissions: manifest.permissions, commandPaths: [:],
                                          enabledSpaces: [UUID()], developmentMode: dev, approvedAt: Date(),
                                          fileHashes: post.fileHashes)
            #expect(PluginScan.scan(folder: folder).status(approval: approval) == .approved)
            #expect(before.status(approval: approval) == .changed)
        }
        // Code changed during the install: not what the sheet showed.
        try Data("// changed".utf8).write(to: folder.appending(path: "background.ts"))
        #expect(!PluginPackages.sameOutsideNodeModules(pre.fileHashes, try PluginFingerprint.fileHashes(folder: folder)))
    }

    @Test func installWithoutPackagesDeletesShippedNodeModules() async throws {
        let folder = try tempPlugin()
        let file = folder.appending(path: "node_modules/x/index.js")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("shipped".utf8).write(to: file)
        let result = await PluginPackages.install(folder: folder, runtime: URL(filePath: "/nonexistent/bun"),
                                                  hostFolder: URL(filePath: "/nonexistent"), stagingRoot: folder.appending(path: "c"))
        #expect(result.outcome == .nothingToInstall)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "node_modules").path))
    }

    /// Only the package.json and bun.lock the approval sheet showed are installed.
    @Test func installRefusesFilesOtherThanTheReviewedOnes() async throws {
        let folder = try copyWithDeps()
        let shown = try PluginFingerprint.fileHashes(folder: folder)
        let lock = folder.appending(path: "bun.lock")
        try Data((try String(contentsOf: lock, encoding: .utf8) + "\n").utf8).write(to: lock)
        try FileManager.default.createDirectory(at: folder.appending(path: "node_modules/x"), withIntermediateDirectories: true)
        let result = await PluginPackages.install(folder: folder, expectedFileHashes: shown, runtime: URL(filePath: "/nonexistent/bun"),
                                                  hostFolder: URL(filePath: "/nonexistent"),
                                                  stagingRoot: folder.deletingLastPathComponent().appending(path: "staging"))
        #expect(result.outcome == .filesChanged)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "node_modules").path))
        // A package.json that appeared after the review counts too.
        let plain = try tempPlugin()
        let shownPlain = try PluginFingerprint.fileHashes(folder: plain)
        try Data(#"{"dependencies":{}}"#.utf8).write(to: plain.appending(path: "package.json"))
        let second = await PluginPackages.install(folder: plain, expectedFileHashes: shownPlain, runtime: URL(filePath: "/nonexistent/bun"),
                                                  hostFolder: URL(filePath: "/nonexistent"), stagingRoot: plain.appending(path: "c"))
        #expect(second.outcome == .filesChanged)
    }

    @Test func installFailureLeavesNoNodeModules() async throws {
        let folder = try copyWithDeps()
        try FileManager.default.createDirectory(at: folder.appending(path: "node_modules/x"), withIntermediateDirectories: true)
        let result = await PluginPackages.install(folder: folder, runtime: URL(filePath: "/nonexistent/bun"),
                                                  hostFolder: URL(filePath: "/nonexistent"),
                                                  stagingRoot: folder.deletingLastPathComponent().appending(path: "staging"))
        #expect(result.outcome == .failed)
        #expect(!result.message.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "node_modules").path))
    }

    @Test func installCommandIsLockedDown() {
        let args = PluginPackages.installArguments(hostFolder: "/App/plugin-host")
        #expect(Array(args.prefix(3)) == ["--config=/App/plugin-host/bunfig.toml", "--no-env-file", "install"])
        for flag in ["--frozen-lockfile", "--ignore-scripts", "--production", "--omit=optional", "--registry=https://registry.npmjs.org/",
                     "--linker=hoisted", "--backend=clonefile"] {
            #expect(args.contains(flag), "\(flag)")
        }
        let env = PluginPackages.installEnvironment(home: "/S/install-1/home", cache: "/S/install-1/cache")
        #expect(Set(env.keys) == ["HOME", "TMPDIR", "LANG", "NO_COLOR", "BUN_INSTALL_CACHE_DIR", "BUN_CONFIG_REGISTRY"])
        #expect(env["BUN_INSTALL_CACHE_DIR"] == "/S/install-1/cache")
    }

    @Test func removeBinFoldersKeepsEverythingElse() throws {
        let nm = try tempPlugin().appending(path: "node_modules", directoryHint: .isDirectory)
        let fm = FileManager.default
        for dir in [".bin", "a/node_modules/.bin", "a/lib/.bin"] {
            try fm.createDirectory(at: nm.appending(path: dir), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: nm.appending(path: ".bin/semver").path, withDestinationPath: "../semver/bin/semver.js")
        try PluginPackages.removeBinFolders(in: nm)
        #expect(!fm.fileExists(atPath: nm.appending(path: ".bin").path))
        #expect(!fm.fileExists(atPath: nm.appending(path: "a/node_modules/.bin").path))
        #expect(fm.fileExists(atPath: nm.appending(path: "a/lib/.bin").path))   // not directly in node_modules
    }

    @Test func runUsesGivenEnvironmentAndDirectory() async throws {
        let dir = try tempPlugin()
        let result = await CommandBroker.run(path: "/bin/sh", arguments: ["-c", "pwd -P; echo \"$ONLY\"; env | wc -l"],
                                             timeout: .seconds(5), environment: ["ONLY": "yes"], currentDirectory: dir)
        let lines = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        _ = realpath(dir.path, &buffer)
        #expect(lines.first == String(cString: buffer))
        #expect(lines.dropFirst().first == "yes")
        // sh adds PWD, SHLVL and _ of its own; nothing from the test runner's environment.
        #expect((Int(lines.last ?? "") ?? 99) <= 4)
    }

    /// Real `bun install` against registry.npmjs.org. Needs the network, so it only runs with
    /// SINGULARITY_NETWORK_TESTS=1. The plugin folder also holds a bunfig.toml and a .env that
    /// point the registry at a closed port: the install only works if neither is used.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SINGULARITY_NETWORK_TESTS"] == "1"
                   && FileManager.default.isExecutableFile(atPath: installBun.path)),
          .timeLimit(.minutes(4)))
    func installFromRegistry() async throws {
        let folder = try copyWithDeps()
        try Data("[install]\nregistry = \"http://127.0.0.1:9/\"\n".utf8).write(to: folder.appending(path: "bunfig.toml"))
        try Data("BUN_CONFIG_REGISTRY=http://127.0.0.1:9/\nNPM_CONFIG_REGISTRY=http://127.0.0.1:9/\n".utf8)
            .write(to: folder.appending(path: ".env"))
        let lockBefore = try Data(contentsOf: folder.appending(path: "bun.lock"))
        let stagingRoot = folder.deletingLastPathComponent().appending(path: "staging", directoryHint: .isDirectory)
        let result = await PluginPackages.install(folder: folder, expectedFileHashes: try PluginFingerprint.fileHashes(folder: folder),
                                                  runtime: installBun,
                                                  hostFolder: installRepo.appending(path: "Resources/plugin-host"),
                                                  stagingRoot: stagingRoot)
        #expect(result.outcome == .installed, "\(result.message)\n\(result.output)")
        #expect(result.message == "Installed 2 packages")
        // The staging folder (with this install's own cache) is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).isEmpty)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: folder.appending(path: "node_modules/is-odd/index.js").path))
        #expect(fm.fileExists(atPath: folder.appending(path: "node_modules/is-odd/node_modules/is-number/index.js").path))
        #expect(try Data(contentsOf: folder.appending(path: "bun.lock")) == lockBefore)
        // No symlinks left, so the folder can be fingerprinted and approved.
        let scan = PluginScan.scan(folder: folder)
        #expect(scan.validManifest != nil)
    }
}

private let installRepo = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let installBun = installRepo.appending(path: "Vendor/bun/bun")
