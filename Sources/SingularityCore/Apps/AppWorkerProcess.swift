import Foundation

/// Why a Worker did not answer.
public enum AppWorkerError: Error, Equatable, Sendable {
    /// The Worker could not start: a syntax error, a failed migration, no `fetch` export…
    /// The text is for the developer (it names the file).
    case failedToStart(String)
    /// No answer in time; the process was killed.
    case timedOut
    /// The process ended while the request waited.
    case exited
    /// A request or response body over the limit.
    case tooLarge
}

/// One app's running Worker: Bun, confined by `sandbox-exec` with the same profile as plugin
/// code, running `Resources/plugin-host/app-host.ts`:
///
///     /usr/bin/sandbox-exec -p <profile> <bun> run <host folder>/app-host.ts
///
/// with the app's folder as working directory (readable), the app's data folder as its only
/// writable place, no network and no other programs. The two sides talk in JSON lines over the
/// process's stdin and stdout (`AppWireOut`, `AppWireIn`).
///
/// A Worker's own `fetch()` arrives here as a message and is handed to `onFetch`: whoever owns
/// this object decides whether the host is allowed, adds keys and makes the request. The
/// sandbox has no network, so there is no way around that.
///
/// One object is one run: after it ended, make a new one.
/// `@unchecked Sendable`: all mutable state is behind `lock`.
public final class AppWorkerProcess: @unchecked Sendable {
    public struct Limits: Sendable {
        /// From spawning Bun to `ready`.
        public var start: TimeInterval = 20
        /// One request, from sending it to its response.
        public var request: TimeInterval = 30
        /// The longest a request may wait in all, however long the Worker's outside requests
        /// (and the owner's answers in the inbox) keep its clock paused.
        public var requestTotal: TimeInterval = 600
        /// A request or response body.
        public var bodyBytes = 8 << 20
        /// After `stop()`, how long the Worker may finish `ctx.waitUntil` work before SIGKILL.
        public var stopGrace: TimeInterval = 35
        public init() {}
    }

    /// One line of the wire: an 8 MB body as base64 plus headers, with room to spare.
    static let maxLineLength = 16 << 20
    /// Bytes that may wait for a Worker that has stopped reading before it is ended.
    static let maxPendingInput = 64 << 20

    public let appFolder: URL
    public let dataFolder: URL
    private let runtime: URL
    private let hostFolder: URL
    private let keys: [String: String]
    private let limits: Limits

    private let lock = NSLock()
    private let input = PluginInput()
    private var process: Process?
    private var started = false
    private var stopRequested = false
    private var ready = false
    private var ended = false
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var startFailure: String?
    private var waiting: [Int: CheckedContinuation<AppHTTPResponse, Error>] = [:]
    private var nextID = 1
    private var lastErrorLines: [String] = []
    /// Outside requests the owner of this object is making for the Worker right now, and when
    /// the last one started or ended. A request's time limit does not run while one is out: the
    /// owner may be answering "may this app connect to …?" in the inbox.
    private var pendingFetches = 0
    private var lastFetchActivity = Date.distantPast

    private var _onFetch: (@Sendable (AppHTTPRequest) async -> Result<AppHTTPResponse, AppFetchRefusal>)?
    private var _onLog: (@Sendable (String, String) -> Void)?
    private var _onEnvRead: (@Sendable (String) -> Void)?
    private var _onExit: (@Sendable () -> Void)?

    /// Makes an outside request for the Worker. Nil: every `fetch()` fails.
    public var onFetch: (@Sendable (AppHTTPRequest) async -> Result<AppHTTPResponse, AppFetchRefusal>)? {
        get { lock.withLock { _onFetch } }
        set { lock.withLock { _onFetch = newValue } }
    }
    /// Called with a level ("info", "error") and a line the Worker logged or printed.
    public var onLog: (@Sendable (_ level: String, _ text: String) -> Void)? {
        get { lock.withLock { _onLog } }
        set { lock.withLock { _onLog = newValue } }
    }
    /// The Worker read `env.NAME` and no key of that name exists.
    public var onEnvRead: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onEnvRead } }
        set { lock.withLock { _onEnvRead = newValue } }
    }
    /// The process is gone (after every waiting request was failed). Called once.
    public var onExit: (@Sendable () -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    /// - Parameters:
    ///   - runtime: the bundled Bun (`Contents/Helpers/bun`).
    ///   - hostFolder: the folder with `app-host.ts` and the empty `bunfig.toml`
    ///     (`Contents/Resources/plugin-host`).
    ///   - keys: what the Worker gets in `env` for the app's keys (`AppKeySubstitution.environment`).
    public init(appFolder: URL, dataFolder: URL, runtime: URL, hostFolder: URL, keys: [String: String],
                limits: Limits = Limits()) {
        self.appFolder = appFolder
        self.dataFolder = dataFolder
        self.runtime = runtime
        self.hostFolder = hostFolder
        self.keys = keys
        self.limits = limits
    }

    /// If the owner lets go of a running Worker, don't leave Bun running on its own.
    deinit {
        terminateNow()
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning == true && !ended }
    }

    /// Running and not told to stop. An outside request the owner allows only now must not be
    /// sent for a Worker that was stopped while the question waited (its code may be old).
    public var isLive: Bool {
        lock.withLock { process?.isRunning == true && !ended && !stopRequested }
    }

    // MARK: - Start

    /// Launches Bun and waits until the Worker says it is ready (config read, migrations applied,
    /// the Worker's file imported). Throws `.failedToStart` with the Worker's own message, or
    /// `.timedOut`. Only the first call does anything.
    public func start() async throws {
        let first: Bool = lock.withLock {
            defer { started = true }
            return !started
        }
        guard first else { return }

        let process: Process
        do {
            process = try launch()
        } catch {
            lock.withLock { ended = true }
            throw AppWorkerError.failedToStart("Bun could not be started: \(error.localizedDescription)")
        }
        // Give up when `ready` doesn't come in time (a Worker that loops at import).
        DispatchQueue.global().asyncAfter(deadline: .now() + limits.start) { [weak self] in
            self?.failStart(with: .timedOut, kill: true)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The Worker may have answered (or died) before we got here: it was started above.
            enum Already { case ready, ended, neither }
            let already: Already = lock.withLock {
                if ready { return .ready }
                if ended { return .ended }
                startWaiter = continuation
                return .neither
            }
            switch already {
            case .ready: continuation.resume()
            case .ended: continuation.resume(throwing: AppWorkerError.failedToStart(startFailureText()))
            case .neither: break
            }
        }
        _ = process   // kept alive by `self.process`
    }

    private func launch() throws -> Process {
        // The data folder must be a real folder. The profile below lets the Worker write whatever
        // the folder's real path is, so a link there (to the home folder, say) would hand it that.
        if let type = try? FileManager.default.attributesOfItem(atPath: dataFolder.path)[.type] as? FileAttributeType,
           type != .typeDirectory {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "the app's data folder is not a folder (\(dataFolder.path))",
            ])
        }
        try FileManager.default.createDirectory(at: dataFolder.appending(path: "tmp"), withIntermediateDirectories: true)
        // The sandbox compares real paths (/var is really /private/var), so every path we hand
        // to the profile or to Bun is resolved with realpath(3) first (as PluginProcess does).
        let runtimePath = try PluginProcess.realPath(runtime)
        let hostPath = try PluginProcess.realPath(hostFolder)
        let appPath = try PluginProcess.realPath(appFolder)
        let dataPath = try PluginProcess.realPath(dataFolder)

        let profile = SandboxProfile.make(
            pluginFolder: URL(filePath: appPath, directoryHint: .isDirectory),
            dataFolder: URL(filePath: dataPath, directoryHint: .isDirectory),
            runtime: URL(filePath: runtimePath),
            extraReadable: [URL(filePath: hostPath, directoryHint: .isDirectory)])

        let process = Process()
        // sandbox-exec applies the profile to itself and then exec()s Bun, so the pid is Bun's.
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        // Same flags as plugin code: our own empty bunfig (the app folder's is not read), no
        // .env files into process.env, never an auto-install.
        process.arguments = ["-p", profile, runtimePath, "--config=" + hostPath + "/bunfig.toml", "--no-env-file",
                             "--no-install", "run", hostPath + "/app-host.ts"]
        process.currentDirectoryURL = URL(filePath: appPath, directoryHint: .isDirectory)
        process.environment = PluginProcess.environment(dataFolder: dataPath)

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Writing to a pipe whose reader has died would kill the writer (the app) with SIGPIPE;
        // with this flag the write just fails instead.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // The exit is reported after the process has ended AND both output pipes reached
        // end-of-file, so the Worker's last lines (its `failed` message) arrive first.
        let finished = DispatchGroup()
        for _ in 0..<3 { finished.enter() }
        process.terminationHandler = { [weak self] _ in
            finished.leave()
            // Fallback: if something kept a pipe open, report the exit anyway after 2 s.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self?.processEnded() }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            for _ in 0..<3 { finished.leave() }
            throw error
        }
        input.attach(stdinPipe.fileHandleForWriting)
        lock.withLock { self.process = process }
        read(stdoutPipe.fileHandleForReading, done: finished) { [weak self] piece in self?.handleStdout(piece) }
        read(stderrPipe.fileHandleForReading, done: finished) { [weak self] piece in self?.handleStderr(piece) }
        finished.notify(queue: .global()) { [weak self] in self?.processEnded() }

        send(.start(keys: keys, dataFolder: dataPath, appFolder: appPath))
        return process
    }

    // MARK: - Requests

    /// Hands a request to the Worker and waits for its response. Throws `.timedOut` (and kills
    /// the process: a Worker that hangs once would hang every later request too), `.exited`,
    /// or `.tooLarge`.
    public func handle(_ request: AppHTTPRequest) async throws -> AppHTTPResponse {
        guard (request.body?.count ?? 0) <= limits.bodyBytes else { throw AppWorkerError.tooLarge }
        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppHTTPResponse, Error>) in
            let gone: Bool = lock.withLock {
                if ended || process == nil { return true }
                waiting[id] = continuation
                return false
            }
            if gone {
                continuation.resume(throwing: AppWorkerError.exited)
                return
            }
            send(.request(id: id, request))
            armTimeout(for: id, after: limits.request, started: Date())
        }
    }

    /// Fails request `id` when its time is up, and kills the process. Time spent on the Worker's
    /// own outside requests doesn't count (see `pendingFetches`): then the check comes back later.
    private func armTimeout(for id: Int, after delay: TimeInterval, started: Date) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            enum Verdict { case answered, wait(TimeInterval), late(CheckedContinuation<AppHTTPResponse, Error>) }
            let verdict: Verdict = self.lock.withLock {
                guard self.waiting[id] != nil else { return .answered }
                // The pause is the whole Worker's, not this request's (the wire doesn't say which
                // request a fetch belongs to), so it has an end: `requestTotal`.
                if Date().timeIntervalSince(started) < self.limits.requestTotal {
                    if self.pendingFetches > 0 { return .wait(1) }
                    let quietFor = Date().timeIntervalSince(self.lastFetchActivity)
                    if quietFor < self.limits.request { return .wait(self.limits.request - quietFor) }
                }
                return .late(self.waiting.removeValue(forKey: id)!)
            }
            switch verdict {
            case .answered:
                return
            case .wait(let more):
                self.armTimeout(for: id, after: max(0.05, more), started: started)
            case .late(let waiter):
                waiter.resume(throwing: AppWorkerError.timedOut)
                self.log("error", "A request got no answer in \(Int(self.limits.request)) seconds; the Worker was stopped.")
                self.terminateNow()
            }
        }
    }

    // MARK: - Stop

    /// Asks the Worker to finish (`ctx.waitUntil` work may complete) and exit; SIGKILL after the
    /// grace time. Requests still waiting fail with `.exited` when it goes.
    public func stop() {
        lock.withLock { stopRequested = true }
        guard let process = lock.withLock({ self.process }), process.isRunning else { return }
        send(.stop)
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + limits.stopGrace) {
            // `isRunning` on the same Process object: true only while our child has not been
            // reaped, so the pid can't belong to some other program yet.
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Kills the process at once (SIGKILL). For app termination, a hung Worker, or a restart
    /// that must not wait. Safe to call any time, more than once.
    public func terminateNow() {
        let process: Process? = lock.withLock {
            stopRequested = true
            return self.process
        }
        input.close()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: - Sending and receiving

    private func send(_ message: AppWireOut) {
        guard !input.enqueue(message.line(), limit: Self.maxPendingInput) else { return }
        // The Worker has stopped reading its input: end it rather than buffer without limit.
        log("error", "The Worker is not reading its input; it was stopped.")
        terminateNow()
    }

    /// Reads a pipe as lines until end-of-file, then leaves `done`. `readabilityHandler` is
    /// called on a background queue whenever bytes arrive (an empty chunk means end-of-file).
    private func read(_ handle: FileHandle, done: DispatchGroup, _ deliver: @escaping @Sendable (LineSplitter.Piece) -> Void) {
        let splitter = LockedSplitter(maxLength: Self.maxLineLength)
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                splitter.finish().forEach(deliver)
                done.leave()
            } else {
                splitter.append(chunk).forEach(deliver)
            }
        }
    }

    private func handleStdout(_ piece: LineSplitter.Piece) {
        guard case .line(let data) = piece else {
            log("error", "Dropped a message longer than 16 MB.")
            return
        }
        guard !data.isEmpty else { return }
        guard let message = AppWireIn.decode(data) else {
            // Not a protocol line (something printed to stdout directly): keep it as a log line.
            log("info", String(decoding: data.prefix(4000), as: UTF8.self))
            return
        }
        switch message {
        case .ready:
            lock.withLock { () -> CheckedContinuation<Void, Error>? in
                ready = true
                defer { startWaiter = nil }
                return startWaiter
            }?.resume()
        case .failed(let text):
            lock.withLock { startFailure = text }
            log("error", text)
        case let .response(id, response):
            guard let waiter = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
            if response.body.count > limits.bodyBytes {
                waiter.resume(throwing: AppWorkerError.tooLarge)
            } else {
                // The line came from the Worker's process, whose code can write anything to its
                // output: only well-formed headers and a real status go on to the page.
                var response = response
                response.headers = ArtifactApps.headersFromWorker(response.headers)
                if !ArtifactApps.isResponseStatus(response.status) {
                    response = .text(502, "The Worker answered with a status that is not one (\(response.status)).")
                }
                waiter.resume(returning: response)
            }
        case let .fetch(id, request):
            let handler = onFetch
            lock.withLock {
                pendingFetches += 1
                lastFetchActivity = Date()
            }
            Task { [weak self] in
                let result: Result<AppHTTPResponse, AppFetchRefusal>
                if let handler {
                    result = await handler(request)
                } else {
                    result = .failure(AppFetchRefusal("This Worker has no network."))
                }
                guard let self else { return }
                self.lock.withLock {
                    self.pendingFetches -= 1
                    self.lastFetchActivity = Date()
                }
                self.send(.fetchResult(id: id, result))
            }
        case let .log(level, text):
            log(level, text)
        case .envRead(let name):
            onEnvRead?(name)
        }
    }

    private func handleStderr(_ piece: LineSplitter.Piece) {
        guard case .line(let data) = piece, !data.isEmpty else { return }
        let text = String(decoding: data.prefix(4000), as: UTF8.self)
        // Kept in case the process dies before it could say `failed` (Bun's own crash message).
        lock.withLock {
            lastErrorLines.append(text)
            if lastErrorLines.count > 20 { lastErrorLines.removeFirst() }
        }
        log("error", text)
    }

    private func log(_ level: String, _ text: String) {
        onLog?(level, text)
    }

    // MARK: - Ending

    /// The process is gone: everyone waiting gets an error. Runs once.
    private func processEnded() {
        let (startWaiter, waiters, callback): (CheckedContinuation<Void, Error>?, [CheckedContinuation<AppHTTPResponse, Error>], (@Sendable () -> Void)?) = lock.withLock {
            guard !ended else { return (nil, [], nil) }
            ended = true
            defer {
                self.startWaiter = nil
                waiting = [:]
            }
            return (self.startWaiter, Array(waiting.values), _onExit)
        }
        input.close()
        startWaiter?.resume(throwing: AppWorkerError.failedToStart(startFailureText()))
        for waiter in waiters { waiter.resume(throwing: AppWorkerError.exited) }
        callback?()
    }

    /// `start()` is still waiting: fail it (the start timeout).
    private func failStart(with error: AppWorkerError, kill: Bool) {
        let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { startWaiter = nil }
            return startWaiter
        }
        guard let waiter else { return }
        waiter.resume(throwing: error)
        if kill { terminateNow() }
    }

    /// The Worker's own `failed` message, else the last lines Bun wrote before it died.
    private func startFailureText() -> String {
        lock.withLock {
            if let startFailure { return startFailure }
            if !lastErrorLines.isEmpty { return lastErrorLines.joined(separator: "\n") }
            return "The Worker ended before it was ready."
        }
    }
}
