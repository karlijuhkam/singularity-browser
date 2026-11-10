import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Singularity

/// The web-tab features that only exist with a real WKWebView in a real window.
/// The window sits far off screen, so nothing flashes up while the tests run.
@MainActor
@Suite(.serialized) struct WebTabTests {
    private func makeTab() -> (WebTabController, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WebTabController(tabID: UUID(), spaceID: UUID(), configuration: configuration, state: nil)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.webView.frame = window.contentView!.bounds
        window.contentView!.addSubview(controller.webView)
        window.orderFront(nil)
        return (controller, window)
    }

    /// Polls until `condition` holds; fails the test after `seconds`.
    private func wait(_ what: String, seconds: Double = 10, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func findAndZoom() async {
        let (tab, window) = makeTab()
        defer { window.close() }
        tab.webView.loadHTMLString("<title>words</title><p>alpha beta gamma</p>", baseURL: nil)
        await wait("page load") { tab.webView.title == "words" }

        tab.findText = "zzz"
        tab.find()
        await wait("no match reported") { tab.findFailed }
        tab.findText = "beta"
        tab.find()
        await wait("match found") { !tab.findFailed }
        let selection = try? await tab.webView.evaluateJavaScript("getSelection().toString()") as? String
        #expect(selection == "beta")

        tab.zoom(larger: true)
        #expect(tab.webView.pageZoom == 1.1)
        tab.zoom(larger: false)
        tab.zoom(larger: false)
        #expect(tab.webView.pageZoom == 0.9)
        tab.resetZoom()
        #expect(tab.webView.pageZoom == 1.0)
    }

    @Test func findBarShowsAndTakesFocusAgain() async {
        let (tab, window) = makeTab()
        defer { window.close() }
        let host = NSHostingView(rootView: FindBar(controller: tab))
        window.contentView!.addSubview(host)
        host.frame.size = host.fittingSize
        #expect(host.fittingSize.width > 150 && host.fittingSize.height > 20)

        let before = tab.findFocusToken
        tab.showFindBar()
        #expect(tab.isFindBarVisible && tab.findFocusToken == before + 1)
        tab.hideFindBar()
        #expect(!tab.isFindBarVisible)
    }

    @Test func failedLoadShowsTheErrorPageAndReloadRetries() async {
        let (tab, window) = makeTab()
        defer { window.close() }
        let dead = URL(string: "http://127.0.0.1:9/")! // a port WebKit refuses to talk to
        tab.load(dead)
        await wait("error page") { tab.webView.title == "Can’t open this page" }
        #expect(tab.webView.url == dead)

        // Reload tries the address again (and fails again, back onto the error page).
        tab.reload()
        await wait("loading again") { tab.webView.isLoading }
        await wait("error page again") { !tab.webView.isLoading && tab.webView.title == "Can’t open this page" }
        #expect(tab.webView.url == dead)

        // Leaving the error page for a real page works and Reload then reloads that page.
        tab.webView.loadHTMLString("<title>fine</title>", baseURL: nil)
        await wait("good page") { tab.webView.title == "fine" }
    }

    @Test func passwordProtectedSiteAsksInASheetAndLogsIn() async throws {
        let server = try BasicAuthServer.start()
        defer { server.stop() }
        let (tab, window) = makeTab()
        defer { window.close() }
        tab.load(server.url)

        await wait("login sheet") { window.attachedSheet != nil }
        guard let sheet = window.attachedSheet else { return }
        let views = allSubviews(of: sheet.contentView!)
        let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let name = fields.first { !($0 is NSSecureTextField) }
        let password = fields.first { $0 is NSSecureTextField }
        let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        #expect(texts.contains("Log in to 127.0.0.1"))
        #expect(texts.contains("Staging"))
        #expect(texts.contains("not encrypted"))
        name?.stringValue = "u"
        password?.stringValue = "p"
        let logIn = views.compactMap { $0 as? NSButton }.first { $0.title == "Log In" }
        #expect(logIn != nil)
        logIn?.performClick(nil)

        await wait("page behind the login") { tab.webView.title == "secret" }
    }

    @Test func aTabThatIsNotOnScreenNeverAsksForAPassword() async throws {
        let server = try BasicAuthServer.start()
        defer { server.stop() }
        let (tab, window) = makeTab()
        tab.webView.removeFromSuperview() // like a tab an agent opened in the background
        defer { window.close() }
        tab.load(server.url)
        await wait("the server's own 401 page") { tab.webView.title == "401" }
        #expect(NSApp?.modalWindow == nil)
    }

    @Test func printOpensThePrintSheet() async {
        let (tab, window) = makeTab()
        defer { window.close() }
        tab.webView.loadHTMLString("<title>paper</title><p>print me</p>", baseURL: nil)
        await wait("page load") { tab.webView.title == "paper" }
        tab.printPage()
        await wait("print sheet") { window.attachedSheet != nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }
}

/// A tiny local site behind HTTP Basic auth (name "u", password "p"), run with the system Python.
private struct BasicAuthServer {
    let process: Process
    let url: URL

    static func start() throws -> BasicAuthServer {
        let script = """
        import base64, http.server, sys
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                ok = self.headers.get("Authorization") == "Basic " + base64.b64encode(b"u:p").decode()
                self.send_response(200 if ok else 401)
                if not ok: self.send_header("WWW-Authenticate", 'Basic realm="Staging"')
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(b"<title>secret</title>" if ok else b"<title>401</title>")
            def log_message(self, *a): pass
        s = http.server.HTTPServer(("127.0.0.1", 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // The first line it prints is the port it got.
        var line = ""
        while !line.hasSuffix("\n") {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            line += String(decoding: data, as: UTF8.self)
        }
        let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return BasicAuthServer(process: process, url: URL(string: "http://127.0.0.1:\(port)/")!)
    }

    func stop() { process.terminate() }
}
