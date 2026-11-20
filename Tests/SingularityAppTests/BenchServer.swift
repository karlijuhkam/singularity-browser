import Foundation

/// The agent bench (`Fixtures/bench`, the pages the 2026-11-20 comparison with Playwright MCP used),
/// served by the system Python on two ports of 127.0.0.1: two origins, for cross-origin frames.
/// Pages that need the other origin take its port as `?other=<port>` (`url(_:)` adds it).
struct BenchServer {
    let process: Process
    let port: Int
    let otherPort: Int

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/bench")

    /// A page on the main origin, with `?other=` (and any `query`) appended.
    func url(_ page: String, query: String = "", onOther: Bool = false) -> URL {
        let extra = query.isEmpty ? "" : "&" + query
        return URL(string: "http://127.0.0.1:\(onOther ? otherPort : port)/\(page)?other=\(onOther ? port : otherPort)\(extra)")!
    }

    static func start() throws -> BenchServer {
        let script = ##"""
        import http.server, os, sys, threading, time, functools
        PARENT = os.getppid()
        def watch():
            while os.getppid() == PARENT: time.sleep(0.2)
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        class H(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()
        handler = functools.partial(H, directory=sys.argv[1])
        servers = [http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) for _ in range(2)]
        for s in servers: threading.Thread(target=s.serve_forever, daemon=True).start()
        print(servers[0].server_address[1], servers[1].server_address[1], flush=True)
        while True: time.sleep(3600)
        """##
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, folder.path]
        let line = try startFixtureServer(process)
        let ports = line.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard ports.count == 2 else {
            process.terminate()
            throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "the bench server didn't start"])
        }
        return BenchServer(process: process, port: ports[0], otherPort: ports[1])
    }

    func stop() { process.terminate() }
}
