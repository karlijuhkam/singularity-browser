import AppKit
import Foundation
import SingularityCore
import Testing
import WebKit
@testable import Singularity

/// Opt-in, never part of `scripts/test.sh`: the bundled Assistant's own page with the REAL Preact,
/// in a real `PluginPageHost` (WKWebView), against a fake background. It needs the network (npm)
/// but starts no program: no `claude`, no plugin background.
///
///     source scripts/env.sh && SINGULARITY_REAL_ASSISTANT_PAGE=1 swift test --filter RealAssistantPageTests
///
/// What it does:
/// - copies `Plugins/assistant` to `/private/tmp/sg-rp-<8 hex>/assistant` and installs its two
///   packages there with the repository's Bun and the app's own install (`PluginPackages.install`,
///   as approval does and as `RealAssistantTests` does);
/// - shows the page in an off-screen window that never becomes key, served and compiled as in the
///   app; `send` is a fake that answers `hello` with a ready, empty conversation in the shape
///   `background.ts` sends, and `send` with the state of an answer on its way;
/// - checks the empty-chat text, that `panel.css` applied, that the input is there and has the
///   focus, that it keeps it (enabled) after a message is sent, and that a pushed `delta` and
///   `state` put the answer in the page as text.
/// The temporary folder is removed afterwards.
private let realPageRequested = ProcessInfo.processInfo.environment["SINGULARITY_REAL_ASSISTANT_PAGE"] == "1"

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostFolder = repoRoot.appending(path: "Resources/plugin-host", directoryHint: .isDirectory)

extension AppTests {
    @MainActor
    @Suite(.serialized, .enabled(if: realPageRequested, "opt-in: set SINGULARITY_REAL_ASSISTANT_PAGE=1 (installs the Assistant's packages from npm)"))
    struct RealAssistantPageTests {
        @Test(.timeLimit(.minutes(5)))
        func theRealPageRendersWithRealPreact() async throws {
            guard FileManager.default.isExecutableFile(atPath: bunPath.path) else {
                Issue.record("Vendor/bun/bun is missing (run scripts/fetch-bun.sh)")
                return
            }
            MainRunLoopGuard.start
            let files = FileManager.default
            let root = URL(filePath: "/private/tmp/sg-rp-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
            try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: root) }
            let folder = root.appending(path: "assistant", directoryHint: .isDirectory)
            try files.copyItem(at: repoRoot.appending(path: "Plugins/assistant", directoryHint: .isDirectory), to: folder)
            // Packages someone installed by hand in the repository are not what this test is about.
            try? files.removeItem(at: folder.appending(path: "node_modules"))

            // The packages, as approval installs them.
            let install = await PluginPackages.install(folder: folder, runtime: bunPath, hostFolder: hostFolder,
                                                       stagingRoot: root.appending(path: "staging", directoryHint: .isDirectory))
            print("real-page: \(install.message)")
            guard install.outcome == .installed else {
                Issue.record("installing the packages failed: \(install.message)\n\(install.output)")
                return
            }
            let preactPackage = folder.appending(path: "node_modules/preact/package.json")
            let preactVersion = (try? JSONSerialization.jsonObject(with: Data(contentsOf: preactPackage)) as? [String: Any])?["version"]
            print("real-page: preact \(preactVersion.map { "\($0)" } ?? "missing")")
            #expect(preactVersion as? String == "11.2.0")

            // The fake background: `hello` gets the ready, empty conversation; `send` its answering state.
            let manifest = try PluginManifest.load(from: folder)
            var received: [JSONValue] = []
            let scripts = ArtifactScriptService(runtime: bunPath, hostFolder: hostFolder)
            let host = PluginPageHost(pluginID: "assistant", folder: folder, manifest: manifest,
                                      compile: { await scripts.javascript(for: $0) }) { payload in
                received.append(payload)
                guard case .object(let fields) = payload, case .string(let type)? = fields["type"] else {
                    return .object(["error": .string("unknown request")])
                }
                switch type {
                case "hello": return Self.state(status: "ready", messages: [], version: 1)
                case "send":
                    return Self.state(status: "answering", messages: [Self.message("user", "Hi")], version: 2)
                default: return .object(["error": .string("unknown request")])
                }
            }
            // Off screen and never key (a key window of the test process can take the owner's keyboard).
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host.webView.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
            window.contentView!.addSubview(host.webView)
            window.orderFront(nil)
            defer {
                host.tearDown()
                window.close()
            }

            // The page renders: the empty chat, after its first `hello`.
            let emptyChat = "Ask anything. In this version the Assistant can't see your pages or act for you yet."
            let rendered = await wait("the empty chat") { await text(host, "p.empty") == emptyChat }
            print("real-page: empty chat shown: \(rendered); body: \(await text(host, "body").prefix(300).debugDescription)")
            if !rendered {
                let problems = try? await host.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
                print("real-page: page HTML: \(problems?.prefix(2000) ?? "none")")
                Issue.record("the real page didn't render")
                return
            }
            #expect(received.first == .object(["type": .string("hello")]))
            // Real Preact, through the page's import map.
            let importMap = await evaluate(host, "document.querySelector('script[type=importmap]')?.textContent ?? ''") as? String ?? ""
            print("real-page: import map \(importMap.debugDescription)")
            #expect(importMap.contains("node_modules/preact/dist/preact.mjs"))
            #expect(await text(host, ".billing") == "Claude plan")

            // panel.css applied: only it makes `.app` a flex column and the textarea unresizable.
            let styled = await wait("the stylesheet") {
                await evaluate(host, "getComputedStyle(document.querySelector('.app')).display") as? String == "flex"
            }
            let resize = await evaluate(host, "getComputedStyle(document.querySelector('textarea')).resize") as? String
            print("real-page: .app display flex: \(styled); textarea resize: \(resize ?? "none")")
            #expect(styled)
            #expect(resize == "none")

            // The input is there, enabled, and has the focus (the page gives it on load).
            #expect(await evaluate(host, "document.querySelector('textarea') !== null && !document.querySelector('textarea').disabled") as? Bool == true)
            let focused = await wait("the input to have the focus", seconds: 5) {
                await evaluate(host, "document.activeElement === document.querySelector('textarea')") as? Bool == true
            }
            print("real-page: input focused on load: \(focused)")
            #expect(focused)

            // Typing and Send: the background answers with "answering"; the input stays enabled and focused.
            _ = await evaluate(host, """
                (() => { const t = document.querySelector('textarea'); t.value = 'Hi';
                         t.dispatchEvent(new Event('input', { bubbles: true })); return 1; })()
                """)
            _ = await wait("Send to be enabled") {
                await evaluate(host, "[...document.querySelectorAll('button')].some((b) => b.textContent === 'Send' && !b.disabled)") as? Bool == true
            }
            _ = await evaluate(host, "[...document.querySelectorAll('button')].find((b) => b.textContent === 'Send').click(), 1")
            #expect(await wait("the Stop button") {
                await evaluate(host, "[...document.querySelectorAll('button')].some((b) => b.textContent === 'Stop')") as? Bool == true
            })
            #expect(received.last == .object(["type": .string("send"), "text": .string("Hi")]))
            let afterSend = await evaluate(host, """
                (() => { const t = document.querySelector('textarea');
                         return JSON.stringify({ disabled: t.disabled, focused: document.activeElement === t, value: t.value }); })()
                """) as? String
            print("real-page: input after send: \(afterSend ?? "none")")
            #expect(afterSend == #"{"disabled":false,"focused":true,"value":""}"#)

            // A piece of the answer, then the state at the end of the turn: drawn as text.
            host.post(.object(["type": .string("delta"), "text": .string("Hello **there** <img src=x>"), "version": .number(3)]))
            #expect(await wait("the streamed answer") { await text(host, ".message.assistant strong") == "there" })
            var end = Self.state(status: "ready", messages: [Self.message("user", "Hi"),
                                                             Self.message("assistant", "Hello **there** <img src=x>")], version: 4)
            if case .object(var fields) = end {
                fields["type"] = .string("state")
                end = .object(fields)
            }
            host.post(end)
            #expect(await wait("the finished answer") {
                await evaluate(host, "[...document.querySelectorAll('button')].some((b) => b.textContent === 'Send')") as? Bool == true
            })
            let user = await text(host, ".message.user")
            let answer = await text(host, ".message.assistant")
            print("real-page: user \(user.debugDescription), answer \(answer.debugDescription)")
            #expect(user == "Hi")
            #expect(answer == "Hello there <img src=x>")
            #expect(await evaluate(host, "document.querySelectorAll('img').length") as? Int == 0)
            #expect(await evaluate(host, "document.querySelectorAll('.message').length") as? Int == 2)
            #expect(await text(host, "p.empty") == "")
        }

        /// The state `background.ts` sends (its `state()`: see view.ts, ViewState).
        private static func state(status: String, messages: [JSONValue], version: Int) -> JSONValue {
            .object([
                "messages": .array(messages), "status": .string(status), "model": .string("default"),
                "models": .array([.object(["id": .string("default"), "name": .string("Default (recommended)")])]),
                "billing": .string("plan"), "billingNoticeSeen": .bool(true), "configFolder": .string(""),
                "providerVersion": .string("2.1.323"), "sdkVersion": .string("0.3.323"), "error": .null,
                "version": .number(Double(version)),
            ])
        }

        private static func message(_ role: String, _ text: String) -> JSONValue {
            .object(["role": .string(role), "text": .string(text)])
        }

        /// The text of the first element matching `selector`; "" when there is none.
        private func text(_ host: PluginPageHost, _ selector: String) async -> String {
            let result = try? await host.webView.callAsyncJavaScript(
                "return document.querySelector(selector)?.textContent ?? ''", arguments: ["selector": selector],
                in: nil, contentWorld: .page)
            return result as? String ?? ""
        }

        private func evaluate(_ host: PluginPageHost, _ script: String) async -> Any? {
            try? await host.webView.evaluateJavaScript(script)
        }

        /// Polls `condition` until it holds (true) or `seconds` pass (false).
        private func wait(_ what: String, seconds: Double = 30, until condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("real-page: timed out waiting for \(what)")
            return false
        }
    }
}
