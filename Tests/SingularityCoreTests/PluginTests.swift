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
        #expect(try load(package: #"{"devDependencies":{"a":"1"}}"#) == .missingLockfile)
        #expect(try load(package: #"{"dependencies":{"a":"1"}}"#, lockAsDirectory: true) == .missingLockfile)
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

    private func approval(_ p: PluginManifest.Permissions, fingerprint: String = "aa", dev: Bool = false) -> PluginApproval {
        PluginApproval(fingerprint: fingerprint, permissions: p, commandPaths: [:],
                       enabledSpaces: [], developmentMode: dev, approvedAt: Date(timeIntervalSince1970: 0))
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
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb",
                                      approval: approval(m.permissions, dev: false)) == .changed)
        #expect(PluginStatus.evaluate(manifest: .success(m), fingerprint: "bb",
                                      approval: approval(m.permissions, dev: true)) == .approved)
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
        import { readFileSync, writeFileSync } from "node:fs";
        const out: string[] = ["ok"];
        const probe = async (name: string, fn: () => unknown) => {
          try { await fn(); out.push(name + ":allowed"); } catch { out.push(name + ":denied"); }
        };
        await probe("data", () => { writeFileSync(\(json(data.path))+"/f.txt", "hi"); if (readFileSync(\(json(data.path))+"/f.txt","utf8") !== "hi") throw 1; });
        await probe("net", async () => { await fetch("https://example.com", { signal: AbortSignal.timeout(5000) }); });
        await probe("home", () => readFileSync(\(json(secret.path)), "utf8"));
        await probe("pluginwrite", () => writeFileSync(\(json(plugin.path))+"/evil.txt", "x"));
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
        let lines = PermissionDescriptions.lines(for: try onePassword().permissions,
                                                 commandPaths: ["op": "/opt/homebrew/bin/op"])
        #expect(lines == ["Adds buttons to pages on all sites",
                          "Fills login forms on all sites",
                          "Runs /opt/homebrew/bin/op (only: item list, item get)",
                          "Never uses the internet"])
        let mixed = PermissionDescriptions.lines(for: .init(pageAdditions: ["https://a.com/*", "<all_urls>"]), commandPaths: [:])
        #expect(mixed.first == "Adds buttons to pages on all sites")
        let some = PermissionDescriptions.lines(
            for: .init(pageAdditions: ["https://a.com/*", "https://b.com/*"], commands: ["gh": ["pr list"]], network: ["x.com"]),
            commandPaths: [:])
        #expect(some == ["Adds buttons to pages on https://a.com/*, https://b.com/*",
                         "Runs gh (only: pr list)", "Connects to x.com"])
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
