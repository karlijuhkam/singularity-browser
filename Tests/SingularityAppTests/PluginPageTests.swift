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
    func thePageCannotReachTheNetwork() async throws {
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

        // After tearDown nothing is delivered (and nothing breaks).
        host.tearDown()
        host.post(.string("too late"))
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

    // MARK: Helpers

    private func makeHost(_ plugin: FixturePlugin,
                          send: @escaping (JSONValue) async -> JSONValue? = { _ in nil }) -> (PluginPageHost, NSWindow) {
        MainRunLoopGuard.start
        let scripts = ArtifactScriptService(runtime: bunPath, hostFolder: hostFolder)
        let host = PluginPageHost(pluginID: "demo", folder: plugin.folder, manifest: plugin.manifest,
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

    init() throws {
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
             "panel": {"page": "panel.tsx", "title": "Demo"}, "permissions": {}}
            """)
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
