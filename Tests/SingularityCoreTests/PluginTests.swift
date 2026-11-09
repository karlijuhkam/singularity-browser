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
}
