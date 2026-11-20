import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// Browser extensions in a real `AppState`, with a fixture MV3 extension (content script,
/// background, a declarativeNetRequest rule, a popup) and a local fixture site. No network, no
/// key window, nothing from Chrome Web Store.
@MainActor
@Suite(.serialized) struct ExtensionTests {
    static let extensionID = "local-0e0e0e0e"

    static let files: [String: String] = [
        "manifest.json": """
        {"manifest_version":3,"name":"SG Fixture","version":"1.0",
         "background":{"service_worker":"bg.js"},
         "content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["cs.js"],"run_at":"document_end"}],
         "permissions":["storage","declarativeNetRequest"],
         "declarative_net_request":{"rule_resources":[{"id":"r","enabled":true,"path":"rules.json"}]},
         "options_page":"options.html",
         "action":{"default_popup":"popup.html","default_title":"Fixture"}}
        """,
        "bg.js": "chrome.runtime.onMessage.addListener((m, s, r) => { r({pong: m.ping + 1}); return true; });",
        "cs.js": """
        document.documentElement.dataset.sgExt = 'cs';
        chrome.runtime.sendMessage({ping: 1}).then(r => document.documentElement.dataset.sgBg = String(r && r.pong))
          .catch(e => document.documentElement.dataset.sgBg = 'err:' + e);
        """,
        "rules.json": #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"blocked.js","resourceTypes":["script"]}}]"#,
        "popup.html": "<!doctype html><p>popup</p>",
        "options.html": "<!doctype html><title>Fixture options</title><p>options</p>",
    ]

    static func writeExtension(to folder: URL, changing: Bool = false) throws {
        for (name, text) in files {
            let url = folder.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A local site: `/` is a page that loads `/blocked.js` (which the extension's rule blocks).
    final class Site {
        let process: Process
        let port: Int
        init() throws {
            let script = ##"""
            import http.server, os, threading, time
            PARENT = os.getppid()
            def watch():
                while os.getppid() == PARENT: time.sleep(0.2)
                os._exit(0)
            threading.Thread(target=watch, daemon=True).start()
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path.startswith("/blocked.js"): body, ct = "window.blockedLoaded = true;", "text/javascript"
                    else: body, ct = "<!doctype html><title>page</title><p>hello</p><script src='/blocked.js'></script><script>document.documentElement.dataset.blocked = window.blockedLoaded ? 'loaded' : 'blocked'</script>", "text/html"
                    data = body.encode()
                    self.send_response(200); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
                def log_message(self, *a): pass
            s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
            print(s.server_address[1], flush=True)
            s.serve_forever()
            """##
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script]
            let line = try startFixtureServer(process)
            port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }
        func stop() { process.terminate() }
    }

    @MainActor final class Rig {
        let root = TestAppState.makeRoot()
        let site: Site
        let state: AppState
        let work: UUID
        let home: UUID
        let workTab: UUID
        let homeTab: UUID

        /// Two Spaces, a web tab of the fixture site in each; the extension installed and switched
        /// on in "Work" only (unless `installed` is false). `changeAfterApproval` edits a file after
        /// the fingerprint was taken.
        init(installed: Bool = true, changeAfterApproval: Bool = false) throws {
            MainRunLoopGuard.start
            site = try Site()
            let paths = Paths(root: root)
            let store = SpaceStore(paths: paths)
            var workSpace = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
            var homeSpace = Space(name: "Home", slug: "home", colorHex: "#F4A15E")
            let a = BrowserTab.web(site.url)
            let b = BrowserTab.web(site.url)
            workSpace.append(a); workSpace.selectedTabID = a.id
            homeSpace.append(b); homeSpace.selectedTabID = b.id
            try store.save(workSpace)
            try store.save(homeSpace)
            try store.save(AppStateFile(spaceOrder: [workSpace.id, homeSpace.id], selectedSpaceID: workSpace.id))
            if installed {
                let folder = paths.extensionsDirectory.appending(path: ExtensionTests.extensionID)
                try ExtensionTests.writeExtension(to: folder)
                let fingerprint = try PluginFingerprint.compute(folder: folder)
                if changeAfterApproval { try "/* changed */".write(to: folder.appending(path: "cs.js"), atomically: true, encoding: .utf8) }
                let record = ExtensionRecord(id: ExtensionTests.extensionID, name: "SG Fixture", version: "1.0", source: .file,
                                             fingerprint: fingerprint, permissions: ["storage", "declarativeNetRequest"],
                                             patterns: ["http://127.0.0.1/*"], enabledSpaces: [workSpace.id])
                try ExtensionStateStore(file: paths.extensionStateFile).save([record.id: record])
            }
            state = TestAppState.make(root: root)
            work = workSpace.id
            home = homeSpace.id
            workTab = a.id
            homeTab = b.id
        }

        func page(_ tabID: UUID, _ spaceID: UUID) async throws -> WebTabController {
            let controller = try #require(await state.liveWebController(tabID: tabID, spaceID: spaceID))
            try await waitUntil("the page", limit: .seconds(10)) { !controller.webView.isLoading && controller.webView.url != nil }
            return controller
        }

        func reload(_ controller: WebTabController) async throws {
            controller.reload()
            try await Task.sleep(for: .milliseconds(200))
            try await waitUntil("the reload", limit: .seconds(10)) { !controller.webView.isLoading }
        }

        func tearDown() {
            TestAppState.shutDown(state)
            site.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func attribute(_ controller: WebTabController, _ name: String) async -> String {
        (try? await controller.webView.evaluateJavaScript("document.documentElement.dataset.\(name) || ''") as? String) ?? "?"
    }

    /// Polls an async condition (page values come from JavaScript).
    static func eventually(_ what: String, limit: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for: \(what)")
        return false
    }

    /// In the Space it is on in: the content script runs, its message reaches the background and
    /// comes back (only possible when the app answers WebKit's tab questions), and the request
    /// rule blocks. In the other Space nothing of it runs.
    @Test(.timeLimit(.minutes(1))) func runsInItsSpaceOnly() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await waitUntil("extensions ready", limit: .seconds(10)) { rig.state.extensions.isReady }
        #expect(rig.state.extensions.statuses[Self.extensionID] == .ready)

        let workPage = try await rig.page(rig.workTab, rig.work)
        _ = await Self.eventually("the content script") { await Self.attribute(workPage, "sgExt") == "cs" }
        _ = await Self.eventually("the background's answer") { await Self.attribute(workPage, "sgBg") == "2" }
        #expect(await Self.attribute(workPage, "blocked") == "blocked")
        #expect(rig.state.extensions.loadedIDs(in: rig.work) == [Self.extensionID])

        let homePage = try await rig.page(rig.homeTab, rig.home)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await Self.attribute(homePage, "sgExt") == "")
        #expect(await Self.attribute(homePage, "blocked") == "loaded")
        #expect(rig.state.extensions.loadedIDs(in: rig.home).isEmpty)

        // The toolbar has its button on the Work page, none on the Home page.
        #expect(rig.state.extensions.toolbarItems(spaceID: rig.work, tabID: rig.workTab).map(\.id) == [Self.extensionID])
        #expect(rig.state.extensions.toolbarItems(spaceID: rig.home, tabID: rig.homeTab).isEmpty)
    }

    /// The Space switch and the site switch take it away from the next load.
    @Test(.timeLimit(.minutes(1))) func switchesTurnItOff() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await waitUntil("extensions ready", limit: .seconds(10)) { rig.state.extensions.isReady }
        let page = try await rig.page(rig.workTab, rig.work)
        _ = await Self.eventually("the content script") { await Self.attribute(page, "sgExt") == "cs" }

        // Off for this site.
        let site = try #require(SiteInfo.site(of: rig.site.url))
        rig.state.updateSiteSettings(spaceID: rig.work, site: site) { $0.disabledExtensions.insert(Self.extensionID) }
        try await rig.reload(page)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await Self.attribute(page, "sgExt") == "")

        // On again for the site.
        rig.state.updateSiteSettings(spaceID: rig.work, site: site) { $0.disabledExtensions.remove(Self.extensionID) }
        try await rig.reload(page)
        _ = await Self.eventually("the content script again") { await Self.attribute(page, "sgExt") == "cs" }

        // Off for the Space.
        rig.state.extensions.setEnabled(Self.extensionID, spaceID: rig.work, on: false)
        #expect(rig.state.extensions.loadedIDs(in: rig.work).isEmpty)
        try await rig.reload(page)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await Self.attribute(page, "sgExt") == "")
        #expect(await Self.attribute(page, "blocked") == "loaded")
    }

    /// A file changed after approval: the extension is paused and runs nowhere.
    @Test(.timeLimit(.minutes(1))) func changedFilesPauseIt() async throws {
        let rig = try Rig(changeAfterApproval: true)
        defer { rig.tearDown() }
        try await waitUntil("extensions ready", limit: .seconds(10)) { rig.state.extensions.isReady }
        #expect(rig.state.extensions.statuses[Self.extensionID] == .changed)
        let page = try await rig.page(rig.workTab, rig.work)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await Self.attribute(page, "sgExt") == "")
        #expect(rig.state.extensions.loadedIDs(in: rig.work).isEmpty)
    }

    /// Add Extension… with a .zip: nothing runs until Install; then it runs in the chosen Space,
    /// with its options page openable as a tab. Removing it takes it away and deletes its folder.
    @Test(.timeLimit(.minutes(1))) func addingAZipNeedsInstall() async throws {
        let rig = try Rig(installed: false)
        defer { rig.tearDown() }
        let source = rig.root.appending(path: "source")
        try Self.writeExtension(to: source)
        let zip = rig.root.appending(path: "fixture.zip")
        // Off the main thread: `waitUntilExit` runs the current run loop, where `MainRunLoopGuard` never returns.
        try await Task.detached {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path] // a zip with one top folder
            try ditto.run()
            ditto.waitUntilExit()
        }.value

        let page = try await rig.page(rig.workTab, rig.work)
        rig.state.extensions.add(file: zip, fromSpace: rig.work)
        try await waitUntil("the approval sheet's extension", limit: .seconds(10)) { rig.state.extensions.pending != nil }
        let pending = try #require(rig.state.extensions.pending)
        #expect(pending.webExtension.displayName == "SG Fixture")
        #expect(pending.extensionID.hasPrefix("local-"))
        #expect(rig.state.extensions.records.isEmpty)
        try await rig.reload(page)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await Self.attribute(page, "sgExt") == "") // not installed yet

        await rig.state.extensions.approve(pending, spaces: [rig.work])
        let id = pending.extensionID
        #expect(rig.state.extensions.records[id]?.enabledSpaces == [rig.work])
        #expect(FileManager.default.fileExists(atPath: rig.state.extensions.folder(of: id).appending(path: "manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: pending.staged.stage.path))
        try await rig.reload(page)
        _ = await Self.eventually("the content script after Install") { await Self.attribute(page, "sgExt") == "cs" }

        // Options page in a tab of the Space.
        let before = rig.state.space(rig.work)?.tabs.count ?? 0
        rig.state.extensions.openOptions(id, spaceID: rig.work)
        #expect(rig.state.space(rig.work)?.tabs.count == before + 1)
        let optionsTab = try #require(rig.state.space(rig.work)?.selectedTab)
        #expect(optionsTab.url?.scheme == "webkit-extension")
        let options = try await rig.page(optionsTab.id, rig.work)
        try await waitUntil("the options page's title", limit: .seconds(10)) { options.webView.title == "Fixture options" }

        rig.state.extensions.remove(id)
        #expect(rig.state.extensions.records[id] == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.state.extensions.folder(of: id).path))
        #expect(rig.state.extensions.loadedIDs(in: rig.work).isEmpty)
    }

    /// A folder with a symbolic link is refused before any sheet.
    @Test(.timeLimit(.minutes(1))) func linksAreRefused() async throws {
        let rig = try Rig(installed: false)
        defer { rig.tearDown() }
        let source = rig.root.appending(path: "linked")
        try Self.writeExtension(to: source)
        try FileManager.default.createSymbolicLink(at: source.appending(path: "passwd"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        rig.state.extensions.add(file: source, fromSpace: rig.work)
        try await waitUntil("the problem", limit: .seconds(10)) { rig.state.extensions.installMessage != nil }
        #expect(rig.state.extensions.pending == nil)
        #expect(rig.state.extensions.records.isEmpty)
    }

    /// On a Chrome Web Store detail page (here a fixture page with that address) the store's
    /// disabled "Add to Chrome" button becomes an enabled "Add to Singularity"; a page script's
    /// click on it asks for nothing (only the owner's real click does).
    @Test(.timeLimit(.minutes(1))) func storeButtonIsRelabelled() async throws {
        let rig = try Rig(installed: false)
        defer { rig.tearDown() }
        let page = try await rig.page(rig.workTab, rig.work)
        let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
        let html = """
        <!doctype html><title>store</title>
        <button id=other>Share</button>
        <button id=add disabled><span jsname="V67aGc">Add to Chrome</span></button>
        """
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://chromewebstore.google.com/detail/dark-reader/\(id)"))
        _ = await Self.eventually("the relabelled button") {
            (try? await page.webView.evaluateJavaScript("document.getElementById('add').innerText + '|' + document.getElementById('add').disabled") as? String) == "Add to Singularity|false"
        }
        #expect((try? await page.webView.evaluateJavaScript("document.getElementById('other').innerText") as? String) == "Share")
        _ = try? await page.webView.evaluateJavaScript("document.getElementById('add').click()")
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.state.extensions.downloading.isEmpty)
        #expect(rig.state.extensions.pending == nil)
    }

    /// The store moves between pages with `pushState`: a button that appears on a detail page
    /// reached that way is relabelled too, and on a page that isn't a detail page nothing changes.
    @Test(.timeLimit(.minutes(1))) func storeButtonAfterPushState() async throws {
        let rig = try Rig(installed: false)
        defer { rig.tearDown() }
        let page = try await rig.page(rig.workTab, rig.work)
        let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
        page.webView.loadHTMLString("<!doctype html><title>store</title><div id=box></div>",
                                    baseURL: URL(string: "https://chromewebstore.google.com/category/extensions"))
        try await waitUntil("the category page", limit: .seconds(10)) { page.webView.title == "store" }
        let addButton = "document.getElementById('box').innerHTML = '<button id=add disabled><span jsname=\"V67aGc\">Add to Chrome</span></button>'"
        _ = try? await page.webView.evaluateJavaScript(addButton)
        try await Task.sleep(for: .milliseconds(300))
        #expect((try? await page.webView.evaluateJavaScript("document.getElementById('add').disabled") as? Bool) == true)

        _ = try? await page.webView.evaluateJavaScript("history.pushState({}, '', '/detail/dark-reader/\(id)'); document.getElementById('box').innerHTML = ''")
        _ = try? await page.webView.evaluateJavaScript(addButton)
        _ = await Self.eventually("the relabelled button after pushState") {
            (try? await page.webView.evaluateJavaScript("document.getElementById('add').innerText + '|' + document.getElementById('add').disabled") as? String) == "Add to Singularity|false"
        }
    }

    /// Opt-in (`SG_REAL_STORE=1`, needs the network): Dark Reader from Chrome Web Store, through
    /// the same download, signature check and unpacking as the store button; up to the sheet.
    @Test(.timeLimit(.minutes(1))) func realStoreDownload() async throws {
        guard ProcessInfo.processInfo.environment["SG_REAL_STORE"] == "1" else { return }
        let rig = try Rig(installed: false)
        defer { rig.tearDown() }
        rig.state.extensions.addFromStore("eimadpbcbfnmbkopoojfekhnkhdbieeh", fromSpace: rig.work)
        try await waitUntil("the sheet", limit: .seconds(50)) { rig.state.extensions.pending != nil || rig.state.extensions.installMessage != nil }
        #expect(rig.state.extensions.installMessage == nil)
        let pending = try #require(rig.state.extensions.pending)
        #expect(pending.extensionID == "eimadpbcbfnmbkopoojfekhnkhdbieeh")
        #expect(pending.webExtension.displayName == "Dark Reader")
        rig.state.extensions.cancel(pending)
    }

    /// Deleting a Space lets go of its extension controller and takes the Space off the record.
    @Test(.timeLimit(.minutes(1))) func deletingASpaceForgetsIt() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await waitUntil("extensions ready", limit: .seconds(10)) { rig.state.extensions.isReady }
        _ = try await rig.page(rig.workTab, rig.work)
        #expect(rig.state.extensions.hasController(rig.work))
        rig.state.deleteSpace(rig.work)
        try await waitUntil("the controller to go", limit: .seconds(10)) { !rig.state.extensions.hasController(rig.work) }
        #expect(rig.state.extensions.records[Self.extensionID]?.enabledSpaces.isEmpty == true)
    }
}
}
