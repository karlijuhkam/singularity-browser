import Foundation

/// A small local site for tests about page titles and agent clicks, run with the system Python
/// (as the other fixture servers are). The same server answers on 127.0.0.1 and localhost, which
/// are two different sites.
/// - `/titled?t=<title>`: a page with that title
/// - `/untitled`: a page without a title
/// - `/slow-titled?t=<title>`, `/slow-untitled`: the same, answered after a second
/// - `/go`: a page titled "Go" with a button (`#go`) that moves the page to `/titled?t=There` on
///   the *other* host (127.0.0.1 ↔ localhost), i.e. to another site
struct TitleFixtureServer {
    let process: Process
    let port: Int

    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    static func start() throws -> TitleFixtureServer {
        let script = ##"""
        import http.server, os, threading, time, urllib.parse, html
        PARENT = os.getppid()
        def watch():
            while os.getppid() == PARENT: time.sleep(0.2)
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                q = urllib.parse.parse_qs(u.query)
                t = html.escape(q.get("t", ["Title"])[0])
                p = u.path
                if p.startswith("/slow-"):
                    time.sleep(1); p = "/" + p[len("/slow-"):]
                if p == "/titled": body = "<!doctype html><title>%s</title><p>titled</p>" % t
                elif p == "/untitled": body = "<!doctype html><p>no title here</p>"
                elif p == "/go": body = ("<!doctype html><title>Go</title><button id=go onclick=\"var h = location.hostname == '127.0.0.1' ? 'localhost' : '127.0.0.1';"
                                         " location.href = 'http://' + h + ':' + location.port + '/titled?t=There'\">Go</button>")
                else: body = "not found"
                data = body.encode()
                self.send_response(200 if body != "not found" else 404)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
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
        guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "the fixture server didn't start"])
        }
        return TitleFixtureServer(process: process, port: port)
    }

    func stop() { process.terminate() }
}
