import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import Singularity
import SingularityCore

// Bun and the plugin host scripts in the repository, found from this file's location (as the Core
// tests do). Tests that compile TypeScript are skipped when Bun hasn't been fetched.
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostFolder = repoRoot.appending(path: "Resources/plugin-host", directoryHint: .isDirectory)
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

extension AppTests {
/// A plugin's own page (`PluginPageServer` + `PluginPageHost`): served from its folder under
/// `singularity-plugin://<id>/`, compiled like TS/TSX artifacts, locked away from the network,
/// and talking to its background through `window.singularity`.
@MainActor
@Suite(.serialized) struct PluginPageTests {
    // MARK: Serving (the scheme handler on its own)

    @Test func servesOnlyFilesInsideTheFolder() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let server = PluginPageServer(pluginID: "demo", folder: plugin.folder, entry: "panel.tsx",
                                      compile: { _ in .success("// compiled") })

        let util = await fetch(server, "util.ts")
        #expect(util.status == 200)
        #expect(util.text == "// compiled")
        #expect(util.headers["Content-Type"] == "text/javascript; charset=utf-8")
        // Extension-less imports, as in TypeScript.
        #expect(await fetch(server, "util").status == 200)
        // The plugin's own files, including plugin.json, are its reviewed source.
        #expect(await fetch(server, "plugin.json").status == 200)
        #expect(await fetch(server, "node_modules/preact/dist/preact.mjs").status == 200)

        for path in ["../outside.txt", "%2e%2e/outside.txt", "node_modules/../../outside.txt",
                     ".secret", ".git/config", "leak.txt", "missing.ts"] {
            let reply = await fetch(server, path)
            #expect(reply.status == 404, "\(path) should be 404, was \(reply.status)")
            #expect(!reply.text.contains("outside the plugin") && !reply.text.contains("hidden"), "\(path) leaked")
        }
        // Another plugin's host.
        #expect(await fetch(server, url: "singularity-plugin://other/util.ts").status == 404)
        // GET only.
        #expect(await fetch(server, "util.ts", method: "POST").status == 405)
        #expect(await fetch(server, "util.ts", method: "HEAD").status == 405)
    }

    @Test func everyResponseCarriesThePolicy() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let server = PluginPageServer(pluginID: "demo", folder: plugin.folder, entry: "panel.tsx",
                                      compile: { _ in .success("") })
        for path in ["", "util.ts", "plugin.json", "missing.ts", ".secret"] {
            let reply = await fetch(server, path)
            let policy = reply.headers["Content-Security-Policy"] ?? ""
            #expect(policy.hasPrefix("default-src 'none'; script-src 'self' 'nonce-"), "\(path): \(policy)")
            #expect(policy.hasSuffix("'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'"), "\(path): \(policy)")
            #expect(reply.headers["X-Content-Type-Options"] == "nosniff")
            #expect(reply.headers["Cache-Control"] == "no-store")
        }
        let wrongMethod = await fetch(server, "util.ts", method: "POST")
        #expect(wrongMethod.headers["Content-Security-Policy"]?.hasPrefix("default-src 'none'") == true)
    }

    @Test func theEntryScriptGetsAShellPageWithTheImportMapAndANonce() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let server = PluginPageServer(pluginID: "demo", folder: plugin.folder, entry: "panel.tsx",
                                      compile: { _ in .success("") })
        let first = await fetch(server, "")
        #expect(first.status == 200)
        #expect(first.headers["Content-Type"] == "text/html; charset=utf-8")
        let nonce = try #require(Self.nonce(in: first.headers["Content-Security-Policy"] ?? ""))
        #expect(first.text.contains(#"<script type="module" nonce="\#(nonce)" src="./panel.tsx"></script>"#))
        #expect(first.text.contains(#"<script type="importmap" nonce="\#(nonce)">"#))
        #expect(first.text.contains(#""preact":"/node_modules/preact/dist/preact.mjs""#))
        #expect(first.text.contains(#""preact/jsx-runtime":"/node_modules/preact/jsx-runtime/dist/jsxRuntime.mjs""#))
        // A new nonce for every response.
        let second = await fetch(server, "")
        #expect(Self.nonce(in: second.headers["Content-Security-Policy"] ?? "") != nonce)
    }

    @Test func anHTMLPageMustSitAtTheTopOfTheFolder() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        func page(_ entry: String) async -> Reply {
            await fetch(PluginPageServer(pluginID: "demo", folder: plugin.folder, entry: entry,
                                         compile: { _ in .success("") }), "")
        }
        let top = await page("index.html")
        #expect(top.status == 200)
        #expect(top.text.contains("top page"))
        #expect(await page("./index.html").status == 200)
        // In a subfolder its relative links would resolve from "/", so it isn't served.
        #expect(await page("ui/index.html").status == 404)
        // A script page in a subfolder is fine: the shell page loads it by its path.
        let script = await page("ui/panel.tsx")
        #expect(script.status == 200)
        #expect(script.text.contains(#"src="./ui/panel.tsx""#))
    }

    @Test func aCompileErrorComesBackAsTheModuleThatShowsIt() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let server = PluginPageServer(pluginID: "demo", folder: plugin.folder, entry: "panel.tsx",
                                      compile: { _ in .failure(.rejected("Unexpected } (line 3)")) })
        let reply = await fetch(server, "util.ts")
        #expect(reply.status == 200)
        #expect(reply.headers["Content-Type"] == "text/javascript; charset=utf-8")
        #expect(reply.text.contains("Could not compile"))
        #expect(reply.text.contains("Unexpected } (line 3)"))
    }

    // MARK: The page in a web view

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func theEntryTSXRendersWithASiblingModuleAndAPackage() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { close(host, window) }

        await wait("the page to render") { host.webView.title == "rendered:from-util" }
        #expect(host.webView.title == "rendered:from-util")
        #expect(host.webView.url?.absoluteString == "singularity-plugin://demo/")
        // The page is on the plugin's own origin.
        let origin = try await host.webView.evaluateJavaScript("location.origin") as? String
        #expect(origin == "singularity-plugin://demo")
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func thePageCannotLoadFromOrGoToAnotherSite() async throws {
        let site = try await CountingServer.start()
        defer { site.stop() }
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { close(host, window) }
        await wait("the page to render") { host.webView.title == "rendered:from-util" }

        // `attack` is the page's own code (attack.ts): fetch, an image, a frame, a new window.
        let result = try await host.webView.callAsyncJavaScript(
            "return await window.attack(url)", arguments: ["url": site.url.absoluteString],
            in: nil, contentWorld: .page) as? String
        #expect(result == "fetch:blocked,img:blocked,frame:blocked,open:blocked")
        // Leaving the page for the site.
        _ = try? await host.webView.evaluateJavaScript("location.href = \(Self.literal(site.url.absoluteString + "nav")); 1")
        try await Task.sleep(for: .seconds(1))
        #expect(host.webView.url?.absoluteString == "singularity-plugin://demo/")
        #expect(site.connections == 0)

        // The server does count: a request from outside the page is seen.
        _ = try? await URLSession.shared.data(from: site.url)
        #expect(site.connections == 1)
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func navigationStaysRefusedAfterTearDown() async throws {
        let site = try await CountingServer.start()
        defer { site.stop() }
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { window.close() }
        await wait("the page to render") { host.webView.title == "rendered:from-util" }

        // A timer the page left running.
        _ = try await host.webView.evaluateJavaScript(
            "setTimeout(() => { window.fired = true; location.href = \(Self.literal(site.url.absoluteString + "timer")) }, 300); 1")
        host.tearDown()
        try await Task.sleep(for: .seconds(1))
        // It fired (the same document is still there), and its navigation was refused.
        #expect(try await host.webView.evaluateJavaScript("window.fired === true") as? Bool == true)
        #expect(site.connections == 0)

        // A navigation started after the teardown.
        _ = try? await host.webView.evaluateJavaScript("location.href = \(Self.literal(site.url.absoluteString + "later")); 1")
        try await Task.sleep(for: .seconds(1))
        #expect(site.connections == 0)

        // Not even the plugin's own page loads again: the document stays the same.
        _ = try? await host.webView.evaluateJavaScript("location.href = 'singularity-plugin://demo/'; 1")
        try await Task.sleep(for: .seconds(1))
        #expect(try await host.webView.evaluateJavaScript("window.fired === true") as? Bool == true)
        #expect(host.webView.url?.absoluteString == "singularity-plugin://demo/")

        // The server does count: a request from outside the page is seen.
        _ = try? await URLSession.shared.data(from: site.url)
        #expect(site.connections == 1)
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func webRTCIsSwitchedOff() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { close(host, window) }
        await wait("the page to render") { host.webView.title == "rendered:from-util" }
        let result = try await host.webView.callAsyncJavaScript("""
            const frame = document.createElement("iframe");
            document.body.append(frame);
            const inFrame = frame.contentWindow;
            return [typeof RTCPeerConnection, typeof webkitRTCPeerConnection,
                    typeof inFrame.RTCPeerConnection, typeof inFrame.webkitRTCPeerConnection].join()
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(result == "undefined,undefined,undefined,undefined")
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func aScriptPageInASubfolderWorks() async throws {
        let plugin = try FixturePlugin(page: "ui/panel.tsx")
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { close(host, window) }
        await wait("the page to render") { host.webView.title == "rendered:ui:from-util" }
        #expect(host.webView.title == "rendered:ui:from-util")
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func sendRoundTripsThroughTheBackground() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        var received: [JSONValue] = []
        let (host, window) = makeHost(plugin) { payload in
            received.append(payload)
            return .object(["echo": payload])
        }
        defer { close(host, window) }
        await wait("the page to render") { host.webView.title == "rendered:from-util" }

        let reply = try await host.webView.callAsyncJavaScript(
            "const r = await singularity.send({ask: 'hello', n: 2}); return [Object.keys(r).join(), r.echo.ask, r.echo.n].join('|')",
            arguments: [:], in: nil, contentWorld: .page) as? String
        // (Compared by value: the order of keys in the answer isn't fixed.)
        #expect(reply == "echo|hello|2")
        let expected: [JSONValue] = [.object(["ask": .string("hello"), "n": .number(2)])]
        #expect(received == expected)

        // 300 KB is over the limit; it never reaches the background.
        let tooLarge = try await host.webView.callAsyncJavaScript(
            "try { await singularity.send('x'.repeat(300 * 1024)); return 'sent' } catch (e) { return String(e.message || e) }",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(tooLarge == "the message is larger than 256 KB")
        #expect(received.count == 1)
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func sendWithoutAnAnswerIsRejected() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin) { _ in nil }
        defer { close(host, window) }
        await wait("the page to render") { host.webView.title == "rendered:from-util" }
        let result = try await host.webView.callAsyncJavaScript(
            "try { await singularity.send({}); return 'answered' } catch (e) { return String(e.message || e) }",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(result == "the plugin isn't running or didn't answer")
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func postReachesOnMessageAlsoBeforeAHandlerIsSet() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { close(host, window) }
        // Before the page has loaded: dropped.
        host.post(.string("too early"))
        await wait("the page to render") { host.webView.title == "rendered:from-util" }

        // The page has set no handler yet: this one waits for it.
        host.post(.object(["n": .number(1)]))
        _ = try await host.webView.evaluateJavaScript("""
            window.got = []; singularity.onMessage((payload) => window.got.push(payload)); 1
            """)
        host.post(.object(["n": .number(2)]))
        await wait("both messages") {
            ((try? await host.webView.evaluateJavaScript("window.got.length")) as? Int) == 2
        }
        let got = try await host.webView.evaluateJavaScript("JSON.stringify(window.got)") as? String
        #expect(got == #"[{"n":1},{"n":2}]"#)

        // After tearDown nothing is delivered (the page itself is still there to ask).
        host.tearDown()
        host.post(.string("too late"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await host.webView.evaluateJavaScript("window.got.length") as? Int == 2)
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func aDeadWebContentProcessReloadsThePageButNotInALoop() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        let (host, window) = makeHost(plugin)
        defer { close(host, window) }
        #expect(host.webView.allowsLinkPreview == false)
        await wait("the page to render") { host.webView.title == "rendered:from-util" }
        func mark() async throws { _ = try await host.webView.evaluateJavaScript("window.marker = 1; 1") }
        func reloaded() async -> Bool {
            (try? await host.webView.evaluateJavaScript("window.marker === undefined && document.title === 'rendered:from-util'")) as? Bool == true
        }

        // WebKit calls this when the page's process died; we call it the same way.
        host.crashReloadSpacing = .seconds(2)
        try await mark()
        host.webViewWebContentProcessDidTerminate(host.webView)
        await wait("the first reload") { await reloaded() }

        // Again right away: it waits for the spacing, then loads once.
        try await mark()
        host.webViewWebContentProcessDidTerminate(host.webView)
        host.webViewWebContentProcessDidTerminate(host.webView)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await reloaded() == false)
        await wait("the second reload", seconds: 5) { await reloaded() }
    }

    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func theBridgeTakesOnlySendsFromTheMainFrame() async throws {
        let plugin = try FixturePlugin()
        defer { plugin.remove() }
        var calls = 0
        let (host, window) = makeHost(plugin) { _ in calls += 1; return .null }
        defer { close(host, window) }
        await wait("the page to render") { host.webView.title == "rendered:from-util" }

        // Posted straight to the handler, not through `singularity.send`: still fine from the page.
        let direct = try await host.webView.callAsyncJavaScript(
            "return JSON.stringify(await webkit.messageHandlers.singularityPanel.postMessage({type: 'send', json: '1'}))",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(direct == "null")
        #expect(calls == 1)

        // A click request (the page-script prelude's message) means nothing here.
        let click = try await host.webView.callAsyncJavaScript(
            "try { await webkit.messageHandlers.singularityPanel.postMessage({type: 'click', secret: 'x'}); return 'ok' } catch (e) { return String(e.message || e) }",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(click == "malformed message")

        // From a frame inside the page (an empty one has the page's origin, but isn't the main frame).
        let fromFrame = try await host.webView.callAsyncJavaScript("""
            const frame = document.createElement("iframe");
            document.body.append(frame);
            try { await frame.contentWindow.webkit.messageHandlers.singularityPanel.postMessage({type: 'send', json: '1'}); return 'ok' }
            catch (e) { return String(e.message || e) }
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(fromFrame == "only the plugin's own page can send messages")
        #expect(calls == 1)
    }

    // MARK: The Assistant's real page

    /// The bundled Assistant's own files (a copy of `Plugins/assistant`), served, compiled and shown
    /// as in the app, against a fake background. Its packages are never installed in tests (that
    /// needs the network): a small stand-in for Preact takes the real package's place.
    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func theAssistantsPageShowsTheEmptyChatAndAnAnswer() async throws {
        let plugin = try AssistantCopy()
        defer { plugin.remove() }
        #expect(plugin.manifest.id == "assistant")
        #expect(plugin.manifest.panel?.page == "panel.tsx")
        #expect(plugin.manifest.panel?.title == "Assistant")

        // Its files are served and compile with the real compiler.
        let scripts = ArtifactScriptService(runtime: bunPath, hostFolder: hostFolder)
        let server = PluginPageServer(pluginID: "assistant", folder: plugin.folder, entry: "panel.tsx",
                                      compile: { await scripts.javascript(for: $0) })
        for file in ["panel.tsx", "markdown.ts", "view.ts"] {
            let reply = await fetch(server, url: "singularity-plugin://assistant/" + file)
            #expect(reply.status == 200, "\(file): \(reply.status)")
            #expect(reply.headers["Content-Type"] == "text/javascript; charset=utf-8", "\(file)")
            #expect(!reply.text.contains("Could not compile"), "\(file): \(reply.text.prefix(500))")
        }
        let css = await fetch(server, url: "singularity-plugin://assistant/panel.css")
        #expect(css.status == 200)
        #expect(css.headers["Content-Type"]?.hasPrefix("text/css") == true)
        // The shell page maps every package name panel.tsx imports.
        let shell = await fetch(server, url: "singularity-plugin://assistant/")
        for name in ["preact", "preact/hooks", "preact/jsx-runtime"] {
            #expect(shell.text.contains("\"\(name)\":"), "the import map has no \(name)")
        }

        // In a web view: the page's first message is `hello`, and the answer is drawn.
        var received: [JSONValue] = []
        let (host, window) = makeHost(pluginID: "assistant", folder: plugin.folder, manifest: plugin.manifest) { payload in
            received.append(payload)
            return Self.readyState
        }
        defer { close(host, window) }
        let emptyChat = "Ask anything. In this version the Assistant can't see your pages or act for you yet."
        await wait("the empty chat") { await text(host, "p.empty") == emptyChat }
        #expect(await text(host, "p.empty") == emptyChat)
        #expect(received.first == .object(["type": .string("hello")]))
        #expect(await text(host, ".billing") == "Claude plan")
        // The stylesheet the page adds by itself is allowed by the policy and applied.
        await wait("the stylesheet") {
            (try? await host.webView.evaluateJavaScript(
                "[...document.styleSheets].some((s) => (s.href ?? '').endsWith('/panel.css') && s.cssRules.length > 0)")) as? Bool == true
        }

        // A piece of an answer pushed by the background: Markdown is drawn, HTML stays text.
        host.post(.object(["type": .string("delta"), "text": .string("Hello **there** <img src=x>"), "version": .number(2)]))
        await wait("the answer") { await text(host, ".message.assistant strong") == "there" }
        #expect(await text(host, ".message.assistant") == "Hello there <img src=x>")
        #expect(try await host.webView.evaluateJavaScript("document.querySelectorAll('img').length") as? Int == 0)
        #expect(await text(host, "p.empty") == "")
    }

    /// A first `hello` that gets no answer (a background restarting after a crash) leaves the page
    /// with the reason and Try Again, which asks again.
    @Test(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func theAssistantsPageCanTryTheFirstHelloAgain() async throws {
        let plugin = try AssistantCopy()
        defer { plugin.remove() }
        var hellos = 0
        let (host, window) = makeHost(pluginID: "assistant", folder: plugin.folder, manifest: plugin.manifest) { _ in
            hellos += 1
            return hellos == 1 ? nil : Self.readyState
        }
        defer { close(host, window) }
        let failed = "the plugin isn't running or didn't answer"
        await wait("the failed hello") { await text(host, ".notice.warn p") == failed }
        #expect(await text(host, ".notice.warn button") == "Try Again")
        _ = try await host.webView.evaluateJavaScript("document.querySelector('.notice.warn button').click(); 1")
        let emptyChat = "Ask anything. In this version the Assistant can't see your pages or act for you yet."
        await wait("the empty chat after Try Again") { await text(host, "p.empty") == emptyChat }
        #expect(hellos == 2)
    }

    /// What the Assistant's background answers `hello` with once Claude is ready (see view.ts, ViewState).
    private static let readyState: JSONValue = .object([
        "messages": .array([]), "status": .string("ready"), "model": .null, "models": .array([]),
        "billing": .string("plan"), "billingNoticeSeen": .bool(true), "configFolder": .string(""),
        "providerVersion": .string("2.1.323"), "sdkVersion": .string("0.3.323"), "error": .null,
        "version": .number(1),
    ])

    /// The text of the first element matching `selector`; "" when there is none.
    private func text(_ host: PluginPageHost, _ selector: String) async -> String {
        let result = try? await host.webView.callAsyncJavaScript(
            "return document.querySelector(selector)?.textContent ?? ''", arguments: ["selector": selector],
            in: nil, contentWorld: .page)
        return result as? String ?? ""
    }

    // MARK: Helpers

    private func makeHost(_ plugin: FixturePlugin,
                          send: @escaping (JSONValue) async -> JSONValue? = { _ in nil }) -> (PluginPageHost, NSWindow) {
        makeHost(pluginID: "demo", folder: plugin.folder, manifest: plugin.manifest, send: send)
    }

    private func makeHost(pluginID: String, folder: URL, manifest: PluginManifest,
                          send: @escaping (JSONValue) async -> JSONValue?) -> (PluginPageHost, NSWindow) {
        MainRunLoopGuard.start
        let scripts = ArtifactScriptService(runtime: bunPath, hostFolder: hostFolder)
        let host = PluginPageHost(pluginID: pluginID, folder: folder, manifest: manifest,
                                  compile: { await scripts.javascript(for: $0) }, send: send)
        // Off screen and never key (a key window of the test process can take the owner's keyboard).
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView!.addSubview(host.webView)
        window.orderFront(nil)
        return (host, window)
    }

    private func close(_ host: PluginPageHost, _ window: NSWindow) {
        host.tearDown()
        window.close()
    }

    private func wait(_ what: String, seconds: Double = 20, until condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for: \(what)")
    }

    private struct Reply {
        var status = 0
        var headers: [String: String] = [:]
        var body = Data()
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// Stands in for WebKit's side of one request. (WebKit calls the handler on the main thread,
    /// and so does the test; the protocol itself isn't main-actor isolated.)
    private final class FakeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
        let request: URLRequest
        var reply = Reply()
        var finished: CheckedContinuation<Void, Never>?
        init(request: URLRequest) { self.request = request }
        func didReceive(_ response: URLResponse) {
            let http = response as! HTTPURLResponse
            reply.status = http.statusCode
            for (key, value) in http.allHeaderFields { reply.headers["\(key)"] = "\(value)" }
        }
        func didReceive(_ data: Data) { reply.body.append(data) }
        func didFinish() { finished?.resume(); finished = nil }
        func didFailWithError(_ error: any Error) { finished?.resume(); finished = nil }
    }

    private func fetch(_ server: PluginPageServer, _ path: String, method: String = "GET") async -> Reply {
        await fetch(server, url: "singularity-plugin://demo/" + path, method: method)
    }

    private func fetch(_ server: PluginPageServer, url: String, method: String = "GET") async -> Reply {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        MainRunLoopGuard.start
        let task = FakeTask(request: request)
        await withCheckedContinuation { continuation in
            task.finished = continuation
            server.webView(WKWebView(), start: task)
        }
        return task.reply
    }

    private static func nonce(in policy: String) -> String? {
        guard let start = policy.range(of: "'nonce-"), let end = policy[start.upperBound...].firstIndex(of: "'") else { return nil }
        return String(policy[start.upperBound..<end])
    }

    private static func literal(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
}

/// A plugin folder in a temporary directory: a TSX panel that imports a sibling module and a
/// package shaped like Preact (hand-written, no install), plus things that must never be served.
private struct FixturePlugin {
    let base: URL
    let folder: URL
    let manifest: PluginManifest

    /// `page`: the manifest's `panel.page`.
    init(page: String = "panel.tsx") throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "sg-pp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let folder = base.appending(path: "demo", directoryHint: .isDirectory)
        func write(_ path: String, _ text: String) throws {
            let file = folder.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("plugin.json", """
            {"id": "demo", "name": "Demo", "version": "1.0.0", "description": "A test panel.", "author": "Tests",
             "background": "background.ts", "panel": {"page": "\(page)", "title": "Demo"}, "permissions": {}}
            """)
        try write("background.ts", "// A panel needs a background program (never run here).\n")
        try write("package.json", #"{"dependencies": {"preact": "10.0.0"}}"#)
        // A well-formed lock entry for the declared version (the integrity is 64 zero bytes).
        let integrity = "sha512-" + Data(count: 64).base64EncodedString()
        try write("bun.lock", """
            {"lockfileVersion": 1, "workspaces": {"": {"name": "demo", "dependencies": {"preact": "10.0.0"}}},
             "packages": {"preact": ["preact@10.0.0", "", {}, "\(integrity)"]}}
            """)
        try write("node_modules/preact/package.json", """
            {"name": "preact", "version": "10.0.0",
             "exports": {".": {"import": "./dist/preact.mjs"}, "./jsx-runtime": {"import": "./jsx-runtime/dist/jsxRuntime.mjs"}}}
            """)
        try write("node_modules/preact/dist/preact.mjs", """
            export function h(type, props) { return { type, props }; }
            export function render(vnode, parent) {
              const element = document.createElement(vnode.type);
              element.id = vnode.props.id;
              element.textContent = vnode.props.children;
              parent.append(element);
              document.title = "rendered:" + element.textContent;
            }
            """)
        // Imports the package by its bare name too, through the import map.
        try write("node_modules/preact/jsx-runtime/dist/jsxRuntime.mjs", """
            import { h } from "preact";
            export function jsx(type, props) { return h(type, props); }
            export const jsxs = jsx;
            """)
        try write("util.ts", #"export const marker: string = "from-util";"#)
        try write("attack.ts", """
            export async function attack(url: string): Promise<string> {
              const results: string[] = [];
              try { await fetch(url + "fetch"); results.push("fetch:ok"); } catch { results.push("fetch:blocked"); }
              results.push(await new Promise<string>((resolve) => {
                const image = new Image();
                image.onload = () => resolve("img:ok");
                image.onerror = () => resolve("img:blocked");
                image.src = url + "image.png";
              }));
              results.push(await new Promise<string>((resolve) => {
                const frame = document.createElement("iframe");
                frame.src = url + "frame";
                document.body.append(frame);
                // A blocked frame stays empty; a loaded one would have the site's text.
                setTimeout(() => {
                  let text = "";
                  try { text = frame.contentDocument?.body?.textContent ?? ""; } catch { text = "cross-origin"; }
                  resolve(text === "" ? "frame:blocked" : "frame:ok");
                }, 500);
              }));
              const opened = window.open(url + "popup");
              results.push(opened ? "open:ok" : "open:blocked");
              return results.join(",");
            }
            """)
        try write("panel.tsx", """
            /** @jsxImportSource preact */
            import { render } from "preact";
            import { marker } from "./util";
            import { attack } from "./attack";
            (window as any).attack = attack;
            render(<b id="out">{marker}</b>, document.getElementById("root")!);
            """)
        try write("ui/panel.tsx", """
            /** @jsxImportSource preact */
            import { render } from "preact";
            import { marker } from "../util";
            render(<b id="out">{"ui:" + marker}</b>, document.getElementById("root")!);
            """)
        try write("index.html", "<!doctype html><title>top page</title>")
        try write("ui/index.html", "<!doctype html><title>ui page</title>")
        // Never served: hidden files, and a link that points out of the folder.
        try write(".secret", "hidden")
        try write(".git/config", "hidden")
        try Data("outside the plugin".utf8).write(to: base.appending(path: "outside.txt"))
        try fm.createSymbolicLink(atPath: folder.appending(path: "leak.txt").path, withDestinationPath: "../outside.txt")

        self.base = base
        self.folder = folder
        manifest = try PluginManifest.load(from: folder)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

/// A copy of the bundled Assistant plugin (`Plugins/assistant`) in a temporary directory, with a
/// hand-written stand-in for Preact in `node_modules/preact`: laid out like the real package
/// (`exports` for ".", "./hooks" and "./jsx-runtime") and providing exactly what `panel.tsx` uses:
/// `Fragment`, `render`, `useState`, `useRef`, `useEffect`, `useLayoutEffect`, `jsx` and `jsxs`.
/// It has no diffing: every change builds the page's DOM again.
private struct AssistantCopy {
    let base: URL
    let folder: URL
    let manifest: PluginManifest

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "sg-as-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let folder = base.appending(path: "assistant", directoryHint: .isDirectory)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.copyItem(at: repoRoot.appending(path: "Plugins/assistant", directoryHint: .isDirectory), to: folder)
        // Packages someone installed by hand in the repository are not what this test is about.
        try? fm.removeItem(at: folder.appending(path: "node_modules"))
        func write(_ path: String, _ text: String) throws {
            let file = folder.appending(path: "node_modules/preact/" + path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("package.json", """
            {"name": "preact", "version": "11.2.0", "type": "module",
             "exports": {".": {"import": "./dist/preact.mjs"},
                         "./hooks": {"import": "./hooks/dist/hooks.mjs"},
                         "./jsx-runtime": {"import": "./jsx-runtime/dist/jsxRuntime.mjs"}}}
            """)
        try write("dist/preact.mjs", """
            // Hook state lives in slots named by the component's place in the tree (as in real
            // Preact, hooks.mjs reaches it through `options`).
            const slots = new Map();
            let frame = null, root = null, queued = false, layoutEffects = [], effects = [];

            export function Fragment(props) { return props.children; }

            export const options = {
              slot() {
                const key = frame.path + "#" + frame.next++;
                return { fresh: !slots.has(key), get: () => slots.get(key), set: (value) => slots.set(key, value) };
              },
              rerender() {
                if (queued) return;
                queued = true;
                queueMicrotask(() => { queued = false; draw(); });
              },
              layoutEffect(run) { layoutEffects.push(run); },
              effect(run) { effects.push(run); },
            };

            function build(node, path) {
              if (node === null || node === undefined || typeof node === "boolean") return [];
              if (Array.isArray(node)) return node.flatMap((child, i) => build(child, path + "." + i));
              if (typeof node !== "object") return [document.createTextNode(String(node))];
              const { type, props } = node;
              if (typeof type === "function") {
                const outer = frame;
                frame = { path: path + "/" + type.name, next: 0 };
                try { return build(type(props), frame.path); } finally { frame = outer; }
              }
              const element = document.createElement(type);
              for (const [name, value] of Object.entries(props)) {
                if (name === "children") continue;
                if (name === "ref") { if (value) value.current = element; }
                else if (name === "class") element.className = value ?? "";
                else if (name.startsWith("on") && typeof value === "function") element.addEventListener(name.slice(2).toLowerCase(), value);
                else if (!name.includes("-") && name in element) element[name] = value;
                else if (value !== false && value !== null && value !== undefined) element.setAttribute(name, String(value));
              }
              element.append(...build(props.children, path));
              return [element];
            }

            function draw() {
              layoutEffects = [];
              root.parent.replaceChildren(...build(root.vnode, ""));
              for (const run of layoutEffects.splice(0)) run();
              const later = effects.splice(0);
              if (later.length > 0) setTimeout(() => { for (const run of later) run(); }, 0);
            }

            export function render(vnode, parent) { root = { vnode, parent }; draw(); }
            """)
        try write("hooks/dist/hooks.mjs", """
            import { options } from "preact";

            function changed(before, after) {
              return before === undefined || after === undefined || before.length !== after.length
                || before.some((value, i) => !Object.is(value, after[i]));
            }

            export function useState(initial) {
              const slot = options.slot();
              if (slot.fresh) slot.set(typeof initial === "function" ? initial() : initial);
              const set = (next) => {
                const value = typeof next === "function" ? next(slot.get()) : next;
                if (!Object.is(value, slot.get())) { slot.set(value); options.rerender(); }
              };
              return [slot.get(), set];
            }

            export function useRef(initial) {
              const slot = options.slot();
              if (slot.fresh) slot.set({ current: initial });
              return slot.get();
            }

            export function useEffect(run, deps) {
              const slot = options.slot();
              if (changed(slot.fresh ? undefined : slot.get(), deps)) { slot.set(deps); options.effect(run); }
            }

            // Every change makes new elements, so a layout effect (which works on them) runs every time.
            export function useLayoutEffect(run) { options.layoutEffect(run); }
            """)
        try write("jsx-runtime/dist/jsxRuntime.mjs", """
            export { Fragment } from "preact";
            export function jsx(type, props) { return { type, props }; }
            export const jsxs = jsx;
            """)

        self.base = base
        self.folder = folder
        manifest = try PluginManifest.load(from: folder)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

/// A local site that only counts connections and answers "ok". In-process (Network framework),
/// so the test can ask how many requests reached it.
private final class CountingServer: @unchecked Sendable {   // `count` behind `lock`
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private(set) var url = URL(string: "http://127.0.0.1/")!

    var connections: Int { lock.withLock { count } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> CountingServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = CountingServer(listener: try NWListener(using: parameters))
        let queue = DispatchQueue(label: "plugin-page-tests.counting-server")
        server.listener.newConnectionHandler = { connection in
            server.lock.withLock { server.count += 1 }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let answer = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OnceFlag()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: server.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            server.listener.start(queue: queue)
        }
        server.url = URL(string: "http://127.0.0.1:\(port)/")!
        return server
    }

    func stop() { listener.cancel() }
}

/// Lets exactly one caller through (a continuation must be resumed once).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
