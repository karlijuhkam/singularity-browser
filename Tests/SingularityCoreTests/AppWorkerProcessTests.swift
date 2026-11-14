import Foundation
import Testing
@testable import SingularityCore

// Paths in the repository, found from this file's location.
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostFolder = repoRoot.appending(path: "Resources/plugin-host")
private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/apps")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

/// A test's temp folder: `<root>/app` (a copy of a fixture app) and `<root>/data`.
private struct Workspace {
    let root: URL, app: URL, data: URL
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func makeWorkspace(_ fixture: String = "basic") throws -> Workspace {
    let root = FileManager.default.temporaryDirectory.appending(path: "sg-app-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let app = root.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: fixtures.appending(path: fixture), to: app)
    return Workspace(root: root, app: app, data: root.appending(path: "data", directoryHint: .isDirectory))
}

private func makeProcess(_ ws: Workspace, keys: [String: String] = [:],
                         limits: AppWorkerProcess.Limits = .init()) -> AppWorkerProcess {
    AppWorkerProcess(appFolder: ws.app, dataFolder: ws.data, runtime: bunPath, hostFolder: hostFolder,
                     keys: keys, limits: limits)
}

private func get(_ path: String) -> AppHTTPRequest {
    AppHTTPRequest(method: "GET", url: "http://127.0.0.1:1234" + path)
}

private func json(_ response: AppHTTPResponse) throws -> Any {
    try JSONSerialization.jsonObject(with: response.body)
}

/// Collects log lines and unset key names from a process.
private final class Recorder: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var _logs: [(level: String, text: String)] = []
    private var _envReads: [String] = []
    private var _exits = 0

    func attach(_ process: AppWorkerProcess) {
        process.onLog = { level, text in self.lock.withLock { self._logs.append((level, text)) } }
        process.onEnvRead = { name in self.lock.withLock { self._envReads.append(name) } }
        process.onExit = { self.lock.withLock { self._exits += 1 } }
    }

    var logs: [(level: String, text: String)] { lock.withLock { _logs } }
    var envReads: [String] { lock.withLock { _envReads } }
    var exits: Int { lock.withLock { _exits } }
}

private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ check: @escaping () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if check() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(what)")
}

// MARK: - The wire (no Bun needed)

@Suite struct AppWireTests {
    @Test func messagesAreOneLineOfJSON() throws {
        let request = AppHTTPRequest(method: "POST", url: "http://x/a?b=1", headers: [("A", "1"), ("A", "2")],
                                     body: Data("line one\nline two".utf8))
        let line = AppWireOut.request(id: 7, request).line()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["t"] as? String == "request")
        #expect(object["id"] as? Int == 7)
        #expect(object["headers"] as? [[String]] == [["A", "1"], ["A", "2"]])
        #expect(Data(base64Encoded: object["body"] as? String ?? "") == request.body)

        let noBody = try #require(try JSONSerialization.jsonObject(with: AppWireOut.request(id: 1, get("/")).line()) as? [String: Any])
        #expect(noBody["body"] is NSNull)

        let refused = try #require(try JSONSerialization.jsonObject(
            with: AppWireOut.fetchResult(id: 3, .failure(AppFetchRefusal("no"))).line()) as? [String: Any])
        #expect(refused["error"] as? String == "no")
        #expect(refused["status"] == nil)
    }

    @Test func readsWhatTheHostSends() {
        func decode(_ text: String) -> AppWireIn? { AppWireIn.decode(Data(text.utf8)) }
        if case .ready = decode(#"{"t":"ready"}"#) {} else { Issue.record("ready") }
        if case .failed(let message) = decode(#"{"t":"failed","message":"worker.ts: oops"}"#) {
            #expect(message == "worker.ts: oops")
        } else { Issue.record("failed") }
        if case let .response(id, response) = decode(#"{"t":"response","id":4,"status":201,"headers":[["Set-Cookie","a=1"],["Set-Cookie","b=2"]],"body":"aGk="}"#) {
            #expect(id == 4)
            #expect(response.status == 201)
            #expect(response.headers.map(\.1) == ["a=1", "b=2"])
            #expect(response.body == Data("hi".utf8))
        } else { Issue.record("response") }
        if case let .fetch(id, request) = decode(#"{"t":"fetch","id":9,"method":"GET","url":"https://x/","headers":[],"body":null}"#) {
            #expect(id == 9)
            #expect(request.body == nil)
        } else { Issue.record("fetch") }
        if case let .log(level, _) = decode(#"{"t":"log","level":"weird","text":"x"}"#) { #expect(level == "info") } else { Issue.record("log") }
        // Not ours: plain output, an unknown kind, a body that is not base64.
        #expect(decode("hello") == nil)
        #expect(decode(#"{"t":"nope"}"#) == nil)
        #expect(decode(#"{"t":"response","id":1,"status":200,"headers":[],"body":"***"}"#) == nil)
    }
}

// MARK: - The log (no Bun needed)

@Suite struct AppLogTests {
    @Test func writesScrubbedEntriesAndCutsTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sg-log-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AppLog(file: folder.appending(path: "data/worker.log"),
                         scrub: { $0.replacingOccurrences(of: "hunter2", with: "[key K]") },
                         now: { Date(timeIntervalSince1970: 0) })
        log.append(level: "error", text: "the key is hunter2\n  at worker.ts:3")
        log.append(level: "strange", text: "plain")
        #expect(log.lastLines(10) == [
            "1970-01-01T00:00:00Z error the key is [key K]",
            "      at worker.ts:3",
            "1970-01-01T00:00:00Z info plain",
        ])

        // Far more than the file may hold: it ends up short, with the newest lines.
        for index in 0..<5000 { log.append(level: "info", text: "line \(index) " + String(repeating: "x", count: 100)) }
        let size = try FileManager.default.attributesOfItem(atPath: log.file.path)[.size] as? Int ?? 0
        #expect(size <= AppLog.maxBytes)
        #expect(log.lastLines(1).first?.contains("line 4999 ") == true)
        // Cut more than once on the way: far fewer than the 5000 lines written are left.
        #expect(log.lastLines(100_000).count < 2500)
    }
}

// MARK: - A real Worker in the real sandbox

@Suite(.enabled(if: hasBun, "needs Vendor/bun/bun (scripts/fetch-bun.sh)"))
struct AppWorkerProcessTests {
    @Test func answersARequestThroughTheSandbox() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        try await process.start()
        #expect(process.isRunning)

        let response = try await process.handle(get("/api/hello"))
        #expect(response.status == 200)
        let body = try #require(try json(response) as? [String: String])
        // A variable from wrangler.jsonc, a file imported next to the Worker, the path as given.
        #expect(body == ["hello": "tere", "helper": "imported", "path": "/api/hello"])
    }

    @Test func theWorkerSeesTheRequestAsGiven() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        try await process.start()

        let request = AppHTTPRequest(method: "POST", url: "http://127.0.0.1:1234/api/echo?x=1",
                                     headers: [("Content-Type", "text/plain"), ("X-Test", "yes")],
                                     body: Data("tere, maailm".utf8))
        let body = try #require(try json(try await process.handle(request)) as? [String: Any])
        #expect(body["method"] as? String == "POST")
        #expect(body["url"] as? String == "http://127.0.0.1:1234/api/echo?x=1")
        #expect(body["body"] as? String == "tere, maailm")
        let headers = try #require(body["headers"] as? [[String]])
        #expect(headers.contains(["x-test", "yes"]))
    }

    @Test func theDatabaseIsMadeFromMigrationsAndKeepsRows() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        try await process.start()
        let added = try await process.handle(AppHTTPRequest(method: "POST", url: "http://x/api/notes", body: Data("esimene".utf8)))
        #expect(try json(added) as? [String: Int] == ["id": 1])
        process.terminateNow()
        #expect(FileManager.default.fileExists(atPath: ws.data.appending(path: "DB.sqlite").path))

        // A second run on the same data folder: the migration is not applied again, the row is there.
        let second = makeProcess(ws)
        defer { second.terminateNow() }
        try await second.start()
        let rows = try #require(try json(try await second.handle(get("/api/notes"))) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["text"] as? String == "esimene")
    }

    @Test func outsideRequestsGoThroughTheOwner() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        let seen = LockedBox<[AppHTTPRequest]>([])
        process.onFetch = { request in
            seen.withValue { $0.append(request) }
            if request.url.contains("refused") { return .failure(AppFetchRefusal("api.refused.example is not allowed")) }
            return .success(AppHTTPResponse(status: 203, headers: [("Content-Type", "text/plain")],
                                            body: Data("from outside".utf8), url: request.url))
        }
        try await process.start()

        let ok = try #require(try json(try await process.handle(get("/api/fetch?url=https://api.example.com/x"))) as? [String: Any])
        #expect(ok["status"] as? Int == 203)
        #expect(ok["text"] as? String == "from outside")
        #expect(seen.value.first?.url == "https://api.example.com/x")
        #expect(seen.value.first?.method == "GET")

        let refused = try await process.handle(get("/api/fetch?url=https://api.refused.example/x"))
        #expect(refused.status == 502)
        #expect((try json(refused) as? [String: String])?["error"]?.contains("api.refused.example is not allowed") == true)
    }

    @Test func theSandboxHasNoNetwork() async throws {
        // A real listener on this Mac: outside the sandbox the connection would succeed.
        let listener = try LoopbackListener()
        defer { listener.close() }
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        try await process.start()
        let response = try await process.handle(get("/api/connect?host=127.0.0.1&port=\(listener.port)"))
        #expect(String(decoding: response.body, as: UTF8.self) == "denied")
    }

    @Test func keysArriveInEnvAndUnknownNamesAreReported() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws, keys: ["API_KEY": "sgkey_placeholder"])
        defer { process.terminateNow() }
        let recorder = Recorder()
        recorder.attach(process)
        try await process.start()
        let body = try #require(try json(try await process.handle(get("/api/env"))) as? [String: Any])
        #expect(body["key"] as? String == "sgkey_placeholder")
        #expect(body["missing"] is NSNull)
        try await waitUntil("the unset key's name") { recorder.envReads == ["NOPE"] }
        // Asked again: reported once.
        _ = try await process.handle(get("/api/env"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.envReads == ["NOPE"])
    }

    @Test func logsAndErrorsReachTheOwner() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        let recorder = Recorder()
        recorder.attach(process)
        try await process.start()

        #expect(String(decoding: try await process.handle(get("/api/log")).body, as: UTF8.self) == "logged")
        try await waitUntil("the log lines") { recorder.logs.count >= 2 }
        #expect(recorder.logs.contains { $0.level == "info" && $0.text.contains("hello from the worker") })
        #expect(recorder.logs.contains { $0.level == "error" && $0.text.contains("an error line") })

        let thrown = try await process.handle(get("/api/throw"))
        #expect(thrown.status == 500)
        #expect(thrown.header("content-type")?.hasPrefix("text/plain") == true)
        #expect(String(decoding: thrown.body, as: UTF8.self).contains("the worker threw"))
        try await waitUntil("the error in the log") { recorder.logs.contains { $0.level == "error" && $0.text.contains("the worker threw") } }
        // The Worker goes on after an error.
        #expect(try await process.handle(get("/api/hello")).status == 200)
    }

    @Test func aWorkerThatNeverAnswersIsKilled() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        var limits = AppWorkerProcess.Limits()
        limits.request = 1
        let process = makeProcess(ws, limits: limits)
        defer { process.terminateNow() }
        let recorder = Recorder()
        recorder.attach(process)
        try await process.start()

        await #expect(throws: AppWorkerError.timedOut) { _ = try await process.handle(get("/api/loop")) }
        try await waitUntil("the process to end") { !process.isRunning && recorder.exits == 1 }
        // Nothing more is answered by this run.
        await #expect(throws: AppWorkerError.exited) { _ = try await process.handle(get("/api/hello")) }
    }

    @Test func aRequestWaitingWhenTheWorkerDiesFails() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        try await process.start()
        let hanging = Task { try await process.handle(get("/api/loop")) }
        try await Task.sleep(for: .milliseconds(300))
        process.terminateNow()
        await #expect(throws: AppWorkerError.exited) { _ = try await hanging.value }
    }

    @Test func bodiesOverTheLimitAreRefusedBothWays() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        var limits = AppWorkerProcess.Limits()
        limits.bodyBytes = 1000
        let process = makeProcess(ws, limits: limits)
        defer { process.terminateNow() }
        try await process.start()
        #expect(try await process.handle(get("/api/big?n=1000")).body.count == 1000)
        await #expect(throws: AppWorkerError.tooLarge) { _ = try await process.handle(get("/api/big?n=1001")) }
        await #expect(throws: AppWorkerError.tooLarge) {
            _ = try await process.handle(AppHTTPRequest(method: "POST", url: "http://x/api/echo", body: Data(count: 1001)))
        }
    }

    @Test func aTwoMegabyteBodyRoundTrips() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        try await process.start()
        let response = try await process.handle(get("/api/big?n=2000000"))
        #expect(response.body.count == 2_000_000)
        #expect(response.body.allSatisfy { $0 == UInt8(ascii: "x") })
    }

    @Test func aWorkerThatDoesNotParseSaysWhichFile() async throws {
        let ws = try makeWorkspace("broken")
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        do {
            try await process.start()
            Issue.record("a broken Worker started")
        } catch let AppWorkerError.failedToStart(message) {
            #expect(message.contains("worker.ts"))
        }
        try await waitUntil("the process to end") { !process.isRunning }
        await #expect(throws: AppWorkerError.exited) { _ = try await process.handle(get("/")) }
    }

    @Test func stopLetsTheWorkerFinishAndExit() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let process = makeProcess(ws)
        let recorder = Recorder()
        recorder.attach(process)
        try await process.start()
        process.stop()
        try await waitUntil("the process to exit after stop") { recorder.exits == 1 }
        #expect(!process.isRunning)
    }

    /// Worker code can write to its process's output directly, past the host script: a forged
    /// answer must not get a header of its choosing (a line break in a value) or a status that
    /// is not one through to the page.
    @Test func aForgedAnswerCannotInjectHeaders() async throws {
        let ws = try makeWorkspace("forged")
        defer { ws.remove() }
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        try await process.start()
        let forged = try await process.handle(get("/headers"))
        #expect(forged.status == 200)
        #expect(forged.headers.map(\.0) == ["X-Ok"])
        let badStatus = try await process.handle(get("/status"))
        #expect(badStatus.status == 502)
    }

    /// The data folder's real path is what the sandbox lets the Worker write: a link there
    /// (to the home folder, say) must not be followed.
    @Test func aDataFolderThatIsALinkIsRefused() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        let elsewhere = ws.root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ws.data, withDestinationURL: elsewhere)
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        await #expect(throws: AppWorkerError.self) { try await process.start() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func theWorkerCannotWriteItsOwnFolder() async throws {
        let ws = try makeWorkspace()
        defer { ws.remove() }
        // A Worker that tries to rewrite its own code and to write outside its data folder.
        try #"""
        import { writeFileSync } from "node:fs";
        export default {
          fetch() {
            const results: string[] = [];
            for (const path of ["./worker.ts", "../outside.txt"]) {
              try { writeFileSync(path, "x"); results.push("wrote " + path); } catch { results.push("denied " + path); }
            }
            return new Response(results.join(","));
          },
        };
        """#.write(to: ws.app.appending(path: "worker.ts"), atomically: true, encoding: .utf8)
        let process = makeProcess(ws)
        defer { process.terminateNow() }
        try await process.start()
        let response = try await process.handle(get("/"))
        #expect(String(decoding: response.body, as: UTF8.self) == "denied ./worker.ts,denied ../outside.txt")
        #expect(!FileManager.default.fileExists(atPath: ws.root.appending(path: "outside.txt").path))
    }
}

/// A value shared between a test and a `@Sendable` closure.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func withValue(_ change: (inout Value) -> Void) { lock.withLock { change(&_value) } }
}

/// A TCP listener on 127.0.0.1 with a port the system picked; it accepts nothing, but a
/// connection attempt to it succeeds at the TCP level while it is open.
private final class LoopbackListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { throw CocoaError(.fileNoSuchFile) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() { Darwin.close(descriptor) }
}
