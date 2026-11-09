import Foundation
import Testing
@testable import SingularityCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostFolder = repoRoot.appending(path: "Resources/plugin-host", directoryHint: .isDirectory)
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)
private let pluginFixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/plugins")

private func url(_ s: String) -> URL { URL(string: s)! }

/// Page additions (Task 8): which plugins a Space gets, where they may run and fill, and the
/// checks on messages from page scripts.
@Suite struct PluginPageTests {
    private func fixtureManifest() throws -> PluginManifest {
        try PluginManifest.load(from: pluginFixtures.appending(path: "fixture-filler", directoryHint: .isDirectory))
    }

    private func approval(_ manifest: PluginManifest, spaces: Set<UUID>) -> PluginApproval {
        PluginApproval(fingerprint: "f", permissions: manifest.permissions, commandPaths: [:],
                       enabledSpaces: spaces, developmentMode: false, approvedAt: Date())
    }

    // MARK: Fill guard

    @Test func fillGuard() {
        #expect(FillGuard.allows(frameHost: "github.com", forHost: "github.com"))
        #expect(FillGuard.allows(frameHost: "www.github.com", forHost: "github.com"))
        #expect(FillGuard.allows(frameHost: "GitHub.com.", forHost: "github.com"))
        // The saved host's parent, an unrelated host, and lookalikes are refused.
        #expect(!FillGuard.allows(frameHost: "github.com", forHost: "www.github.com"))
        #expect(!FillGuard.allows(frameHost: "example.com", forHost: "github.com"))
        #expect(!FillGuard.allows(frameHost: "evilgithub.com", forHost: "github.com"))
        #expect(!FillGuard.allows(frameHost: "github.com.evil.com", forHost: "github.com"))
        #expect(!FillGuard.allows(frameHost: "", forHost: "github.com"))
        #expect(!FillGuard.allows(frameHost: "github.com", forHost: ""))
    }

    @Test func fillReplyChecks() throws {
        let forms = [try SitePattern("https://*.github.com/*")]
        let frame = url("https://github.com/login")
        let fill: JSONValue = .object(["fill": .object([
            "forHost": .string("github.com"), "username": .string("u"), "password": .string("p")])])
        func check(_ reply: JSONValue, host: String = "github.com", url: URL = frame, clicked: Bool = true) -> FillGuard.Decision {
            FillGuard.check(reply: reply, frameHost: host, frameURL: url, fillForms: forms, clickOriginated: clicked)
        }
        #expect(check(fill) == .allowed)
        // Replies without "fill" pass through untouched.
        #expect(check(.object(["logins": .array([])])) == .notAFill)
        #expect(check(.string("fill")) == .notAFill)
        #expect(check(.null) == .notAFill)
        // (a) the frame's host must be the login's host or a subdomain of it,
        #expect(check(fill, host: "evil.com") == .blocked(.hostMismatch))
        // (b) the frame must be on a fillForms site,
        #expect(check(fill, url: url("https://github.com.evil.com/login")) == .blocked(.siteNotPermitted))
        #expect(FillGuard.check(reply: fill, frameHost: "github.com", frameURL: frame, fillForms: [],
                                clickOriginated: true) == .blocked(.siteNotPermitted))
        // (c) the request must come from a real click.
        #expect(check(fill, clicked: false) == .blocked(.notFromClick))
        // A "fill" that isn't shaped like one is blocked too.
        #expect(check(.object(["fill": .string("x")])) == .blocked(.malformed))
        #expect(check(.object(["fill": .object(["username": .string("u")])])) == .blocked(.malformed))
        #expect(check(.object(["fill": .object(["forHost": .string("github.com"), "password": .number(1)])])) == .blocked(.malformed))
    }

    @Test func fillCheckWithAccessNeedsManifestAndApproval() throws {
        let manifest = try fixtureManifest()
        let fill: JSONValue = .object(["fill": .object(["forHost": .string("127.0.0.1"), "username": .string("u"),
                                                        "password": .string("p")])])
        let frame = url("http://127.0.0.1:52011/plugin-pages/login.html")
        let full = PluginPageAccess(manifest: manifest, approved: manifest.permissions)
        #expect(FillGuard.check(reply: fill, frameHost: "127.0.0.1", frameURL: frame, access: full,
                                clickOriginated: true) == .allowed)
        var approved = manifest.permissions
        approved.fillForms = []
        let narrow = PluginPageAccess(manifest: manifest, approved: approved)
        #expect(FillGuard.check(reply: fill, frameHost: "127.0.0.1", frameURL: frame, access: narrow,
                                clickOriginated: true) == .blocked(.siteNotPermitted))
    }

    // MARK: Which plugins a Space gets

    @Test func pluginScriptsForSpace() throws {
        let manifest = try fixtureManifest()
        let a = UUID(), b = UUID()
        let id = "fixture-filler"
        let approvals = [id: approval(manifest, spaces: [a])]
        func select(_ space: UUID, status: PluginStatus = .approved, decision: PluginLaunch.Decision = .launch) -> [String] {
            PluginSelection.forSpace(space, approvals: approvals, statuses: [id: status], decisions: [id: decision])
        }
        // Enabled in Space A only: A gets the script, B doesn't.
        #expect(select(a) == [id])
        #expect(select(b) == [])
        // Only while the manager would run it.
        #expect(select(a, status: .changed) == [])
        #expect(select(a, status: .permissionsWidened) == [])
        #expect(select(a, status: .new) == [])
        #expect(select(a, decision: .blocked("op isn't at /x any more")) == [])
        #expect(select(a, decision: .notApproved) == [])
        // A page-only plugin has nothing to run in the background, but its page script applies.
        #expect(select(a, decision: .nothingToRun) == [id])
        // Unknown status or decision: not selected.
        #expect(PluginSelection.forSpace(a, approvals: approvals, statuses: [:], decisions: [id: .launch]) == [])
        #expect(PluginSelection.forSpace(a, approvals: approvals, statuses: [id: .approved], decisions: [:]) == [])
    }

    @Test func pluginSelectionIsSorted() throws {
        let manifest = try fixtureManifest()
        let a = UUID()
        let ids = ["zeta", "alpha", "mid"]
        var approvals: [String: PluginApproval] = [:]
        for id in ids { approvals[id] = approval(manifest, spaces: [a]) }
        let selected = PluginSelection.forSpace(a, approvals: approvals,
                                                statuses: Dictionary(uniqueKeysWithValues: ids.map { ($0, .approved) }),
                                                decisions: Dictionary(uniqueKeysWithValues: ids.map { ($0, .launch) }))
        #expect(selected == ["alpha", "mid", "zeta"])
    }

    // MARK: Where a plugin runs and fills

    @Test func pageAccessNeedsSitesAndPermissions() throws {
        let manifest = try fixtureManifest()
        let access = PluginPageAccess(manifest: manifest, approved: manifest.permissions)
        #expect(access.runsOn(url("http://127.0.0.1:52011/plugin-pages/login.html")))
        #expect(!access.runsOn(url("https://127.0.0.1/x")))     // http only
        #expect(!access.runsOn(url("http://localhost/x")))
        #expect(access.fills(url("http://127.0.0.1:52011/login.html")))
        #expect(!access.fills(url("http://example.com/")))

        // page.sites alone isn't enough: pageAdditions (also as approved) must cover the page.
        var narrowed = manifest
        narrowed.permissions.pageAdditions = ["http://127.0.0.1/only/*"]
        let both = PluginPageAccess(manifest: narrowed, approved: manifest.permissions)
        #expect(!both.runsOn(url("http://127.0.0.1/login.html")))
        #expect(both.runsOn(url("http://127.0.0.1/only/login.html")))
        var approvedLess = manifest.permissions
        approvedLess.fillForms = []
        approvedLess.pageAdditions = ["http://127.0.0.1/only/*"]
        let approvedNarrow = PluginPageAccess(manifest: manifest, approved: approvedLess)
        #expect(!approvedNarrow.runsOn(url("http://127.0.0.1/login.html")))
        #expect(!approvedNarrow.fills(url("http://127.0.0.1/login.html")))

        // No page section: runs nowhere.
        var noPage = manifest
        noPage.page = nil
        #expect(!PluginPageAccess(manifest: noPage, approved: manifest.permissions).runsOn(url("http://127.0.0.1/")))
    }

    @Test func frameURLFromOriginAndRequest() {
        // Same origin: the request's path and query are used.
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: url("https://github.com/login?x=1"))
                == url("https://github.com/login?x=1"))
        #expect(PluginFrame.url(originProtocol: "http", originHost: "127.0.0.1", originPort: 52011,
                                requestURL: url("http://127.0.0.1:52011/a/b.html"))
                == url("http://127.0.0.1:52011/a/b.html"))
        // An explicit default port counts as the same origin.
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: url("https://github.com:443/login"))?.path() == "/login")
        // The request is on another origin (about:blank or srcdoc frames inherit their parent's
        // origin; a redirect may have moved the frame): only the origin is trusted, path "/".
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: url("about:blank")) == url("https://github.com/"))
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: url("https://evil.com/login")) == url("https://github.com/"))
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: url("https://github.com:8443/login")) == url("https://github.com/"))
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: url("http://github.com/login")) == url("https://github.com/"))
        #expect(PluginFrame.url(originProtocol: "https", originHost: "github.com", originPort: 0,
                                requestURL: nil) == url("https://github.com/"))
        // Opaque origins (sandboxed frames, data: URLs) and other schemes: no URL, so no access.
        #expect(PluginFrame.url(originProtocol: "", originHost: "", originPort: 0, requestURL: url("https://github.com/")) == nil)
        #expect(PluginFrame.url(originProtocol: "file", originHost: "", originPort: 0, requestURL: nil) == nil)
        #expect(PluginFrame.url(originProtocol: "https", originHost: "", originPort: 0, requestURL: nil) == nil)
    }

    // MARK: Messages from page scripts

    @Test func pageRequestParsing() {
        #expect(PluginPageRequest.parse(["type": "click", "secret": "s"]) == .success(.click(secret: "s")))
        #expect(PluginPageRequest.parse(["type": "send", "json": #"{"action":"fill","index":0}"#])
                == .success(.send(payload: .object(["action": .string("fill"), "index": .number(0)]), token: nil)))
        #expect(PluginPageRequest.parse(["type": "send", "json": "null", "token": "t"])
                == .success(.send(payload: .null, token: "t")))
        // A token that isn't a string is ignored (treated as no token).
        #expect(PluginPageRequest.parse(["type": "send", "json": "1", "token": 5])
                == .success(.send(payload: .number(1), token: nil)))
        // Malformed.
        #expect(PluginPageRequest.parse("hello") == .failure(.malformed))
        #expect(PluginPageRequest.parse(["type": "nope"]) == .failure(.malformed))
        #expect(PluginPageRequest.parse(["type": "send"]) == .failure(.malformed))
        #expect(PluginPageRequest.parse(["type": "send", "json": "{not json"]) == .failure(.malformed))
        #expect(PluginPageRequest.parse(["type": "click"]) == .failure(.malformed))
        #expect(PluginPageRequest.parse(["type": "click", "secret": 1]) == .failure(.malformed))
    }

    @Test func pagePayloadSizeLimit() {
        let limit = PluginPageRequest.maxPayloadBytes
        #expect(limit == 256 * 1024)
        let fits = "\"" + String(repeating: "a", count: limit - 2) + "\""
        let tooBig = "\"" + String(repeating: "a", count: limit - 1) + "\""
        #expect(PluginPageRequest.parse(["type": "send", "json": fits]) == .success(.send(payload: .string(String(repeating: "a", count: limit - 2)), token: nil)))
        #expect(PluginPageRequest.parse(["type": "send", "json": tooBig]) == .failure(.tooLarge))
        // Very deep nesting within the size limit is refused, not a crash.
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(PluginPageRequest.parse(["type": "send", "json": deep]) == .failure(.malformed))
        let fine = String(repeating: "[", count: 50) + String(repeating: "]", count: 50)
        #expect((try? PluginPageRequest.parse(["type": "send", "json": fine]).get()) != nil)
    }

    @Test func secretsCompare() {
        #expect(PluginPageRequest.secretsMatch("abc", "abc"))
        #expect(!PluginPageRequest.secretsMatch("abc", "abd"))
        #expect(!PluginPageRequest.secretsMatch("abc", "abcd"))
        #expect(!PluginPageRequest.secretsMatch("", ""))
        let s = PluginPageRequest.makeSecret()
        #expect(s.count == 64)
        #expect(s != PluginPageRequest.makeSecret())
    }

    // MARK: Click tokens

    @Test func clickTokensAreOneUseShortLivedAndScoped() {
        var tokens = ClickTokens()
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = tokens.issue(scope: "tab1|127.0.0.1", now: t0)
        #expect(a.count == 32)
        // Wrong scope (another tab or frame host): refused, and the token stays usable.
        do { let ok = tokens.consume(a, scope: "tab2|127.0.0.1", now: t0); #expect(!ok) }
        do { let ok = tokens.consume(a, scope: "tab1|127.0.0.1", now: t0.addingTimeInterval(1.9)); #expect(ok) }
        // One use only.
        do { let ok = tokens.consume(a, scope: "tab1|127.0.0.1", now: t0.addingTimeInterval(1.9)); #expect(!ok) }
        // Expired after 2 s.
        let b = tokens.issue(scope: "s", now: t0)
        do { let ok = tokens.consume(b, scope: "s", now: t0.addingTimeInterval(2.1)); #expect(!ok) }
        // Unknown tokens never pass.
        do { let ok = tokens.consume("made-up", scope: "s", now: t0); #expect(!ok) }
        do { let ok = tokens.consume("", scope: "s", now: t0); #expect(!ok) }
    }

    @Test func clickTokensAreCapped() {
        var tokens = ClickTokens()
        let t0 = Date(timeIntervalSince1970: 1000)
        let first = tokens.issue(scope: "s", now: t0)
        for _ in 0..<ClickTokens.maxOutstanding { _ = tokens.issue(scope: "s", now: t0) }
        #expect(tokens.count == ClickTokens.maxOutstanding)
        // The oldest was dropped to make room.
        do { let ok = tokens.consume(first, scope: "s", now: t0); #expect(!ok) }
    }

    // MARK: Site patterns in the page

    @Test func browserMatcherMirrorsSitePattern() throws {
        let p = try SitePattern("https://*.github.com/login*")
        let m = p.browserMatcher
        #expect(m.schemes == ["https"])
        #expect(m.host == "github.com")
        #expect(m.hostKind == "domainAndSubdomains")
        let regex = try NSRegularExpression(pattern: m.pathRegex)
        func pathMatches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        #expect(pathMatches("/login"))
        #expect(pathMatches("/login/oauth?x=1"))
        #expect(!pathMatches("/x/login"))

        let special = try SitePattern("http://a.com/a.b+c(d)[e]{f}|g^h$i\\j*")
        let sm = special.browserMatcher
        let sr = try NSRegularExpression(pattern: sm.pathRegex)
        let text = "/a.b+c(d)[e]{f}|g^h$i\\jzzz"
        #expect(sr.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
        let other = "/aXb+c(d)[e]{f}|g^h$i\\j"
        #expect(sr.firstMatch(in: other, range: NSRange(other.startIndex..., in: other)) == nil)

        let all = try SitePattern("<all_urls>").browserMatcher
        #expect(all.schemes == ["http", "https"])
        #expect(all.hostKind == "any")
        #expect(all.pathRegex == #"^\/.*$"#)
    }

    // MARK: Replies to WebKit

    @Test func jsonValueToFoundation() throws {
        let value: JSONValue = .object(["a": .array([.number(1), .bool(true), .null, .string("x")])])
        let object = value.foundationObject
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":[1,true,null,"x"]}"#)
    }

    // MARK: Transpiling page.ts (needs the bundled Bun)

    @Test(.enabled(if: hasBun)) func transpilesFixturePageScript() throws {
        let folder = pluginFixtures.appending(path: "fixture-filler", directoryHint: .isDirectory)
        let snapshot = try PluginFingerprint.snapshot(folder: folder)
        let source = try PluginPageCompiler.readVerified(folder: folder, script: "page.ts",
                                                         expectedHash: snapshot.fileHashes["page.ts"]).get()
        let js = try PluginPageCompiler.transpile(source: source, runtime: bunPath, hostFolder: hostFolder).get()
        #expect(js.contains("singularity.addFieldButton"))
        #expect(!js.contains(": HTMLInputElement"))   // types are gone
    }

    @Test func readVerifiedRefusesChangedOrLargeFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sing-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("const a = 1;".utf8).write(to: dir.appending(path: "page.ts"))
        let hash = try PluginFingerprint.snapshot(folder: dir).fileHashes["page.ts"]
        #expect(try PluginPageCompiler.readVerified(folder: dir, script: "page.ts", expectedHash: hash).get() == "const a = 1;")
        // Edited after the scan: refused until the next scan.
        try Data("const a = 2;".utf8).write(to: dir.appending(path: "page.ts"))
        #expect(PluginPageCompiler.readVerified(folder: dir, script: "page.ts", expectedHash: hash) == .failure(.changed))
        #expect(PluginPageCompiler.readVerified(folder: dir, script: "page.ts", expectedHash: nil) == .failure(.changed))
        #expect(PluginPageCompiler.readVerified(folder: dir, script: "nothere.ts", expectedHash: hash) == .failure(.unreadable))
        let big = Data(repeating: 0x20, count: PluginPageCompiler.maxSourceBytes + 1)
        try big.write(to: dir.appending(path: "page.ts"))
        let bigHash = try PluginFingerprint.snapshot(folder: dir).fileHashes["page.ts"]
        #expect(PluginPageCompiler.readVerified(folder: dir, script: "page.ts", expectedHash: bigHash) == .failure(.tooLarge))
    }

    @Test(.enabled(if: hasBun)) func transpileRefusesImportsExportsAndBrokenCode() {
        func transpile(_ source: String) -> Result<String, PluginPageCompiler.Failure> {
            PluginPageCompiler.transpile(source: source, runtime: bunPath, hostFolder: hostFolder)
        }
        let staticImport = transpile(#"import { a } from "./a"; a();"#)
        guard case .failure(.refused(let imports)) = staticImport else {
            Issue.record("static import: \(staticImport)"); return
        }
        #expect(imports.contains("can't import"))
        let dynamicImport = transpile(#"const m = await import("https://x.example/y.js");"#)
        guard case .failure(.refused(let dynamic)) = dynamicImport else {
            Issue.record("dynamic import: \(dynamicImport)"); return
        }
        #expect(dynamic.contains("can't import"))
        let computed = transpile(#"const u: string = "x"; import(u);"#)
        guard case .failure(.refused(let computedText)) = computed else {
            Issue.record("computed dynamic import: \(computed)"); return
        }
        #expect(computedText.contains("import()"))
        let export = transpile("export const z = 1;")
        guard case .failure(.refused(let exports)) = export else {
            Issue.record("export: \(export)"); return
        }
        #expect(exports.contains("export"))
        let broken = transpile("const = ;")
        guard case .failure(.refused(let syntax)) = broken else {
            Issue.record("syntax error: \(broken)"); return
        }
        #expect(syntax.contains("syntax"))
        // Module-only syntax that scan() lets through fails when compiled as the async function
        // body it becomes in the page.
        for source in ["export {};\nconst q = 1;", "const s = `${import.meta}`;", "const u = \"x\";\nimport.source(u);"] {
            let result = transpile(source)
            guard case .failure(.refused(let text)) = result else {
                Issue.record("\(source): \(result)"); continue
            }
            // Bun itself rejects `import.source` as a syntax error; the others fail as a function body.
            #expect(text.contains("import/export") || text.contains("syntax error"), "\(source): \(text)")
        }
        // Comments and line breaks between import and "(" don't hide it (Bun reprints the code).
        for source in ["const u = \"x\";\nimport /**/ (u);", "const u = \"x\";\nimport //line\n(u);",
                       "const u = \"x\";\n\\u0069mport(u);"] {
            let result = transpile(source)
            guard case .failure(.refused) = result else { Issue.record("\(source): \(result)"); continue }
        }
        // Top-level await is fine: the code runs inside an async function.
        #expect((try? transpile("await Promise.resolve(1);").get()) != nil)
        // Type-only imports vanish when transpiling, so they are fine.
        #expect((try? transpile(#"import type { A } from "./a"; const x: A | null = null;"#).get()) != nil)
    }
}

/// The shipped 1Password plugin (Plugins/1password): its manifest is what the approval sheet
/// shows, and a syntax error in its scripts must not ship.
@Suite struct OnePasswordPluginTests {
    private let folder = repoRoot.appending(path: "Plugins/1password", directoryHint: .isDirectory)

    @Test func manifestAsksForOnlyOp() throws {
        let manifest = try PluginManifest.load(from: folder)
        #expect(manifest.permissions.commands == ["op": ["item list", "item get"]])
        #expect(manifest.permissions.network.isEmpty)
    }

    @Test(.enabled(if: hasBun)) func pageScriptTranspiles() throws {
        let snapshot = try PluginFingerprint.snapshot(folder: folder)
        let source = try PluginPageCompiler.readVerified(folder: folder, script: "page.ts",
                                                         expectedHash: snapshot.fileHashes["page.ts"]).get()
        let js = try PluginPageCompiler.transpile(source: source, runtime: bunPath, hostFolder: hostFolder).get()
        #expect(js.contains("addFieldButton"))
    }

    /// `bun build --no-bundle` only parses and strips types; it fails on a syntax error.
    @Test(.enabled(if: hasBun)) func backgroundScriptsParse() throws {
        for file in ["background.ts", "logic.ts"] {
            let process = Process()
            process.executableURL = bunPath
            process.arguments = ["build", "--no-bundle", folder.appending(path: file).path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(file) doesn't parse")
        }
    }
}
