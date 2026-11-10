import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// The console and network collector (`PageCaptureScript`) in a real WKWebView against a local
/// fixture site: what it collects, that it leaves streaming responses alone, and that pages of
/// sites that aren't switched on see no trace of it.
@MainActor
@Suite(.serialized) struct PageCaptureScriptTests {
    /// Stands in for `CaptureBridge` (which needs the whole app): keeps what the relay sends.
    private final class Sink: NSObject, WKScriptMessageHandler {
        var capture = PageCapture()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let json = message.body as? String { capture.record(json: json) }
        }
    }

    private func makeWebView(sites: [String], sink: Sink) -> (WKWebView, NSWindow) {
        MainRunLoopGuard.start
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(sink, contentWorld: PageCaptureScript.world, name: PageCaptureScript.handlerName)
        for script in PageCaptureScript.scripts(sites: sites) { configuration.userContentController.addUserScript(script) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(webView)
        window.orderFront(nil)
        return (webView, window)
    }

    private func wait(_ what: String, seconds: Double = 15, until condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for: \(what)")
    }

    private func pageText(_ webView: WKWebView, _ id: String) async -> String {
        (try? await webView.evaluateJavaScript("document.getElementById('\(id)')?.textContent ?? ''") as? String) ?? ""
    }

    @Test func collectsProblemsOfASwitchedOnSite() async throws {
        let server = try FixtureServer.start()
        defer { server.stop() }
        let sink = Sink()
        let (webView, window) = makeWebView(sites: [server.site], sink: sink)
        defer { window.close() }

        webView.load(URLRequest(url: server.url))
        await wait("the page's script to finish") { await pageText(webView, "done") == "done" }
        await wait("all entries to arrive") { sink.capture.network.count >= 4 && sink.capture.console.count >= 5 }

        let console = sink.capture.consoleReport(since: nil).text
        #expect(console.contains("error: boom {\"a\":1}"))
        #expect(console.contains("warning: careful"))
        #expect(console.contains("exception:") && console.contains("thrown on purpose"))
        #expect(console.contains("rejection: Unhandled promise rejection:") && console.contains("rejected on purpose"))
        #expect(console.contains("resource: Failed to load <img> \(server.url.absoluteString)nope.png"))

        let network = sink.capture.networkReport(since: nil).text
        #expect(network.contains("POST \(server.url.absoluteString)missing → 404 (fetch)"))
        #expect(network.contains(#"{"q":"payload"}"#))            // what was sent
        #expect(network.contains(#"{"error":"no such thing"}"#))  // what came back
        #expect(network.contains("Authorization: [hidden]") && !network.contains("Bearer secret-token"))
        #expect(network.contains("GET \(server.url.absoluteString)boom → 500 (xhr)"))
        #expect(network.contains("server exploded"))
        #expect(network.contains("x-test: yes"))
        #expect(network.contains("→ failed") && network.contains("(fetch)"))  // the refused connection
        // A long error answer is cut, not kept whole.
        #expect(network.contains("big → 500") && network.contains("[cut:"))
        // Requests that worked are not collected.
        #expect(!network.contains("/ok"))

        // The page itself got everything it should: the error body it read, and the stream, piece by piece.
        #expect(await pageText(webView, "fetchBody") == #"{"error":"no such thing"}"#)
        #expect(await pageText(webView, "stream") == "chunks:5")
    }

    @Test func leavesOtherSitesUntouched() async throws {
        let server = try FixtureServer.start()
        defer { server.stop() }
        let sink = Sink()
        // Switched on for another site only.
        let (webView, window) = makeWebView(sites: ["https://example.com"], sink: sink)
        defer { window.close() }

        webView.load(URLRequest(url: server.url))
        await wait("the page's script to finish") { await pageText(webView, "done") == "done" }
        try await Task.sleep(for: .milliseconds(500))
        #expect(sink.capture.isEmpty)
        // No trace in the page: fetch, XHR and console are the browser's own, and no handler is visible.
        let native = try await webView.evaluateJavaScript("""
            [fetch, XMLHttpRequest.prototype.open, XMLHttpRequest.prototype.send, console.error, console.warn]
              .every((f) => Function.prototype.toString.call(f).includes("[native code]"))
              && !(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.singularityCapture)
            """) as? Bool
        #expect(native == true)
    }

    @Test func noScriptsWithoutSites() {
        #expect(PageCaptureScript.scripts(sites: []).isEmpty)
        #expect(PageCaptureScript.scripts(sites: ["http://localhost:3000"]).count == 2)
    }
}
}

/// A local fixture site, run with the system Python (as the Basic-auth test server is).
private struct FixtureServer {
    let process: Process
    let url: URL
    var site: String { "http://127.0.0.1:\(url.port!)" }

    static func start() throws -> FixtureServer {
        let script = ##"""
        import http.server, os, sys, threading, time
        # /usr/bin/python3 starts the real Python as another process, which the test's SIGTERM to
        # the first one doesn't reach. So leave when that parent is gone (also if the test dies).
        PARENT = os.getppid()
        def watch():
            while os.getppid() == PARENT: time.sleep(0.2)
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        PAGE = b"""<!doctype html><title>fixture</title>
        <p id="fetchBody"></p><p id="stream"></p><p id="done"></p><img src="nope.png">
        <script>
        (async () => {
          console.error("boom", {a: 1});
          console.warn("careful");
          setTimeout(() => { throw new Error("thrown on purpose"); }, 0);
          Promise.reject(new Error("rejected on purpose"));
          const r = await fetch("missing", {method: "POST", headers: {"Authorization": "Bearer secret-token", "Content-Type": "application/json"}, body: JSON.stringify({q: "payload"})});
          document.getElementById("fetchBody").textContent = await r.text();
          await fetch("ok");
          await fetch("big");
          try { await fetch("http://127.0.0.1:1/refused"); } catch (e) {}
          await new Promise((resolve) => { const x = new XMLHttpRequest(); x.open("GET", "boom"); x.onloadend = resolve; x.send(); });
          // A stream must arrive piece by piece, not all at once at the end.
          const s = await fetch("stream"); const reader = s.body.getReader(); let chunks = 0;
          while (true) { const {done} = await reader.read(); if (done) break; chunks++; }
          document.getElementById("stream").textContent = "chunks:" + chunks;
          document.getElementById("done").textContent = "done";
        })();
        </script>"""
        class H(http.server.BaseHTTPRequestHandler):
            def reply(self, status, ctype, body, extra=None):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (extra or {}).items(): self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                self.reply(404, "application/json", b'{"error":"no such thing"}')
            def do_GET(self):
                if self.path == "/": self.reply(200, "text/html", PAGE)
                elif self.path == "/ok": self.reply(200, "text/plain", b"fine")
                elif self.path == "/boom": self.reply(500, "text/plain", b"server exploded", {"X-Test": "yes"})
                elif self.path == "/big": self.reply(500, "text/plain", b"x" * 200000)
                elif self.path == "/stream":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for i in range(5):
                        self.wfile.write(b"data: %d\n\n" % i); self.wfile.flush(); time.sleep(0.15)
                else: self.reply(404, "text/plain", b"not found")
            def log_message(self, *a): pass
        s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """##
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        var line = ""
        while !line.hasSuffix("\n") {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            line += String(decoding: data, as: UTF8.self)
        }
        let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return FixtureServer(process: process, url: URL(string: "http://127.0.0.1:\(port)/")!)
    }

    func stop() { process.terminate() }
}
