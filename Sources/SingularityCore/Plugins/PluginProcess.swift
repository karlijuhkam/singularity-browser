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
/// So are the messages of a running program (`.startProgram` and the rest; host.ts's
/// `singularity.spawn`): one program from `permissions.programs` at a time, at its pinned path,
/// outside the sandbox, with the environment `programEnvironment` builds, in the data folder (see
/// `RunningProgram`). It ends with the plugin: on `stop()`, `terminateNow()` and the plugin's exit.
///
/// Callbacks run on background threads, one at a time per stream but not on the main thread.
/// A `PluginProcess` runs once; to restart, make a new one (`PluginSupervisor` does that).
///
/// Limits that keep a misbehaving plugin from wedging the app: at most 16 MB of input waiting to
/// be written (a plugin that stops reading is stopped), at most 4 commands running at once, stdout
/// lines up to 1 MB, log messages up to 8 KB.
///
/// `@unchecked Sendable`: the mutable state (callbacks, the Process, flags, counters) is only
/// touched while holding `lock`, and stdin has its own thread-safe `PluginInput`, so it is safe to
/// use from any thread even though the compiler can't prove it.
public final class PluginProcess: @unchecked Sendable {
    /// Longest stdout line accepted from a plugin (1 MB); longer ones are dropped with a log entry.
    static let maxLineLength = 1_000_000
    /// How long a command may run before it is stopped.
    static let commandTimeout: Duration = .seconds(60)
    /// Most bytes of messages waiting for the plugin to read them (16 MB).
    static let maxPendingInput = 16 << 20
    /// Most commands one plugin may have running at the same time.
    static let maxConcurrentCommands = 4
    /// Longest log message kept (8 KB); longer ones are cut.
    static let maxLogMessageBytes = 8192
    /// Most bytes of a program's output sent to the plugin and not yet reported read (1 MB); above
    /// this the app stops reading the program until the plugin catches up.
    static let maxProgramUnread = 1 << 20
    /// Most bytes of program output in one `.programOutput` message (48 KB).
    static let maxProgramOutputChunk = 48 * 1024
    /// A program's stderr lines go to the plugin's log, cut to this many characters.
    static let maxProgramLogLine = 2000

    public let manifest: PluginManifest
    private let folder: URL
    private let dataFolder: URL
    private let runtime: URL
    private let host: URL
    private let commandPaths: [String: String]
    private let programsAllowed: Bool
    private let programEnvironment: @Sendable (_ requested: [String: String]) -> [String: String]

    private let lock = NSLock()
    private var _onReply: (@Sendable (Int, JSONValue) -> Void)?
    private var _onLog: (@Sendable (String, String) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?
    private var _onPanelPost: (@Sendable (JSONValue) -> Void)?
    private var _onFrontRequest: (@Sendable (Int) -> Void)?
    private var _onBrowserServerRequest: (@Sendable (Int) -> Void)?
    private var _onProgramExit: (@Sendable () -> Void)?
    /// The plugin's one program: reserved (`running` nil) while it starts, cleared when its exit
    /// has been sent.
    private var program: (id: Int, name: String, running: RunningProgram?)?
    private var _programUnreadPeak = 0
    private var process: Process?
    private var started = false
    private var stopping = false
    /// `terminateNow()` was called (the app is quitting): a program still starting is killed at once.
    private var terminating = false
    private var exitReported = false
    private var inputOverflowed = false
    private var runningCommands = 0
    /// Commands started for this plugin that are still running (killed by `terminateNow`).
    let commandChildren = RunningChildren()

    /// The plugin's stdin (writes happen on a queue of their own, so `send` never blocks).
    private let input = PluginInput()

    /// Bytes sent but not yet written to the plugin (for tests and diagnostics).
    var pendingInputBytes: Int { input.pendingBytes }

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
    /// Called with what the plugin sends its own page (`singularity.panel.post`).
    public var onPanelPost: (@Sendable (JSONValue) -> Void)? {
        get { lock.withLock { _onPanelPost } }
        set { lock.withLock { _onPanelPost = newValue } }
    }

    /// Called with the request id when the plugin asks for the tab in front; answer with `.reply`.
    public var onFrontRequest: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onFrontRequest } }
        set { lock.withLock { _onFrontRequest = newValue } }
    }
    /// Called with the request id when the plugin asks how to start the browser server.
    public var onBrowserServerRequest: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onBrowserServerRequest } }
        set { lock.withLock { _onBrowserServerRequest = newValue } }
    }
    /// The plugin's program ended (after `programPID` became nil). The agent door then closes the
    /// connections that came from it.
    public var onProgramExit: (@Sendable () -> Void)? {
        get { lock.withLock { _onProgramExit } }
        set { lock.withLock { _onProgramExit = newValue } }
    }

    /// The most program output that was ever sent and not yet reported read (for tests).
    var programUnreadPeak: Int { lock.withLock { _programUnreadPeak } }

    /// The pid of the plugin's running program (`singularity.spawn`); nil when none runs (not
    /// started, still starting, or ended). The agent door uses it to recognise the plugin's own
    /// connection: a peer that descends from this process.
    public var programPID: pid_t? {
        lock.withLock { program?.running }?.livePID
    }

    /// - Parameters:
    ///   - programsAllowed: false refuses every program start (`ProgramPolicy.spawnAllowed`).
    ///   - programEnvironment: builds a program's whole environment from the settings the plugin
    ///     asks for (already narrowed to the manifest's `programEnv`); see `ProgramEnvironment.make`.
    public init(manifest: PluginManifest, folder: URL, dataFolder: URL, runtime: URL, host: URL,
                commandPaths: [String: String], programsAllowed: Bool = false,
                programEnvironment: @escaping @Sendable (_ requested: [String: String]) -> [String: String]
                    = PluginProcess.minimalProgramEnvironment) {
        self.manifest = manifest
        self.folder = folder
        self.dataFolder = dataFolder
        self.runtime = runtime
        self.host = host
        self.commandPaths = commandPaths
        self.programsAllowed = programsAllowed
        self.programEnvironment = programEnvironment
    }

    /// The fixed part of `ProgramEnvironment` with the system's PATH and nothing the plugin asks
    /// for; the default until the app passes the real one.
    public static func minimalProgramEnvironment(_ requested: [String: String]) -> [String: String] {
        ProgramEnvironment.make(home: NSHomeDirectory(), user: NSUserName(), loginPath: "/usr/bin:/bin:/usr/sbin:/sbin",
                                tmpdir: NSTemporaryDirectory(),
                                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                                requested: [:], allowed: [])
    }

    /// If the owner lets go of a running plugin, don't leave Bun running on its own.
    deinit {
        terminateNow()
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
        // Bun's flags come before "run":
        //   --config: our own (empty) bunfig.toml, so a bunfig.toml in the plugin folder (which could
        //             preload code before host.ts, or rewrite identifiers with [define]) is not read;
        //   --no-env-file: don't load the plugin folder's .env files into process.env;
        //   --no-install: never try to auto-install a missing package (it would fail anyway: no network).
        let bunfig = (hostPath as NSString).deletingLastPathComponent + "/bunfig.toml"
        process.arguments = ["-p", profile, runtimePath, "--config=" + bunfig, "--no-env-file", "--no-install",
                             "run", hostPath, backgroundPath, Self.permissionFlags(manifest.permissions)]
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
        input.attach(stdinPipe.fileHandleForWriting)
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
        runningProgram()?.end(drain: true)
    }

    /// Kills the process at once (SIGKILL) and closes its stdin; for app termination, where
    /// there is no time to wait for a polite exit. Also kills the commands it started that are
    /// still running (they run outside the sandbox and would otherwise outlive the app).
    /// Safe to call any time, more than once.
    public func terminateNow() {
        let process: Process? = lock.withLock {
            stopping = true
            terminating = true
            return self.process
        }
        input.close()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        commandChildren.killAll()
        runningProgram()?.killNow()
    }

    /// Closes stdin, SIGTERM, and SIGKILL 2 s later if needed.
    private func end(_ process: Process) {
        input.close()
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
    /// process is gone. If more than 16 MB is already waiting (the plugin has stopped reading),
    /// the message is dropped and the plugin is stopped.
    public func send(_ message: PluginWire) {
        guard var line = try? JSONEncoder().encode(message) else { return }
        line.append(0x0A)   // JSONEncoder never emits a raw newline, so one message = one line
        guard !input.enqueue(line, limit: Self.maxPendingInput) else { return }
        let first: Bool = lock.withLock {
            defer { inputOverflowed = true }
            return !inputOverflowed
        }
        if first { log("error", "plugin is not reading its input") }
        // SIGTERM (then SIGKILL) ends the process; the blocked write then fails with EPIPE and the
        // queue drains.
        stop()
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
            log(level, text)   // log() maps unknown levels to "info"
        case let .runCommand(callID, command, arguments):
            runCommand(callID: callID, command: command, arguments: arguments)
        case let .startProgram(programID, name, arguments, environment):
            startProgram(programID: programID, name: name, arguments: arguments, requested: environment)
        case let .programInput(programID, data):
            writeProgramInput(programID: programID, base64: data)
        case let .closeProgramInput(programID):
            runningProgram(programID)?.closeInput()
        case let .killProgram(programID, signal):
            runningProgram(programID)?.end(signal: ProgramSignal.number(signal), drain: false)
        case let .programOutputRead(programID, bytes):
            runningProgram(programID)?.acknowledge(bytes)
        case let .panelPost(payload):
            lock.withLock { _onPanelPost }?(payload)
        case let .frontRequest(requestID):
            lock.withLock { _onFrontRequest }?(requestID)
        case let .browserServerRequest(requestID):
            lock.withLock { _onBrowserServerRequest }?(requestID)
        case .pageMessage, .commandResult, .panelMessage, .programStarted, .programFailed, .programOutput, .programExit,
             .frontChanged:
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

    /// Passes a log line on: the level is one of debug/info/warn/error (anything else becomes
    /// info) and the message is cut to 8 KB.
    private func log(_ level: String, _ message: String) {
        let level = ["debug", "info", "warn", "error"].contains(level) ? level : "info"
        var text = message
        if text.utf8.count > Self.maxLogMessageBytes {
            // Cut on bytes; a character split in half becomes U+FFFD. "…" is 3 bytes.
            text = String(decoding: text.utf8.prefix(Self.maxLogMessageBytes - 3), as: UTF8.self) + "…"
        }
        lock.withLock { _onLog }?(level, text)
    }

    /// Runs a command the manifest declares, at its pinned path; anything else gets status 126.
    /// Up to 4 commands may run at the same time, each answering with its own callID; more are
    /// refused at once (status 126, "too many commands running"), not queued.
    private func runCommand(callID: Int, command: String, arguments: [String]) {
        func refuse(_ reason: String) {
            send(.commandResult(callID: callID, result: CommandResult(status: 126, stdout: "", stderr: reason, timedOut: false)))
        }
        let allowed = CommandPolicy.allows(command: command, arguments: arguments,
                                           declared: manifest.permissions.commands)
        guard allowed, let path = commandPaths[command] else { return refuse("not allowed by the manifest") }
        let admitted: Bool = lock.withLock {
            guard runningCommands < Self.maxConcurrentCommands else { return false }
            runningCommands += 1
            return true
        }
        guard admitted else { return refuse("too many commands running") }
        Task.detached { [weak self] in
            guard let children = self?.commandChildren else { return }
            let result = await CommandBroker.run(path: path, arguments: arguments, timeout: Self.commandTimeout,
                                                 children: children)
            guard let self else { return }
            // A PluginProcess runs once, so "stopping" marks its only generation as over: results
            // that come back after stop() are dropped.
            let deliver: Bool = self.lock.withLock {
                self.runningCommands -= 1
                return !self.stopping
            }
            if deliver { self.send(.commandResult(callID: callID, result: result)) }
        }
    }

    // MARK: - The running program

    /// Starts the program the plugin asks for, or answers `.programFailed` with the reason.
    private func startProgram(programID: Int, name: String, arguments: [String], requested: [String: String]) {
        func refuse(_ reason: String) { send(.programFailed(programID: programID, reason: reason)) }
        guard programsAllowed else { return refuse("programs are off in a test copy") }
        guard manifest.permissions.programs.contains(name), let path = commandPaths[name] else {
            return refuse("not allowed by the manifest")
        }
        // Checked again at every start: the file at the pinned path may have been replaced.
        guard PluginLaunch.isAllowedProgram(path) else { return refuse("the program is missing or changed") }
        enum Reservation { case reserved, busy, stopping }
        let reservation: Reservation = lock.withLock {
            if stopping { return .stopping }
            if program != nil { return .busy }
            program = (programID, name, nil)
            return .reserved
        }
        switch reservation {
        case .stopping: return   // the plugin is going away; nobody would hear the answer
        case .busy: return refuse("a program is already running")
        case .reserved: break
        }
        // Only the settings the manifest lists reach `programEnvironment`.
        let allowed = requested.filter { manifest.permissions.programEnv.contains($0.key) }
        let running: RunningProgram
        do {
            running = try RunningProgram.start(
                path: path, arguments: arguments, environment: programEnvironment(allowed),
                directory: (try? Self.realPath(dataFolder)) ?? dataFolder.path,
                maxUnread: Self.maxProgramUnread, chunk: Self.maxProgramOutputChunk
            ) { [weak self] event in
                self?.programEvent(event, programID: programID, name: name)
            }
        } catch {
            lock.withLock { program = nil }
            return refuse(error.reason)
        }
        let (stoppedMeanwhile, terminatedMeanwhile): (Bool, Bool) = lock.withLock {
            program = (programID, name, running)
            return (stopping, terminating)
        }
        // stop() or terminateNow() came while it was starting and couldn't see it yet.
        if terminatedMeanwhile { running.killNow() }
        // Announced before any output can be read (`begin`), so the plugin hears of it first.
        send(.programStarted(programID: programID))
        running.begin()
        if stoppedMeanwhile && !terminatedMeanwhile { running.end(drain: true) }
    }

    private func programEvent(_ event: RunningProgram.Event, programID: Int, name: String) {
        switch event {
        case let .output(data, unread):
            lock.withLock { _programUnreadPeak = max(_programUnreadPeak, unread) }
            send(.programOutput(programID: programID, data: data.base64EncodedString()))
        case .stderrLine(let line):
            log("info", "\(name): " + String(line.prefix(Self.maxProgramLogLine)))
        case let .exit(status, signal):
            // Cleared before the plugin hears of the exit, so it may start the next one at once.
            lock.withLock { if program?.id == programID { program = nil } }
            lock.withLock { _onProgramExit }?()
            send(.programExit(programID: programID, status: status, signal: signal.map(ProgramSignal.name)))
        }
    }

    private func writeProgramInput(programID: Int, base64: String) {
        guard let running = runningProgram(programID) else { return }   // gone already: dropped
        guard let data = Data(base64Encoded: base64) else {
            return log("error", "ignored program input that is not base64")
        }
        guard !running.write(data) else { return }
        log("error", "the program is not reading its input; it was ended")
        running.end(drain: false)
    }

    /// The running program, if there is one (and, given an id, only if it has that id).
    private func runningProgram(_ id: Int? = nil) -> RunningProgram? {
        lock.withLock {
            guard let program, id == nil || program.id == id else { return nil }
            return program.running
        }
    }

    private func reportExit(_ status: Int32) {
        let callback: (@Sendable (Int32) -> Void)? = lock.withLock {
            guard !exitReported else { return nil }
            exitReported = true
            return _onExit
        }
        input.close()
        // The plugin is gone; its program goes too.
        runningProgram()?.end(drain: true)
        callback?(status)
    }

    // MARK: - Helpers

    /// The manifest's two reach permissions as JSON, passed to host.ts as its third argument so the
    /// API can refuse `front()` locally (the app refuses again; this only gives a clear error).
    static func permissionFlags(_ permissions: PluginManifest.Permissions) -> String {
        #"{"frontTab":\#(permissions.frontTab),"browser":\#(permissions.browser),"terminals":\#(permissions.terminals)}"#
    }

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

/// A plugin's stdin: writes run in order on a serial queue of their own, so callers never block
/// (a plugin that stops reading would otherwise freeze the app once the 64 KB pipe is full), and
/// the bytes still waiting are counted so the queue can be capped.
/// `@unchecked Sendable`: `handle` is only touched on `queue`, `pending` only while holding `lock`.
private final class PluginInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.roosa.singularity.plugin-stdin")
    private let lock = NSLock()
    private var pending = 0
    private var handle: FileHandle?

    var pendingBytes: Int { lock.withLock { pending } }

    func attach(_ handle: FileHandle) {
        queue.async { self.handle = handle }
    }

    /// Queues `data` for writing. Returns false, queueing nothing, when that would leave more than
    /// `limit` bytes waiting.
    func enqueue(_ data: Data, limit: Int) -> Bool {
        let accepted: Bool = lock.withLock {
            guard pending + data.count <= limit else { return false }
            pending += data.count
            return true
        }
        guard accepted else { return false }
        queue.async {
            defer { self.lock.withLock { self.pending -= data.count } }
            guard let handle = self.handle else { return }   // not started yet, or already closed
            // Blocks while the pipe is full. EPIPE (the plugin exited): stop writing for good.
            do { try handle.write(contentsOf: data) } catch {
                try? handle.close()
                self.handle = nil
            }
        }
        return true
    }

    /// Closes stdin after the writes already queued (host.ts exits when its input ends).
    func close() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
        }
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

    private let makeProcess: @Sendable () throws -> PluginProcess
    private let now: @Sendable () -> Date
    private let restartDelay: Duration

    private let lock = NSLock()
    private var _state: State = .stopped
    private var wanted = false   // between start() and stop()
    /// A launch (first start or restart) is under way or scheduled; start() then does nothing.
    private var launchPending = false
    private var current: PluginProcess?
    /// Bumped on every launch and on stop, so a late exit from an old process is ignored.
    private var generation = 0
    private var crashTimes: [Date] = []
    private var logs: [LogLine] = []
    private var _onReply: (@Sendable (Int, JSONValue) -> Void)?
    private var _onLog: (@Sendable (String, String) -> Void)?
    private var _onStateChange: (@Sendable (State) -> Void)?
    private var _onPanelPost: (@Sendable (JSONValue) -> Void)?
    private var _onFrontRequest: (@Sendable (Int) -> Void)?
    private var _onBrowserServerRequest: (@Sendable (Int) -> Void)?
    private var _onProgramExit: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - restartDelay: pause before a restart.
    ///   - now: the clock used for the 60 s window (tests pass a fake one).
    ///   - makeProcess: builds a fresh, not yet started process (a `Process` can only run once).
    ///     Called for every launch, restarts included, on the thread that calls `start()` (restarts:
    ///     a background thread). It may throw to refuse a launch (the app re-checks the plugin's
    ///     approval there); that ends as `.failedToStart`, without further restarts.
    public init(restartDelay: Duration = .seconds(1), now: @escaping @Sendable () -> Date = { Date() },
                makeProcess: @escaping @Sendable () throws -> PluginProcess) {
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
    /// What the running process sends its own page (`PluginProcess.onPanelPost`).
    public var onPanelPost: (@Sendable (JSONValue) -> Void)? {
        get { lock.withLock { _onPanelPost } }
        set { lock.withLock { _onPanelPost = newValue } }
    }

    /// What the running process asks (`PluginProcess.onFrontRequest`, `onBrowserServerRequest`).
    public var onFrontRequest: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onFrontRequest } }
        set { lock.withLock { _onFrontRequest = newValue } }
    }
    public var onBrowserServerRequest: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onBrowserServerRequest } }
        set { lock.withLock { _onBrowserServerRequest = newValue } }
    }
    /// The plugin's program ended (after `programPID` became nil). The agent door then closes the
    /// connections that came from it.
    public var onProgramExit: (@Sendable () -> Void)? {
        get { lock.withLock { _onProgramExit } }
        set { lock.withLock { _onProgramExit = newValue } }
    }

    /// Starts the plugin. Does nothing while a process is running or a restart is pending.
    /// The crash count is kept: after `.crashedRepeatedly`, start() alone allows one more try
    /// (the next crash gives up again); `stop()` then `start()` starts the count over.
    public func start() {
        let ready: Bool = lock.withLock {
            guard current == nil, !launchPending else { return false }
            wanted = true
            return true
        }
        if ready { launch(ifGeneration: nil) }
    }

    /// Stops the plugin for good; it is not restarted. Also forgets earlier crashes.
    public func stop() {
        let process: PluginProcess? = lock.withLock {
            wanted = false
            launchPending = false
            crashTimes = []
            generation += 1   // the coming exit belongs to an old generation: no restart
            defer { current = nil }
            return current
        }
        process?.stop()
        setState(.stopped)
    }

    /// For app termination: like `stop()`, but kills the process at once (SIGKILL) instead of
    /// asking it to exit and waiting.
    public func terminateNow() {
        let process: PluginProcess? = lock.withLock {
            wanted = false
            launchPending = false
            generation += 1
            defer { current = nil }
            return current
        }
        process?.terminateNow()
        setState(.stopped)
    }

    /// The pid of the running process's program (`PluginProcess.programPID`); nil when none runs.
    public var programPID: pid_t? {
        lock.withLock { current }?.programPID
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
        let process: PluginProcess
        do {
            process = try makeProcess()
        } catch {
            // A restart had set launchPending; clear it so a later start() can try again.
            lock.withLock { if expected == nil || expected == self.generation { launchPending = false } }
            record("error", "not started: \(error)")
            setState(.failedToStart(String(describing: error)), ifGeneration: expected)
            return
        }
        // Reserve a generation now; `current` is set only once the process has started, so
        // send() never hands a message to a process that can't take it yet.
        let generation: Int? = lock.withLock {
            guard allowed() else { return nil }
            self.generation += 1
            launchPending = true
            return self.generation
        }
        guard let generation else { return }
        process.onReply = { [weak self] id, payload in self?.onReply?(id, payload) }
        process.onLog = { [weak self] level, message in self?.record(level, message) }
        process.onPanelPost = { [weak self] payload in self?.onPanelPost?(payload) }
        process.onFrontRequest = { [weak self] id in self?.onFrontRequest?(id) }
        process.onProgramExit = { [weak self] in self?.onProgramExit?() }
        process.onBrowserServerRequest = { [weak self] id in self?.onBrowserServerRequest?(id) }
        process.onExit = { [weak self] status in self?.processExited(status: status, generation: generation) }
        do {
            try process.start()
        } catch {
            lock.withLock { if self.generation == generation { launchPending = false } }
            record("error", "could not start: \(error)")
            setState(.failedToStart(String(describing: error)), ifGeneration: generation)
            return
        }
        // A stop() (or an exit) while it was starting changed the generation: don't keep it.
        let keep = lock.withLock {
            guard self.generation == generation else { return false }
            current = process
            launchPending = false
            return true
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
            let restart = crashTimes.count <= Self.maxRestarts
            launchPending = restart   // start() must not jump in (or reset anything) meanwhile
            return (restart, self.generation)
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
            // A stop() during the delay changes the generation, and launch then does nothing.
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
