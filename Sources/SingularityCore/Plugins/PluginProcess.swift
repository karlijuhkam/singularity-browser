import Foundation

/// One running plugin background program: Bun, confined by `sandbox-exec` with the profile from
/// `SandboxProfile`, started through `Resources/plugin-host/host.ts`.
///
/// The command line is
///     /usr/bin/sandbox-exec -p <profile> <bun> run <host.ts> <plugin folder>/<background>
/// with the plugin folder as working directory and a minimal environment (see `environment`).
/// The app and the plugin exchange `PluginWire` messages as JSON lines: the app writes to the
/// plugin's stdin and reads its stdout. stderr lines become `.log("error", …)`.
///
/// `.runCommand` messages are handled here: `CommandPolicy` decides, `CommandBroker` runs the
/// program at the path pinned at approval time (`commandPaths`), and the result goes back as
/// `.commandResult`. Paths are never looked up again at call time.
///
/// Callbacks run on background threads, one at a time per stream but not on the main thread.
/// A `PluginProcess` runs once; to restart, make a new one (`PluginSupervisor` does that).
///
/// `@unchecked Sendable`: the mutable state (callbacks, the Process, flags) is only touched while
/// holding `lock`, and stdin writes go through the serial `writeQueue`, so it is safe to use from
/// any thread even though the compiler can't prove it.
public final class PluginProcess: @unchecked Sendable {
    /// Longest stdout line accepted from a plugin (1 MB); longer ones are dropped with a log entry.
    static let maxLineLength = 1_000_000
    /// How long a command may run before it is stopped.
    static let commandTimeout: Duration = .seconds(60)

    public let manifest: PluginManifest
    private let folder: URL
    private let dataFolder: URL
    private let runtime: URL
    private let host: URL
    private let commandPaths: [String: String]

    private let lock = NSLock()
    private var _onReply: (@Sendable (Int, JSONValue) -> Void)?
    private var _onLog: (@Sendable (String, String) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?
    private var process: Process?
    private var started = false
    private var stopping = false
    private var exitReported = false

    /// Writes to the plugin's stdin happen here, in order, so `send` never blocks its caller
    /// (a plugin that stops reading would otherwise freeze the app once the 64 KB pipe is full).
    private let writeQueue = DispatchQueue(label: "dev.roosa.singularity.plugin-stdin")
    private var stdinHandle: FileHandle?   // only touched on writeQueue

    /// Called with (requestID, payload) when the plugin answers a page message.
    public var onReply: (@Sendable (Int, JSONValue) -> Void)? {
        get { lock.withLock { _onReply } }
        set { lock.withLock { _onReply = newValue } }
    }
    /// Called with (level, message) for the plugin's log lines (console output, stderr, problems).
    public var onLog: (@Sendable (String, String) -> Void)? {
        get { lock.withLock { _onLog } }
        set { lock.withLock { _onLog = newValue } }
    }
    /// Called once, with the exit status, when the process has ended (for whatever reason).
    public var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    public init(manifest: PluginManifest, folder: URL, dataFolder: URL, runtime: URL, host: URL,
                commandPaths: [String: String]) {
        self.manifest = manifest
        self.folder = folder
        self.dataFolder = dataFolder
        self.runtime = runtime
        self.host = host
        self.commandPaths = commandPaths
    }

    /// If the owner lets go of a running plugin, don't leave Bun running on its own.
    deinit {
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: - Start and stop

    /// Launches the process. Throws `PluginError.missingFile` when the manifest has no background
    /// program (or a path can't be found), or the error from launching. Only the first call does
    /// anything (also when it failed): make a new `PluginProcess` to try again.
    public func start() throws {
        let first: Bool = lock.withLock {
            defer { started = true }
            return !started && !stopping
        }
        guard first else { return }
        guard let background = manifest.background else { throw PluginError.missingFile("background") }
        try FileManager.default.createDirectory(at: dataFolder.appending(path: "tmp"),
                                                withIntermediateDirectories: true)
        // The sandbox compares real paths (/var is really /private/var), so every path we hand to
        // the profile or to Bun is resolved with realpath(3) first.
        let runtimePath = try Self.realPath(runtime)
        let hostPath = try Self.realPath(host)
        let folderPath = try Self.realPath(folder)
        let backgroundPath = try Self.realPath(folder.appending(path: background))
        let dataPath = try Self.realPath(dataFolder)

        let profile = SandboxProfile.make(
            pluginFolder: URL(filePath: folderPath, directoryHint: .isDirectory),
            dataFolder: URL(filePath: dataPath, directoryHint: .isDirectory),
            runtime: URL(filePath: runtimePath),
            // host.ts lives in the app bundle; Bun must be able to read it (read-only).
            extraReadable: [URL(filePath: (hostPath as NSString).deletingLastPathComponent, directoryHint: .isDirectory)])

        let process = Process()
        // sandbox-exec applies the profile to itself and then exec()s Bun, so the pid we get is
        // Bun's and signals reach it directly.
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, runtimePath, "run", hostPath, backgroundPath]
        process.currentDirectoryURL = URL(filePath: folderPath, directoryHint: .isDirectory)
        process.environment = Self.environment(dataFolder: dataPath)

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Writing to a pipe whose reader has died normally kills the writer (the app!) with
        // SIGPIPE. With this flag the write just fails with EPIPE instead.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // onExit fires after the process has ended AND both output pipes reached end-of-file, so
        // the last lines a plugin printed are delivered before the exit. Three enters, three leaves
        // (a DispatchGroup must be balanced before it is freed, hence the leaves on failure below).
        let finished = DispatchGroup()
        for _ in 0..<3 { finished.enter() }
        // Set before run(): a handler set after the process has already ended might never be called.
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            finished.leave()
            guard let self else { return }
            // Fallback: if something kept a pipe open, report the exit anyway after 2 s.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.reportExit(status) }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            for _ in 0..<3 { finished.leave() }
            throw error
        }
        writeQueue.async { self.stdinHandle = stdinPipe.fileHandleForWriting }
        // stop() may have been called while we were starting; it couldn't see the process then.
        let stoppedMeanwhile = lock.withLock {
            self.process = process
            return stopping
        }
        if stoppedMeanwhile { end(process) }
        // Bytes written before these handlers are set wait in the pipe; nothing is lost.
        read(stdoutPipe.fileHandleForReading, done: finished) { [weak self] piece in self?.handleStdout(piece) }
        read(stderrPipe.fileHandleForReading, done: finished) { [weak self] piece in self?.handleStderr(piece) }
        finished.notify(queue: .global()) { [weak self] in self?.reportExit(process.terminationStatus) }
    }

    /// Ends the process: closes its stdin (host.ts exits on end-of-input), sends SIGTERM, and
    /// SIGKILL 2 s later if it is still running. `onExit` still fires. Safe to call more than once.
    public func stop() {
        let process: Process? = lock.withLock {
            guard !stopping else { return nil }
            stopping = true
            return self.process
        }
        if let process { end(process) }
    }

    /// Closes stdin, SIGTERM, and SIGKILL 2 s later if needed.
    private func end(_ process: Process) {
        writeQueue.async { try? self.stdinHandle?.close(); self.stdinHandle = nil }
        guard process.isRunning else { return }
        process.terminate()   // SIGTERM
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // isRunning on the same Process object: true only while our child has not been reaped,
            // so the pid can't belong to some other program yet.
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Sending

    /// Queues a message for the plugin's stdin. Dropped silently before `start()` and once the
    /// process is gone.
    public func send(_ message: PluginWire) {
        guard var encoded = try? JSONEncoder().encode(message) else { return }
        encoded.append(0x0A)   // JSONEncoder never emits a raw newline, so one message = one line
        let line = encoded
        writeQueue.async {
            guard let handle = self.stdinHandle else { return }
            do { try handle.write(contentsOf: line) } catch {
                // EPIPE: the plugin has exited. Stop writing; onExit reports the rest.
                try? handle.close()
                self.stdinHandle = nil
            }
        }
    }

    // MARK: - Receiving

    /// Reads a pipe as lines until end-of-file, then leaves `done`.
    /// `readabilityHandler` is called on a background queue whenever bytes arrive (an empty chunk
    /// means end-of-file).
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
            log("error", "dropped a message longer than 1 MB")
            return
        }
        guard !data.isEmpty else { return }
        guard let message = try? JSONDecoder().decode(PluginWire.self, from: data) else {
            // Not a protocol line (something printed to stdout directly): keep it as a log line.
            log("info", String(decoding: data, as: UTF8.self))
            return
        }
        switch message {
        case let .reply(requestID, payload):
            lock.withLock { _onReply }?(requestID, payload)
        case let .log(level, text):
            log(level, text)
        case let .runCommand(callID, command, arguments):
            runCommand(callID: callID, command: command, arguments: arguments)
        case .pageMessage, .commandResult:
            log("error", "ignored a message the app sends, not the plugin: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    private func handleStderr(_ piece: LineSplitter.Piece) {
        switch piece {
        case .line(let data) where !data.isEmpty: log("error", String(decoding: data, as: UTF8.self))
        case .line: break
        case .tooLong: log("error", "dropped a stderr line longer than 1 MB")
        }
    }

    private func log(_ level: String, _ message: String) {
        lock.withLock { _onLog }?(level, message)
    }

    /// Runs a command the manifest declares, at its pinned path; anything else gets status 126.
    /// Several commands may run at the same time; each answers with its own callID.
    private func runCommand(callID: Int, command: String, arguments: [String]) {
        let allowed = CommandPolicy.allows(command: command, arguments: arguments,
                                           declared: manifest.permissions.commands)
        let path = allowed ? commandPaths[command] : nil
        Task.detached { [weak self] in
            let result: CommandResult
            if let path {
                result = await CommandBroker.run(path: path, arguments: arguments, timeout: Self.commandTimeout)
            } else {
                result = CommandResult(status: 126, stdout: "", stderr: "not allowed by the manifest", timedOut: false)
            }
            self?.send(.commandResult(callID: callID, result: result))
        }
    }

    private func reportExit(_ status: Int32) {
        let callback: (@Sendable (Int32) -> Void)? = lock.withLock {
            guard !exitReported else { return nil }
            exitReported = true
            return _onExit
        }
        writeQueue.async { try? self.stdinHandle?.close(); self.stdinHandle = nil }
        callback?(status)
    }

    // MARK: - Helpers

    /// Exactly what Bun gets; nothing is inherited from the app (whose environment may hold tokens,
    /// SSH_AUTH_SOCK and the like). No PATH: the sandbox forbids starting programs anyway.
    static func environment(dataFolder: String) -> [String: String] {
        [
            "HOME": dataFolder,
            "TMPDIR": dataFolder + "/tmp",
            "LANG": "en_US.UTF-8",
            "NO_COLOR": "1",
            // Bun caches transpiled files over 50 KB under $HOME/Library/Caches/bun; "0" turns that
            // off so the data folder only holds what the plugin itself writes.
            "BUN_RUNTIME_TRANSPILER_CACHE_PATH": "0",
        ]
    }

    /// realpath(3): absolute, symlinks resolved, /var -> /private/var. (URL.resolvingSymlinksInPath
    /// does the opposite for /private/var, which the sandbox would not match.)
    static func realPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { throw PluginError.missingFile(url.path) }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// A `LineSplitter` that may be fed from a background thread.
/// `@unchecked Sendable`: the splitter is only touched while holding `lock`.
private final class LockedSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter: LineSplitter
    init(maxLength: Int) { splitter = LineSplitter(maxLength: maxLength) }
    func append(_ chunk: Data) -> [LineSplitter.Piece] { lock.withLock { splitter.append(chunk) } }
    func finish() -> [LineSplitter.Piece] { lock.withLock { splitter.finish() } }
}

// MARK: - Supervisor

/// Keeps one plugin's background process running: after an unexpected exit it starts a new one,
/// at most 3 times within any 60 seconds. The 4th crash inside that window gives up
/// (`.crashedRepeatedly`), so a broken plugin can't spin in a restart loop. `stop()` is never
/// followed by a restart. Keeps the last 50 log lines for Settings.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; callbacks are called outside it.
public final class PluginSupervisor: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case running
        /// Crashed more than `maxRestarts` times within `window`; not restarted again until `start()`.
        case crashedRepeatedly
        /// The process could not be launched at all.
        case failedToStart(String)
    }

    public struct LogLine: Equatable, Sendable {
        public let date: Date
        public let level: String
        public let message: String
    }

    public static let maxRestarts = 3
    public static let window: TimeInterval = 60
    public static let keptLogLines = 50

    private let makeProcess: @Sendable () -> PluginProcess
    private let now: @Sendable () -> Date
    private let restartDelay: Duration

    private let lock = NSLock()
    private var _state: State = .stopped
    private var wanted = false   // between start() and stop()
    private var current: PluginProcess?
    /// Bumped on every launch and on stop, so a late exit from an old process is ignored.
    private var generation = 0
    private var crashTimes: [Date] = []
    private var logs: [LogLine] = []
    private var _onReply: (@Sendable (Int, JSONValue) -> Void)?
    private var _onLog: (@Sendable (String, String) -> Void)?
    private var _onStateChange: (@Sendable (State) -> Void)?

    /// - Parameters:
    ///   - restartDelay: pause before a restart.
    ///   - now: the clock used for the 60 s window (tests pass a fake one).
    ///   - makeProcess: builds a fresh, not yet started process (a `Process` can only run once).
    public init(restartDelay: Duration = .seconds(1), now: @escaping @Sendable () -> Date = { Date() },
                makeProcess: @escaping @Sendable () -> PluginProcess) {
        self.restartDelay = restartDelay
        self.now = now
        self.makeProcess = makeProcess
    }

    public var state: State { lock.withLock { _state } }
    /// The last 50 log lines, oldest first, including exits and restarts.
    public var recentLogs: [LogLine] { lock.withLock { logs } }

    public var onReply: (@Sendable (Int, JSONValue) -> Void)? {
        get { lock.withLock { _onReply } }
        set { lock.withLock { _onReply = newValue } }
    }
    public var onLog: (@Sendable (String, String) -> Void)? {
        get { lock.withLock { _onLog } }
        set { lock.withLock { _onLog = newValue } }
    }
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    /// Starts the plugin (also after `.crashedRepeatedly`: the crash count starts over).
    /// Does nothing while a process is running.
    public func start() {
        let ready: Bool = lock.withLock {
            guard current == nil else { return false }
            wanted = true
            crashTimes = []
            return true
        }
        if ready { launch(ifGeneration: nil) }
    }

    /// Stops the plugin for good; it is not restarted.
    public func stop() {
        let process: PluginProcess? = lock.withLock {
            wanted = false
            generation += 1   // the coming exit belongs to an old generation: no restart
            defer { current = nil }
            return current
        }
        process?.stop()
        setState(.stopped)
    }

    /// Passes a message to the running process; dropped when none is running.
    public func send(_ message: PluginWire) {
        lock.withLock { current }?.send(message)
    }

    /// Makes and starts a new process. `ifGeneration`: only if nothing changed since that
    /// generation (a restart that a `stop()` or `start()` overtook is dropped).
    private func launch(ifGeneration expected: Int?) {
        func allowed() -> Bool { wanted && (expected == nil || expected == self.generation) }
        guard lock.withLock(allowed) else { return }
        if expected != nil { record("info", "restarting") }
        let process = makeProcess()
        // Reserve a generation now; `current` is set only once the process has started, so
        // send() never hands a message to a process that can't take it yet.
        let generation: Int? = lock.withLock {
            guard allowed() else { return nil }
            self.generation += 1
            return self.generation
        }
        guard let generation else { return }
        process.onReply = { [weak self] id, payload in self?.onReply?(id, payload) }
        process.onLog = { [weak self] level, message in self?.record(level, message) }
        process.onExit = { [weak self] status in self?.processExited(status: status, generation: generation) }
        do {
            try process.start()
        } catch {
            record("error", "could not start: \(error)")
            setState(.failedToStart(String(describing: error)), ifGeneration: generation)
            return
        }
        // A stop() (or an exit) while it was starting changed the generation: don't keep it.
        let keep = lock.withLock {
            if self.generation == generation { current = process }
            return self.generation == generation
        }
        if keep { setState(.running, ifGeneration: generation) } else { process.stop() }
    }

    private func processExited(status: Int32, generation: Int) {
        // (restart?, the generation after this exit) or nil when the exit is expected or stale.
        let decision: (restart: Bool, generation: Int)? = lock.withLock {
            guard generation == self.generation else { return nil }   // stopped on purpose, or stale
            current = nil
            self.generation += 1   // so a late setState(.running) of the dead process is ignored
            let time = now()
            crashTimes = crashTimes.filter { time.timeIntervalSince($0) < Self.window } + [time]
            return (crashTimes.count <= Self.maxRestarts, self.generation)
        }
        guard let decision else { return }
        record("error", "exited with status \(status)")
        guard decision.restart else {
            record("error", "crashed \(Self.maxRestarts + 1) times within \(Int(Self.window)) s; not restarting")
            setState(.crashedRepeatedly, ifGeneration: decision.generation)
            return
        }
        let delay = restartDelay
        Task.detached { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            // A stop() or start() during the delay changes the generation, and launch then does nothing.
            self?.launch(ifGeneration: decision.generation)
        }
    }

    private func record(_ level: String, _ message: String) {
        let callback: (@Sendable (String, String) -> Void)? = lock.withLock {
            logs.append(LogLine(date: now(), level: level, message: message))
            if logs.count > Self.keptLogLines { logs.removeFirst(logs.count - Self.keptLogLines) }
            return _onLog
        }
        callback?(level, message)
    }

    private func setState(_ state: State, ifGeneration expected: Int? = nil) {
        let callback: (@Sendable (State) -> Void)? = lock.withLock {
            if let expected, expected != generation { return nil }
            guard _state != state else { return nil }
            _state = state
            return _onStateChange
        }
        callback?(state)
    }
}
