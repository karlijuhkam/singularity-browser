import AppKit
import Foundation
import Testing
@testable import Singularity
import SingularityCore

/// An outside API for apps' Workers to call, run with the system Python on 127.0.0.1 (which also
/// answers as "localhost": a second host, for redirects to a host that is not allowed).
/// - `/echo`: JSON with the request's path, Host and headers
/// - `/redirect?to=<url>`: 302 to that address
/// - `/big`: 9 MB of text (over what an app may fetch)
/// - `/seen`: JSON list of "<Host> <path>" for every request so far (itself not included)
private struct ApiFixtureServer {
    let process: Process
    let port: Int

    func url(_ path: String, host: String = "127.0.0.1") -> String { "http://\(host):\(port)\(path)" }

    static func start() throws -> ApiFixtureServer {
        let script = ##"""
        import http.server, json, os, threading, time, urllib.parse
        PARENT = os.getppid()
        def watch():
            while os.getppid() == PARENT: time.sleep(0.2)
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        SEEN = []
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                q = urllib.parse.parse_qs(u.query)
                if u.path == "/seen":
                    return self.answer(200, json.dumps(SEEN))
                SEEN.append(self.headers.get("Host", "") + " " + u.path)
                if u.path == "/echo":
                    return self.answer(200, json.dumps({"path": self.path, "host": self.headers.get("Host"),
                                                         "headers": dict(self.headers.items())}))
                if u.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", q["to"][0])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if u.path == "/big":
                    return self.answer(200, "x" * (9 * 1024 * 1024))
                self.answer(404, "not found")
            def answer(self, status, body):
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
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
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "the API fixture didn't start"])
        }
        return ApiFixtureServer(process: process, port: port)
    }

    func seen() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url("/seen"))!)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func stop() { process.terminate() }
}

extension AppTests {
/// Apps end to end: a real `AppState` on a temporary folder, the real artifact server, a real
/// sandboxed Worker (the repository's Bun and host script) from the fixture app, and an outside
/// API on loopback. Keys live in memory, never in the keychain. No window, nothing takes focus.
@MainActor
@Suite(.serialized, .enabled(if: TestAppState.hasBun, "needs Vendor/bun/bun (scripts/fetch-bun.sh)"))
struct AppsTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let keys: MemoryAppKeyStore
        let space: Space
        let other: Space
        let host: ArtifactHost
        var artifacts: URL { host.root }
        var center: InboxCenter { state.inbox }
    }

    private static let appFixture = TestAppState.repositoryRoot
        .appending(path: "Tests/SingularityCoreTests/Fixtures/apps/basic")

    /// Two Spaces ("work" selected). "work" has the app `firma` (the fixture, plus a page), the
    /// folder `firma2` and `plain` (plain artifacts, no manifest), and its server is running.
    private func makeFixture() async throws -> Fixture {
        MainRunLoopGuard.start
        let fm = FileManager.default
        let root = TestAppState.makeRoot()
        let paths = Paths(root: root)
        let store = SpaceStore(paths: paths)
        let work = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        let other = Space(name: "Other", slug: "other", colorHex: "#F45E81")
        try store.save(work)
        try store.save(other)
        try store.save(AppStateFile(spaceOrder: [work.id, other.id], selectedSpaceID: work.id))

        let artifacts = paths.artifactsDirectory("work")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try fm.copyItem(at: Self.appFixture, to: artifacts.appending(path: "firma"))
        try Data("<!doctype html><title>Firma</title><p>page</p>".utf8).write(to: artifacts.appending(path: "firma/index.html"))
        for folder in ["firma2", "plain"] {
            try fm.createDirectory(at: artifacts.appending(path: folder), withIntermediateDirectories: true)
            try Data("<p>plain</p>".utf8).write(to: artifacts.appending(path: "\(folder)/index.html"))
        }

        let keys = MemoryAppKeyStore()
        let state = TestAppState.make(root: root, keys: keys)
        state.inbox.appIsActive = { false }
        state.inbox.onArrival = { _ in }
        state.inbox.onChange = {}
        state.inbox.requestAttention = {}
        let host = try #require(await state.artifacts.ensureStarted(work, root: artifacts))
        return Fixture(root: root, state: state, keys: keys, space: work, other: other, host: host)
    }

    private func tearDown(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    /// A request to the Space's artifact server, as a page of that server would send it (the
    /// token as the app's first load sends it; `Origin` for anything but a read).
    private func send(_ f: Fixture, _ method: String = "GET", _ path: String, body: String? = nil,
                      headers: [String: String] = [:], token: Bool = true, origin: Bool = true) async throws -> (status: Int, text: String, response: HTTPURLResponse) {
        let base = try #require(f.host.origin)
        var request = URLRequest(url: try #require(URL(string: base.absoluteString + path)))
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        if token { request.setValue("Bearer \(f.host.token)", forHTTPHeaderField: "Authorization") }
        if origin, method != "GET", method != "HEAD" { request.setValue(base.absoluteString, forHTTPHeaderField: "Origin") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// "/firma/api/fetch?url=<address>" with the address encoded as one query value.
    private func fetchPath(_ address: String, auth: Bool = false) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        return "/firma/api/fetch?url=" + (address.addingPercentEncoding(withAllowedCharacters: allowed) ?? address) + (auth ? "&auth=1" : "")
    }

    private func waiting(_ f: Fixture) -> [InboxEntry] {
        f.center.inbox.visible.filter { if case .approval = $0.kind { true } else { false } }
    }

    // MARK: - Files and the Worker

    @Test func filesAreServedAsBeforeAndTheRestGoesToTheWorker() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }

        let page = try await send(f, "GET", "/firma/index.html")
        #expect(page.status == 200 && page.text.contains("<title>Firma</title>"))
        // A script is still answered as a module, as any artifact's (this test run has no
        // compiler, so only that it is JavaScript, not the Worker's 404).
        let script = try await send(f, "GET", "/firma/helper.ts")
        #expect(script.status == 200)
        #expect(script.response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/javascript") == true)

        let hello = try await send(f, "GET", "/firma/api/hello?x=1")
        #expect(hello.status == 200)
        // The Worker sees the app at the root of the site.
        #expect(try object(hello.text)["path"] as? String == "/api/hello")
        #expect(hello.response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(f.state.apps.status(space: f.space.id, app: "firma").running)

        let unknown = try await send(f, "GET", "/firma/api/nothing")
        #expect(unknown.status == 404 && unknown.text.contains("no route for /api/nothing"))
    }

    @Test func onlyTheServersOwnPagesReachTheWorker() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }

        let posted = try await send(f, "POST", "/firma/api/echo?a=b", body: "tere")
        #expect(posted.status == 200)
        let echo = try object(posted.text)
        #expect(echo["method"] as? String == "POST")
        #expect(echo["body"] as? String == "tere")
        #expect((echo["url"] as? String)?.hasSuffix("/api/echo?a=b") == true)

        #expect(try await send(f, "POST", "/firma/api/echo", body: "x", origin: false).status == 403)
        #expect(try await send(f, "POST", "/firma/api/echo", body: "x", headers: ["Origin": "http://127.0.0.1:1"], origin: false).status == 403)
        #expect(try await send(f, "GET", "/firma/api/hello", headers: ["Sec-Fetch-Site": "cross-site"]).status == 403)
        #expect(try await send(f, "GET", "/firma/api/hello", headers: ["Sec-Fetch-Site": "same-site"]).status == 403)
        #expect(try await send(f, "GET", "/firma/api/hello", headers: ["Sec-Fetch-Site": "same-origin"]).status == 200)
    }

    @Test func withoutTheTokenTheWorkerIsNeverAsked() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let read = try await send(f, "GET", "/firma/api/hello", token: false)
        #expect(read.status == 401 && read.text == "Unauthorized")
        let write = try await send(f, "POST", "/firma/api/notes", body: "x", token: false)
        #expect(write.status == 401 && write.text == "Unauthorized")
        // Nothing was written by the refused request.
        #expect(try await send(f, "GET", "/firma/api/notes").text == "[]")
    }

    @Test func outsideAnAppNothingChanged() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        #expect(try await send(f, "GET", "/plain/index.html").status == 200)
        #expect(try await send(f, "POST", "/plain/index.html", body: "x").status == 405)
        // A folder whose name starts like the app's is not the app.
        let neighbour = try await send(f, "GET", "/firma2/api/hello")
        #expect(neighbour.status == 404 && neighbour.text == "Not Found")
        #expect(try await send(f, "POST", "/firma2/api/echo", body: "x").status == 405)
    }

    @Test func theWorkerNeverSeesTheSpacesToken() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let answer = try await send(f, "GET", "/firma/api/echo",
                                    headers: ["Cookie": "theme=dark; \(ArtifactAuth.cookieName)=\(f.host.token)"])
        #expect(answer.status == 200)
        #expect(!answer.text.contains(f.host.token))
        #expect(!answer.text.lowercased().contains("authorization"))
        #expect(answer.text.contains("theme=dark"))
    }

    @Test func theWorkerCannotReplaceTheAuthCookie() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let answer = try await send(f, "GET", "/firma/api/cookies")
        let cookies = answer.response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        #expect(cookies.contains("session=abc"))
        #expect(!cookies.contains("stolen"))
        // Our own cookie for the token-carrying first request is still set.
        #expect(cookies.contains("\(ArtifactAuth.cookieName)=\(f.host.token)"))
    }

    @Test func aDeletedPageStillSaysItsFileIsMissing() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let gone = try await send(f, "GET", "/firma/gone.html", headers: ["Accept": "text/html"])
        #expect(gone.status == 404)
        #expect(gone.text.contains("file is missing"))
    }

    @Test func errorsComeBackAsText() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let thrown = try await send(f, "GET", "/firma/api/throw")
        #expect(thrown.status == 500 && thrown.text.contains("the worker threw"))
        // The log is a file in the app's data folder.
        let log = Paths(root: f.root).appDataDirectory("work", app: "firma").appending(path: "worker.log")
        try await waitUntil("the error in worker.log") {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("the worker threw")
        }
        #expect(f.state.apps.logLines(space: f.space.id, app: "firma").contains { $0.contains("the worker threw") })
    }

    @Test func aWorkerThatCannotStartSaysWhyOnceAndRecoversWhenFixed() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let worker = f.artifacts.appending(path: "firma/worker.ts")
        let good = try String(contentsOf: worker, encoding: .utf8)
        try "export default { fetch( {".write(to: worker, atomically: true, encoding: .utf8)
        // The watcher may still be on its way with the change; ask until the broken code answers.
        var broken = try await send(f, "GET", "/firma/api/hello")
        for _ in 0..<100 where broken.status != 500 {
            try await Task.sleep(for: .milliseconds(50))
            broken = try await send(f, "GET", "/firma/api/hello")
        }
        #expect(broken.status == 500)
        #expect(broken.text.contains("worker.ts"))
        try await waitUntil("the error in the panel's status") {
            f.state.apps.status(space: f.space.id, app: "firma").lastError?.contains("worker.ts") == true
        }

        try good.write(to: worker, atomically: true, encoding: .utf8)
        var fixed = try await send(f, "GET", "/firma/api/hello")
        for _ in 0..<100 where fixed.status != 200 {
            try await Task.sleep(for: .milliseconds(50))
            fixed = try await send(f, "GET", "/firma/api/hello")
        }
        #expect(fixed.status == 200)
    }

    @Test func editingTheWorkerTakesEffectAtTheNextRequest() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        #expect(try await send(f, "GET", "/firma/api/hello").status == 200)
        try #"export default { fetch() { return new Response("new code") } }"#
            .write(to: f.artifacts.appending(path: "firma/worker.ts"), atomically: true, encoding: .utf8)
        var answer = try await send(f, "GET", "/firma/api/hello")
        for _ in 0..<100 where answer.text != "new code" {
            try await Task.sleep(for: .milliseconds(50))
            answer = try await send(f, "GET", "/firma/api/hello")
            // Never an error in between: a request during the restart waits for the new code.
            #expect(answer.status == 200)
        }
        #expect(answer.text == "new code")
    }

    @Test func anAppThatAppearsGetsItsDatabaseBeforeAnyRequest() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        try FileManager.default.copyItem(at: Self.appFixture, to: f.artifacts.appending(path: "later"))
        let database = Paths(root: f.root).appDataDirectory("work", app: "later").appending(path: "DB.sqlite")
        try await waitUntil("the new app's database", limit: .seconds(10)) {
            FileManager.default.fileExists(atPath: database.path)
        }
        // Its tables are there: the notes route reads an empty list, and rows are kept.
        #expect(try await send(f, "GET", "/later/api/notes").text == "[]")
        #expect(try await send(f, "POST", "/later/api/notes", body: "esimene").status == 200)
        #expect(try await send(f, "GET", "/later/api/notes").text.contains("esimene"))
        #expect(f.state.apps.knownApps(space: f.space.id).map(\.path) == ["firma", "later"])
    }

    /// The starter app that ships in the bundle (`Apps/template`), run as it is: copied into the
    /// Space, its database made from its migration, its three routes answered by the real Worker.
    /// Keeps the template from rotting.
    @Test func theShippedTemplateWorks() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        try FileManager.default.copyItem(at: TestAppState.repositoryRoot.appending(path: "Apps/template"),
                                         to: f.artifacts.appending(path: "notes"))
        var empty = try await send(f, "GET", "/notes/api/notes")
        for _ in 0..<100 where empty.status != 200 {   // the watcher may still be on its way
            try await Task.sleep(for: .milliseconds(50))
            empty = try await send(f, "GET", "/notes/api/notes")
        }
        #expect(empty.status == 200 && empty.text == "[]")

        let added = try await send(f, "POST", "/notes/api/notes", body: #"{"text":"esimene"}"#,
                                   headers: ["Content-Type": "application/json"])
        #expect(added.status == 201)
        let id = try #require(try object(added.text)["id"] as? Int)
        #expect(try await send(f, "GET", "/notes/api/notes").text.contains("esimene"))
        #expect(try await send(f, "DELETE", "/notes/api/notes/\(id)").status == 204)
        #expect(try await send(f, "GET", "/notes/api/notes").text == "[]")

        // The page is a file, answered as a module; its import map names what it imports.
        #expect(try await send(f, "GET", "/notes/app.tsx").status == 200)
        let map = try String(contentsOf: f.artifacts.appending(path: "notes/importmap.json"), encoding: .utf8)
        #expect(map.contains("preact/jsx-runtime"))
        // The template asks for no host and no key by itself.
        #expect(waiting(f).isEmpty)
        #expect(f.state.apps.record(space: f.space.id, app: "notes").isEmpty)
    }

    // MARK: - Outside requests

    @Test func aNewHostAsksOnceAndAllowIsRemembered() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }

        let first = Task { @MainActor in try await send(f, "GET", fetchPath(api.url("/echo"))) }
        try await waitUntil("the approval") { waiting(f).count == 1 }
        let entry = try #require(waiting(f).first)
        guard case .approval(let approval) = entry.kind else { Issue.record("not an approval"); return }
        #expect(approval.actor.contains("firma"))
        #expect(approval.action == "connect to")
        #expect(approval.detail == "127.0.0.1")
        #expect(approval.siteHost == nil)                    // Allow and Deny only
        #expect(entry.spaceID == f.space.id)
        #expect(try await api.seen().isEmpty)                // nothing left the Mac before the answer

        f.center.decideApproval(entry.id, .approved)
        let answer = try await first.value
        #expect(try object(answer.text)["status"] as? Int == 200)
        #expect(f.state.space(f.space.id)?.apps["firma"]?.hosts == ["127.0.0.1"])

        // Allowed now: no question.
        let second = try await send(f, "GET", fetchPath(api.url("/echo")))
        #expect(try object(second.text)["status"] as? Int == 200)
        #expect(waiting(f).isEmpty)
        #expect(try await api.seen().count == 2)
    }

    @Test func aDeniedHostFailsAndStaysQuiet() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }

        let first = Task { @MainActor in try await send(f, "GET", fetchPath(api.url("/echo"))) }
        try await waitUntil("the approval") { waiting(f).count == 1 }
        f.center.decideApproval(try #require(waiting(f).first).id, .denied)
        let answer = try await first.value
        #expect(answer.status == 502)
        #expect((try object(answer.text)["error"] as? String)?.contains("127.0.0.1 is not allowed") == true)
        #expect(f.state.apps.deniedHosts(space: f.space.id, app: "firma") == ["127.0.0.1"])

        // Asked again in the same run: refused without a question.
        #expect(try await send(f, "GET", fetchPath(api.url("/echo"))).status == 502)
        #expect(waiting(f).isEmpty)
        #expect(try await api.seen().isEmpty)
        #expect(f.state.space(f.space.id)?.apps["firma"] == nil)

        // Allowed from the panel: the same run goes through.
        f.state.apps.allowHost("127.0.0.1", space: f.space.id, app: "firma")
        #expect(try object(try await send(f, "GET", fetchPath(api.url("/echo"))).text)["status"] as? Int == 200)
        #expect(f.state.apps.deniedHosts(space: f.space.id, app: "firma").isEmpty)
    }

    @Test func requestsThatArriveTogetherShareOneQuestion() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }

        let requests = (0..<3).map { _ in Task { @MainActor in try await send(f, "GET", fetchPath(api.url("/echo"))) } }
        try await waitUntil("the approval") { waiting(f).count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(waiting(f).count == 1)
        f.center.decideApproval(try #require(waiting(f).first).id, .approved)
        for request in requests {
            #expect(try object(try await request.value.text)["status"] as? Int == 200)
        }
    }

    @Test func aReadOnlySpaceStillAsksAndTheTimeoutDenies() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        f.state.updateSpace(f.space.id, name: "Work", colorHex: "#5E81F4", workingDirectory: "~",
                            agentsEnabled: true, agentPolicy: .readOnly)
        f.state.updateSettings { $0.agentApprovalTimeoutSeconds = 5 }

        let request = Task { @MainActor in try await send(f, "GET", fetchPath(api.url("/echo"))) }
        // The Space's policy is about agents in the browser: an app's new host asks all the same.
        try await waitUntil("the approval") { waiting(f).count == 1 }
        // Nobody answers.
        let answer = try await request.value
        #expect(answer.status == 502)
        #expect(waiting(f).isEmpty)
        #expect(try await api.seen().isEmpty)
        #expect(f.state.apps.deniedHosts(space: f.space.id, app: "firma") == ["127.0.0.1"])
    }

    @Test func aKeyReachesItsHostAndNeverTheWorker() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        try f.state.apps.setKey(name: "API_KEY", host: "127.0.0.1", readable: false, value: "s3cr3t-value",
                                space: f.space.id, app: "firma")
        // Only the name, the host and the switch are in the Space's file; the value is in the store.
        f.state.flushSaves()
        let saved = try String(contentsOf: Paths(root: f.root).spaceFile("work"), encoding: .utf8)
        #expect(saved.contains("API_KEY") && !saved.contains("s3cr3t-value"))
        #expect(f.keys.value(space: f.space.id, app: "firma", name: "API_KEY") == "s3cr3t-value")

        // The Worker's env holds a placeholder.
        let env = try object(try await send(f, "GET", "/firma/api/env").text)
        #expect((env["key"] as? String)?.hasPrefix("sgkey_") == true)

        // The key's host was allowed with the key. The outside server gets the real value; what
        // comes back to the Worker (the server echoes its headers) holds the placeholder again.
        let answer = try await send(f, "GET", fetchPath(api.url("/echo"), auth: true))
        let text = try #require(try object(answer.text)["text"] as? String)
        #expect(text.contains("Bearer sgkey_"))
        #expect(!answer.text.contains("s3cr3t-value"))
        #expect(waiting(f).isEmpty)

        // The log (which agents read) never has it either.
        _ = try await send(f, "GET", "/firma/api/log")
        let log = (try? String(contentsOf: Paths(root: f.root).appDataDirectory("work", app: "firma").appending(path: "worker.log"), encoding: .utf8)) ?? ""
        #expect(!log.contains("s3cr3t-value"))
    }

    @Test func aKeyTheCodeMayReadIsTheRealValue() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        try f.state.apps.setKey(name: "API_KEY", host: "api.example.com", readable: true, value: "sign-with-me",
                                space: f.space.id, app: "firma")
        var env = try object(try await send(f, "GET", "/firma/api/env").text)
        for _ in 0..<100 where env["key"] as? String != "sign-with-me" {   // the Worker restarts with the key
            try await Task.sleep(for: .milliseconds(50))
            env = try object(try await send(f, "GET", "/firma/api/env").text)
        }
        #expect(env["key"] as? String == "sign-with-me")
        // The name the Worker read without a key is listed for the panel.
        try await waitUntil("the unset key's name") {
            f.state.apps.status(space: f.space.id, app: "firma").unsetKeys == ["NOPE"]
        }
    }

    @Test func keyNamesAndHostsAreChecked() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let apps = f.state.apps
        #expect(throws: AppCenter.KeyError.self) {
            try apps.setKey(name: "1BAD", host: "api.example.com", readable: false, value: "long-enough", space: f.space.id, app: "firma")
        }
        #expect(throws: AppCenter.KeyError.self) {
            try apps.setKey(name: "OK", host: "https://api.example.com/", readable: false, value: "long-enough", space: f.space.id, app: "firma")
        }
        // A value so short that it would be found by accident in ordinary answers.
        #expect(throws: AppCenter.KeyError.self) {
            try apps.setKey(name: "OK", host: "api.example.com", readable: false, value: "1234567", space: f.space.id, app: "firma")
        }
        #expect(throws: AppCenter.KeyError.self) {
            try apps.setKey(name: "OK", host: "api.example.com", readable: false, value: nil, space: f.space.id, app: "firma")
        }
        #expect(f.keys.count == 0)
        #expect(apps.record(space: f.space.id, app: "firma").isEmpty)
    }

    @Test func aRedirectToAHostThatIsNotAllowedFailsAndTheKeyStaysHome() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        try f.state.apps.setKey(name: "API_KEY", host: "127.0.0.1", readable: false, value: "s3cr3t-value",
                                space: f.space.id, app: "firma")

        // 127.0.0.1 is allowed; "localhost" is another host, and is not.
        let target = api.url("/echo", host: "localhost")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        let redirect = api.url("/redirect?to=" + target.addingPercentEncoding(withAllowedCharacters: allowed)!)
        let answer = try await send(f, "GET", fetchPath(redirect, auth: true))
        #expect(answer.status == 502)
        #expect((try object(answer.text)["error"] as? String)?.contains("localhost") == true)
        #expect(waiting(f).isEmpty)   // a redirect never asks
        let seen = try await api.seen()
        #expect(seen.count == 1 && seen[0].hasSuffix(" /redirect"))

        // Once localhost is allowed the redirect is followed, but the key belongs to 127.0.0.1:
        // the second hop gets neither the value nor the header it was in.
        f.state.apps.allowHost("localhost", space: f.space.id, app: "firma")
        let followed = try await send(f, "GET", fetchPath(redirect, auth: true))
        let result = try object(followed.text)
        #expect(result["status"] as? Int == 200)
        #expect((result["text"] as? String)?.contains("Authorization") == false)
        #expect(!followed.text.contains("s3cr3t-value"))
    }

    /// A key the code may read is in the Worker's own header as its real value: no placeholder
    /// rule protects it, so a redirect to another host must leave the header behind.
    @Test func aReadableKeyDoesNotFollowARedirectToAnotherHost() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        try f.state.apps.setKey(name: "API_KEY", host: "127.0.0.1", readable: true, value: "sign-with-me",
                                space: f.space.id, app: "firma")
        f.state.apps.allowHost("localhost", space: f.space.id, app: "firma")

        // Straight to the key's host: the header arrives.
        let direct = try object(try await send(f, "GET", fetchPath(api.url("/echo"), auth: true)).text)
        #expect((direct["text"] as? String)?.contains("Bearer sign-with-me") == true)

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        let target = api.url("/echo", host: "localhost")
        let redirect = api.url("/redirect?to=" + target.addingPercentEncoding(withAllowedCharacters: allowed)!)
        let followed = try object(try await send(f, "GET", fetchPath(redirect, auth: true)).text)
        #expect(followed["status"] as? Int == 200)
        let echoed = try #require(followed["text"] as? String)
        #expect(!echoed.contains("sign-with-me"))
        #expect(!echoed.contains("Authorization"))
    }

    /// The server the key belongs to redirects to an address that repeats the key's real value
    /// (a slash added, the same query). The Worker reads `response.url`: it must not find it there.
    @Test func aRedirectThatRepeatsTheKeyDoesNotHandItToTheWorker() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        try f.state.apps.setKey(name: "API_KEY", host: "127.0.0.1", readable: false, value: "s3cr3t-value",
                                space: f.space.id, app: "firma")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        let target = api.url("/echo?key=s3cr3t-value")
        let redirect = api.url("/redirect?to=" + target.addingPercentEncoding(withAllowedCharacters: allowed)!)
        let answer = try await send(f, "GET", fetchPath(redirect))
        let result = try object(answer.text)
        #expect(result["status"] as? Int == 200)
        #expect((result["url"] as? String)?.contains("sgkey_") == true)
        #expect(!answer.text.contains("s3cr3t-value"))
        // The key's own host did get the value back in the followed address.
        #expect(try await api.seen().count == 2)
    }

    /// The inbox shows at most five approvals per Space. A sixth new host is not the owner's
    /// "no": it fails now, but is not denied for the run, and asks when there is room.
    @Test func aHostThatCouldNotBeAskedAboutIsNotDenied() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let requests = (1...5).map { index in
            Task { @MainActor in try await send(f, "GET", fetchPath("https://host\(index).example/")) }
        }
        try await waitUntil("five approvals") { waiting(f).count == 5 }
        let sixth = try await send(f, "GET", fetchPath("https://host6.example/"))
        #expect(sixth.status == 502)
        #expect(waiting(f).count == 5)
        #expect(!f.state.apps.deniedHosts(space: f.space.id, app: "firma").contains("host6.example"))

        for entry in waiting(f) { f.center.decideApproval(entry.id, .denied) }
        for request in requests { #expect(try await request.value.status == 502) }
        #expect(f.state.apps.deniedHosts(space: f.space.id, app: "firma").count == 5)

        // Room again: the sixth host is asked about now.
        let again = Task { @MainActor in try await send(f, "GET", fetchPath("https://host6.example/")) }
        try await waitUntil("the approval for the sixth host") { waiting(f).count == 1 }
        f.center.decideApproval(try #require(waiting(f).first).id, .denied)
        #expect(try await again.value.status == 502)
    }

    /// The owner answers after the Worker that asked was stopped (its file changed): the request
    /// that old code wrote is not sent, though the host is now allowed. The page's request is
    /// answered by the new code, which asks for nothing.
    @Test func anAllowThatComesAfterTheWorkerWentSendsNothing() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        let request = Task { @MainActor in try await send(f, "GET", fetchPath(api.url("/echo"))) }
        try await waitUntil("the approval") { waiting(f).count == 1 }

        try #"export default { fetch() { return new Response("new code") } }"#
            .write(to: f.artifacts.appending(path: "firma/worker.ts"), atomically: true, encoding: .utf8)
        // The request that was inside the old Worker is answered by the new one.
        #expect(try await request.value.text == "new code")

        // The old Worker's question is still in the inbox. Allow: the answer holds…
        f.center.decideApproval(try #require(waiting(f).first).id, .approved)
        try await waitUntil("the host in the record") { f.state.space(f.space.id)?.apps["firma"]?.hosts == ["127.0.0.1"] }
        // …but the request the old code wrote is not sent.
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await api.seen().isEmpty)
    }

    /// A request that is still inside the Worker when its file changes gets an answer, not an error.
    @Test func aRequestInsideTheWorkerDuringARestartIsAnswered() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        #expect(try await send(f, "GET", "/firma/api/hello").status == 200)
        let slow = Task { @MainActor in try await send(f, "GET", "/firma/api/slow?ms=1500") }
        try await Task.sleep(for: .milliseconds(200))
        let worker = f.artifacts.appending(path: "firma/worker.ts")
        try (try String(contentsOf: worker, encoding: .utf8) + "\n// changed\n").write(to: worker, atomically: true, encoding: .utf8)
        let answer = try await slow.value
        #expect(answer.status == 200)
        #expect(answer.text == "slow answer")
    }

    /// Two real apps side by side, one in a subfolder of the other: each has its own database.
    @Test func appsDoNotShareData() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        try FileManager.default.copyItem(at: Self.appFixture, to: f.artifacts.appending(path: "firma/inner"))
        var inner = try await send(f, "GET", "/firma/inner/api/notes")
        for _ in 0..<100 where inner.status != 200 {
            try await Task.sleep(for: .milliseconds(50))
            inner = try await send(f, "GET", "/firma/inner/api/notes")
        }
        #expect(try await send(f, "POST", "/firma/api/notes", body: "outer").status == 200)
        #expect(try await send(f, "POST", "/firma/inner/api/notes", body: "inner").status == 200)
        #expect(try await send(f, "GET", "/firma/api/notes").text.contains("outer"))
        #expect(!(try await send(f, "GET", "/firma/api/notes").text.contains("inner")))
        #expect(!(try await send(f, "GET", "/firma/inner/api/notes").text.contains("outer")))
        // Side by side on disk, never one inside the other.
        let data = Paths(root: f.root).appDataDirectory("work")
        let folders = try FileManager.default.contentsOfDirectory(atPath: data.path).sorted()
        #expect(folders == ["firma", "firma%2Finner"], "got \(folders)")
        #expect(f.state.apps.knownApps(space: f.space.id).map(\.path) == ["firma", "firma/inner"])
    }

    @Test func anAnswerOverTheLimitFails() async throws {
        let api = try ApiFixtureServer.start()
        defer { api.stop() }
        let f = try await makeFixture()
        defer { tearDown(f) }
        f.state.apps.allowHost("127.0.0.1", space: f.space.id, app: "firma")
        let answer = try await send(f, "GET", fetchPath(api.url("/big")))
        #expect(answer.status == 502)
        #expect((try object(answer.text)["error"] as? String)?.contains("8 MB") == true)
    }

    @Test func plainHttpElsewhereIsRefusedWithoutAsking() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let answer = try await send(f, "GET", fetchPath("http://example.com/"))
        #expect(answer.status == 502)
        #expect((try object(answer.text)["error"] as? String)?.contains("https") == true)
        #expect(waiting(f).isEmpty)
    }

    // MARK: - Forgetting

    @Test func forgetAndDeleteDataAndDeletingTheSpace() async throws {
        let f = try await makeFixture()
        defer { tearDown(f) }
        let apps = f.state.apps
        try apps.setKey(name: "API_KEY", host: "api.example.com", readable: false, value: "value-one", space: f.space.id, app: "firma")
        try apps.setKey(name: "OTHER", host: "api.example.com", readable: false, value: "value-two", space: f.space.id, app: "firma2")
        #expect(try await send(f, "POST", "/firma/api/notes", body: "rida").status == 200)
        let data = Paths(root: f.root).appDataDirectory("work", app: "firma")
        #expect(FileManager.default.fileExists(atPath: data.appending(path: "DB.sqlite").path))
        // An app whose folder has no manifest but has keys is still listed (for Settings).
        #expect(apps.knownApps(space: f.space.id) == [
            KnownApp(path: "firma", folderExists: true, hasRecord: true, hasData: true),
            KnownApp(path: "firma2", folderExists: false, hasRecord: true, hasData: false),
        ])

        apps.forget(space: f.space.id, app: "firma")
        #expect(apps.record(space: f.space.id, app: "firma").isEmpty)
        #expect(f.keys.value(space: f.space.id, app: "firma", name: "API_KEY") == nil)
        #expect(f.keys.value(space: f.space.id, app: "firma2", name: "OTHER") == "value-two")
        #expect(FileManager.default.fileExists(atPath: data.path))   // data is a separate choice

        apps.deleteData(space: f.space.id, app: "firma")
        try await waitUntil("the data folder to go") { !FileManager.default.fileExists(atPath: data.path) }

        f.state.deleteSpace(f.space.id)
        #expect(f.keys.count == 0)
    }
}
}
