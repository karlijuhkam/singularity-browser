import Foundation

// A plugin's running program: one program from `permissions.programs`, started by the app outside
// the plugin's sandbox and kept running while the plugin talks to it over its stdin and stdout.
// `PluginProcess` decides whether a start is allowed and carries the bytes as `PluginWire`
// messages; this file has the rules (`ProgramPolicy`, `ProgramEnvironment`) and the process itself
// (`RunningProgram`). host.ts's `singularity.spawn` is the other end.

/// Whether this copy of the app may start plugin programs at all.
public enum ProgramPolicy {
    /// False in a test or development copy (`SINGULARITY_HOME` set): its programs would run with
    /// the owner's real home folder, accounts and settings. `SINGULARITY_REAL_PROGRAMS=1`, set by
    /// hand for a hands-on check, allows them anyway.
    public static func spawnAllowed(environment: [String: String]) -> Bool {
        environment["SINGULARITY_HOME"] == nil || environment["SINGULARITY_REAL_PROGRAMS"] == "1"
    }
}

/// The environment a plugin's program gets. The app builds it; the plugin only adds settings its
/// manifest lists in `programEnv`. Nothing is inherited from the app's own environment (which may
/// hold tokens, SSH_AUTH_SOCK and the like).
public enum ProgramEnvironment {
    /// Exactly `HOME`, `USER`, `LOGNAME`, `PATH`, `TMPDIR`, `LANG`, `CLAUDE_AGENT_SDK_CLIENT_APP`,
    /// plus each `requested` pair whose name is in `allowed` and whose value is not empty and has no
    /// NUL. A requested name can't replace one of the fixed ones.
    public static func make(home: String, user: String, loginPath: String, tmpdir: String, appVersion: String,
                            requested: [String: String], allowed: [String]) -> [String: String] {
        var environment: [String: String] = [:]
        for (name, value) in requested where allowed.contains(name) && !value.isEmpty && !value.contains("\u{0}") {
            environment[name] = value
        }
        let fixed = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": loginPath,
            "TMPDIR": tmpdir,
            "LANG": "en_US.UTF-8",
            // Tells the Agent SDK's program which app it runs in.
            "CLAUDE_AGENT_SDK_CLIENT_APP": "singularity/\(appVersion)",
        ]
        environment.merge(fixed) { _, fixedValue in fixedValue }
        return environment
    }
}

/// Signal names on the wire.
public enum ProgramSignal {
    /// The signal `killProgram` asks for: SIGTERM, SIGKILL or SIGINT; anything else is SIGTERM.
    public static func number(_ name: String) -> Int32 {
        switch name {
        case "SIGKILL": SIGKILL
        case "SIGINT": SIGINT
        default: SIGTERM
        }
    }

    /// "SIGTERM" for 15, and so on; "SIG<n>" for a number without a name.
    public static func name(_ signal: Int32) -> String {
        let names = ["SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGEMT", "SIGFPE", "SIGKILL",
                     "SIGBUS", "SIGSEGV", "SIGSYS", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGURG", "SIGSTOP", "SIGTSTP",
                     "SIGCONT", "SIGCHLD", "SIGTTIN", "SIGTTOU", "SIGIO", "SIGXCPU", "SIGXFSZ", "SIGVTALRM",
                     "SIGPROF", "SIGWINCH", "SIGINFO", "SIGUSR1", "SIGUSR2"]   // 1…31 on macOS
        return (1...names.count).contains(Int(signal)) ? names[Int(signal) - 1] : "SIG\(signal)"
    }
}

/// One started program. Its stdout is read in pieces of at most `chunk` bytes and handed to
/// `onEvent`; reading stops while more than `maxUnread` bytes were handed on and not yet
/// `acknowledge`d, so a slow reader slows the program instead of filling the app's memory.
/// stderr comes out as lines. `.exit` comes once, last, after all output.
///
/// The program is started with posix_spawn, by path (never through a shell), in a new process
/// group of its own, so `end` and `killNow` reach whatever it started too.
///
/// `@unchecked Sendable`: the mutable state is only touched on `queue` (a serial queue), except
/// `pendingInput`, which is behind `inputLock`.
final class RunningProgram: @unchecked Sendable {
    enum Event: Sendable {
        /// Bytes from stdout, and how many bytes are now unacknowledged (this piece included).
        case output(Data, unread: Int)
        case stderrLine(String)
        /// Exit status when it exited, signal number when a signal ended it.
        case exit(status: Int32?, signal: Int32?)
    }

    struct StartError: Error { let reason: String }

    /// Longest stderr line kept whole; longer lines are dropped with a note.
    static let maxStderrLine = 64 * 1024
    /// After the program has exited, how long to wait for its pipes to close before reporting the
    /// exit anyway (something it started may have kept them open).
    static let pipeGrace: TimeInterval = 2
    /// Most bytes of input waiting to be written before the program counts as stuck.
    static let maxPendingInput = 16 << 20

    let pid: pid_t
    /// Set by the reaper thread once the program has ended, *before* it is reaped: while this is
    /// false the pid can't have been handed to another process.
    private let endedLock = NSLock()
    private var ended = false
    private let maxUnread: Int
    private let chunk: Int
    private let onEvent: @Sendable (Event) -> Void

    private let queue = DispatchQueue(label: "dev.roosa.singularity.plugin-program")
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutDone = false
    private var stderrDone = false
    private var paused = false
    /// Set once the plugin is gone: output is then read and dropped, without waiting for acks.
    private var draining = false
    private var unread = 0
    private var reaped: (status: Int32?, signal: Int32?)?
    private var exitReported = false
    private var stderrLines = LineSplitter(maxLength: RunningProgram.maxStderrLine)

    /// Writes to stdin, in order, on a queue of their own (a write blocks while the pipe is full).
    private let inputQueue = DispatchQueue(label: "dev.roosa.singularity.plugin-program-stdin")
    private var stdinFD: Int32   // only touched on inputQueue once started
    private let inputLock = NSLock()
    private var pendingInput = 0

    private init(pid: pid_t, stdin: Int32, maxUnread: Int, chunk: Int, onEvent: @escaping @Sendable (Event) -> Void) {
        self.pid = pid
        self.stdinFD = stdin
        self.maxUnread = maxUnread
        self.chunk = chunk
        self.onEvent = onEvent
    }

    /// Starts `path` with `arguments` and exactly `environment`, in `directory`. Nothing is read
    /// until `begin()`, so the caller can announce the start first.
    static func start(path: String, arguments: [String], environment: [String: String], directory: String,
                      maxUnread: Int, chunk: Int,
                      onEvent: @escaping @Sendable (Event) -> Void) throws(StartError) -> RunningProgram {
        let spawned = try spawn(path: path, arguments: arguments, environment: environment, directory: directory)
        let program = RunningProgram(pid: spawned.pid, stdin: spawned.stdin, maxUnread: maxUnread, chunk: chunk,
                                     onEvent: onEvent)
        program.stdoutSource = program.makeSource(spawned.stdout) { $0.readStdout() }
        program.stderrSource = program.makeSource(spawned.stderr) { $0.readStderr() }
        // A thread of its own blocks until the program ends, then reaps it.
        let pid = spawned.pid
        Thread.detachNewThread {
            // First wait without reaping (WNOWAIT): while the ended program is not reaped, its pid
            // (= its group's id) can't be given to anyone else, so SIGKILL to the group reaches only
            // what it started and left behind. Nothing it started outlives it.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            // Ended, not yet reaped: from now on `livePID` is nil, before the pid can be reused.
            program.endedLock.withLock { program.ended = true }
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            // The wait status: low 7 bits = the signal that ended it (0: it exited), next 8 bits = exit status.
            let signal = status & 0x7f
            let ended: (Int32?, Int32?) = signal == 0 ? ((status >> 8) & 0xff, nil) : (nil, signal)
            program.queue.async { program.programEnded(ended) }
        }
        return program
    }

    /// The program's pid while it runs; nil once it has ended (then the pid may soon be reused).
    var livePID: pid_t? {
        endedLock.withLock { ended ? nil : pid }
    }

    /// Starts reading stdout and stderr.
    func begin() {
        queue.async {
            self.stdoutSource?.resume()
            self.stderrSource?.resume()
        }
    }

    // MARK: Input

    /// Queues bytes for the program's stdin. Dropped once stdin is closed or the program is gone.
    /// False (nothing queued) when more than 16 MB would be waiting: the program isn't reading.
    func write(_ data: Data) -> Bool {
        let accepted: Bool = inputLock.withLock {
            guard pendingInput + data.count <= Self.maxPendingInput else { return false }
            pendingInput += data.count
            return true
        }
        guard accepted else { return false }
        inputQueue.async {
            defer { self.inputLock.withLock { self.pendingInput -= data.count } }
            guard self.stdinFD >= 0 else { return }
            let complete = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(self.stdinFD, buffer.baseAddress! + offset, buffer.count - offset)
                    if n > 0 { offset += n } else if n == -1 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            // EPIPE (F_SETNOSIGPIPE turned the signal into this error): the program has gone, so
            // the rest of its input is dropped.
            if !complete { self.closeStdin() }
        }
        return true
    }

    /// Closes stdin after the writes already queued.
    func closeInput() {
        inputQueue.async { self.closeStdin() }
    }

    private func closeStdin() {   // on inputQueue
        if stdinFD >= 0 { Darwin.close(stdinFD) }
        stdinFD = -1
    }

    // MARK: Output

    /// The plugin has taken `bytes` of the output: read more if we had stopped.
    func acknowledge(_ bytes: Int) {
        queue.async {
            self.unread = max(0, self.unread - max(0, bytes))
            if self.paused, self.unread <= self.maxUnread { self.resumeStdout() }
        }
    }

    private func makeSource(_ fd: Int32, _ handler: @escaping @Sendable (RunningProgram) -> Void) -> DispatchSourceRead {
        // Non-blocking, so a read never waits: the source says when bytes (or end-of-file) are there.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in if let self { handler(self) } }
        source.setCancelHandler { Darwin.close(fd) }
        return source
    }

    private func readStdout() {   // on queue
        guard let source = stdoutSource, !stdoutDone else { return }
        var buffer = [UInt8](repeating: 0, count: chunk)
        let n = Darwin.read(Int32(source.handle), &buffer, chunk)
        if n > 0 {
            if draining { return }
            unread += n
            onEvent(.output(Data(buffer[0..<n]), unread: unread))
            if unread > maxUnread {
                // Stop reading; the program blocks once its pipe is full. `acknowledge` resumes.
                source.suspend()
                paused = true
            }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            finishStdout()
        }
    }

    private func readStderr() {   // on queue
        guard let source = stderrSource, !stderrDone else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let n = Darwin.read(Int32(source.handle), &buffer, buffer.count)
        if n > 0 {
            stderrLines.append(Data(buffer[0..<n])).forEach(deliverStderr)
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            finishStderr()
        }
    }

    private func deliverStderr(_ piece: LineSplitter.Piece) {
        switch piece {
        case .line(let data) where !data.isEmpty: onEvent(.stderrLine(String(decoding: data, as: UTF8.self)))
        case .line: break
        case .tooLong: onEvent(.stderrLine("(a line longer than 64 KB was left out)"))
        }
    }

    private func resumeStdout() {
        paused = false
        stdoutSource?.resume()
    }

    private func finishStdout() {
        guard !stdoutDone else { return }
        stdoutDone = true
        // A suspended source must be resumed before it is cancelled, or it is never freed.
        if paused { resumeStdout() }
        stdoutSource?.cancel()
        stdoutSource = nil
        reportExitIfDone()
    }

    private func finishStderr() {
        guard !stderrDone else { return }
        stderrDone = true
        stderrLines.finish().forEach(deliverStderr)
        stderrSource?.cancel()
        stderrSource = nil
        reportExitIfDone()
    }

    // MARK: Ending

    private func programEnded(_ ended: (status: Int32?, signal: Int32?)) {   // on queue
        reaped = ended
        closeInput()
        reportExitIfDone()
        scheduleGrace()
    }

    /// Something the program started may keep its pipes open after it has gone. Then the exit is
    /// reported anyway after a short wait, but never while unread output is waiting for the plugin.
    private func scheduleGrace() {
        queue.asyncAfter(deadline: .now() + Self.pipeGrace) {
            guard !self.exitReported else { return }
            if self.paused && !self.draining { return self.scheduleGrace() }
            self.finishStdout()
            self.finishStderr()
        }
    }

    private func reportExitIfDone() {
        guard let reaped, stdoutDone, stderrDone, !exitReported else { return }
        exitReported = true
        onEvent(.exit(status: reaped.status, signal: reaped.signal))
    }

    /// Sends `signal` to the program's process group, then SIGKILL 2 s later. `drain`: the plugin is
    /// gone, so the output is read and dropped (a program blocked on a full pipe can then end).
    func end(signal: Int32 = SIGTERM, drain: Bool) {
        queue.async {
            if drain { self.draining = true }
            if self.paused && self.draining { self.resumeStdout() }
            kill(-self.pid, signal)   // see killGroup for why the group's id is safe to use
        }
        queue.asyncAfter(deadline: .now() + 2) { self.killGroup() }
    }

    /// SIGKILL to the program's process group at once (for app termination). The signal is sent
    /// right here, not queued: the app may exit before a queued block would run.
    func killNow() {
        kill(-pid, SIGKILL)   // `pid` is a constant; see killGroup for why the group's id is safe
        queue.async {
            self.draining = true
            if self.paused { self.resumeStdout() }
        }
    }

    /// SIGKILL to the group. While the program is not reaped its pid (= the group's id) is ours.
    /// After that, what it started is still in the group, and while a group has members its id
    /// can't be given to a new process; an empty group just gets ESRCH. (Only if the group is empty
    /// AND the pid was handed out again AND that new process made itself a group leader within
    /// these 2 s could this reach a stranger; macOS hands out pids in order, so that would take
    /// some 100,000 process starts.)
    private func killGroup() {   // on queue
        kill(-pid, SIGKILL)
    }

    // MARK: posix_spawn

    private struct Spawned { let pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32 }

    private static func spawn(path: String, arguments: [String], environment: [String: String],
                              directory: String) throws(StartError) -> Spawned {
        // Three pipes; [0] is the read end, [1] the write end.
        var pipes: [[Int32]] = []
        for _ in 0..<3 {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                pipes.flatMap { $0 }.forEach { Darwin.close($0) }
                throw StartError(reason: "could not start: " + String(cString: strerror(errno)))
            }
            // Close-on-exec, so no other program the app starts inherits them (only the dup2'd
            // copies below reach this program).
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            pipes.append(fds)
        }
        let (stdinPipe, stdoutPipe, stderrPipe) = (pipes[0], pipes[1], pipes[2])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP with group 0: the program leads a new process group, so one signal to the group
        // reaches what it starts. CLOEXEC_DEFAULT: it inherits only fds 0, 1 and 2, none of the
        // app's. SETSIGDEF/SETSIGMASK: signals the app ignores or blocks are normal again for it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal: Int32 in 1...31 where signal != SIGKILL && signal != SIGSTOP { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        // The program has its own copies of its ends (or never started): close ours.
        for fd in [stdinPipe[0], stdoutPipe[1], stderrPipe[1]] { Darwin.close(fd) }
        guard result == 0 else {
            for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] { Darwin.close(fd) }
            throw StartError(reason: "could not start: " + String(cString: strerror(result)))
        }
        // Writing to a program that has gone would kill the app with SIGPIPE; this makes the write
        // fail with EPIPE instead.
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
        return Spawned(pid: pid, stdin: stdinPipe[1], stdout: stdoutPipe[0], stderr: stderrPipe[0])
    }
}
