import Foundation

/// What a finished command produced.
public struct CommandResult: Codable, Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The only way a sandboxed plugin gets a program run on the Mac (outside its sandbox).
/// `resolve` finds a program's absolute path; `run` executes it. Neither is ever given a shell
/// command line built from plugin input.
public enum CommandBroker {
    /// Most bytes kept per output stream; the rest is read and thrown away so the program never blocks.
    static let outputCap = 10_000_000

    // MARK: - resolve

    /// The first executable regular file named `name` on the user's login PATH. That is exactly
    /// what `PluginProcess` will run: it execs the path directly, never through a shell, so shell
    /// aliases, functions and builtins (zsh's `echo`) don't count. GUI apps don't inherit the
    /// shell's PATH, so the login shell is asked for it. Returns nil for invalid or refused names
    /// (checked before any shell runs), and when nothing suitable is found.
    ///
    /// Blocks up to ~6 s (runs the login shell). Never call on the main actor.
    public static func resolve(_ name: String, loginShell: String) -> String? {
        guard CommandPolicy.isValidName(name), !CommandPolicy.isRefused(name),
              let path = loginPath(loginShell: loginShell) else { return nil }
        return find(name, inPath: path)
    }

    /// The PATH a login shell sets up (what a terminal would use); nil when the shell fails or
    /// takes longer than 5 s. Blocks while the shell runs: never call on the main actor.
    public static func loginPath(loginShell: String) -> String? {
        // A fixed script: nothing from a plugin goes into it. The marker line lets us skip
        // whatever rc files print first; `printenv` (not `echo $PATH`) also works in fish.
        let script = "echo \(pathMarker); /usr/bin/printenv PATH"
        guard let output = runShortProcess(loginShell, ["-l", "-c", script], timeout: 5) else { return nil }
        return loginPath(fromShellOutput: output)
    }

    static let pathMarker = "__SINGULARITY_PATH__"

    /// The line after the marker line in the login shell's output.
    static func loginPath(fromShellOutput output: String) -> String? {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let marker = lines.firstIndex(of: pathMarker), marker + 1 < lines.count else { return nil }
        let path = lines[marker + 1]
        return path.isEmpty ? nil : path
    }

    /// Walks `path` (a PATH value) in order and returns the first `<dir>/<name>` that passes `vet`.
    /// Empty and relative entries are skipped (they would depend on the current directory).
    public static func find(_ name: String, inPath path: String) -> String? {
        guard CommandPolicy.isValidName(name), !CommandPolicy.isRefused(name) else { return nil }
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) where entry.hasPrefix("/") {
            let directory = entry.hasSuffix("/") ? String(entry.dropLast()) : String(entry)
            if let found = vet(directory + "/" + name) { return found }
        }
        return nil
    }

    /// `candidate` if it is (after following symlinks) an executable regular file whose name and
    /// whose target's name are both allowed; else nil. Returned as given, not the symlink target:
    /// the approval screen shows and pins this path.
    static func vet(_ candidate: String) -> String? {
        let real = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: real) else { return nil }
        // A friendly name can point at an interpreter (foo -> python3): check both names.
        if CommandPolicy.isRefused((candidate as NSString).lastPathComponent)
            || CommandPolicy.isRefused((real as NSString).lastPathComponent) { return nil }
        return candidate
    }

    /// Runs a program with empty stdin, discards stderr, and returns stdout; nil on failure or
    /// timeout. Blocking, meant for `resolve` only.
    private static func runShortProcess(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // Read on a background queue so a chatty shell can't fill the pipe and hang.
        let collected = LockedBuffer(cap: 1_000_000)
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            collected.drain(pipe.fileHandleForReading)
            reading.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminateHard(process)
            return nil
        }
        _ = reading.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else { return nil }
        return collected.string
    }

    // MARK: - run

    /// Runs `path` with `arguments` (no shell), empty stdin, and the app's own environment unless
    /// `environment` is given (then exactly that, nothing inherited). `currentDirectory`: the
    /// working directory (default: the app's). Collects stdout and stderr (each capped at 10 MB).
    /// After `timeout` it sends SIGTERM, then SIGKILL 2 s later, and reports `timedOut`. Never
    /// blocks a thread while waiting. `children`: the program is listed there while it runs, so
    /// its owner can kill it (`RunningChildren.killAll`, at app quit).
    public static func run(path: String, arguments: [String], timeout: Duration,
                           environment: [String: String]? = nil, currentDirectory: URL? = nil,
                           children: RunningChildren? = nil) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice   // /dev/null: programs that read stdin see EOF at once
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Two pipes must be read at the same time: a program that fills one 64 KB pipe buffer while
        // we are only reading the other would block forever.
        let out = LockedBuffer(cap: outputCap), err = LockedBuffer(cap: outputCap)
        let outDone = Completion(), errDone = Completion()

        // Resume this task when the process exits (the handler runs on a Foundation thread).
        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                err.append(Data("could not start \(path): \(error.localizedDescription)".utf8))
                continuation.resume(returning: nil)
                return
            }
            // Listed for its owner; an owner that is already shutting down gets it killed at once.
            if let children, !children.add(process) { kill(process.processIdentifier, SIGKILL) }
            // Parent keeps only the read ends; the child holds its own copies of the write ends.
            // (Pipe closes our write ends when the Pipe is deallocated; Process closes them after launch.)
            DispatchQueue.global().async { out.drain(outPipe.fileHandleForReading); outDone.finish() }
            DispatchQueue.global().async { err.drain(errPipe.fileHandleForReading); errDone.finish() }
            // Watchdog: TERM, then KILL after 2 s. Cancelled-by-flag when the process ends first.
            let flag = process.processIdentifier
            Task.detached {
                try? await Task.sleep(for: timeout)
                guard process.isRunning, process.processIdentifier == flag else { return }
                timeoutFired.set(flag)
                process.terminate()                                  // SIGTERM
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning { kill(flag, SIGKILL) }         // ignored SIGTERM: force it
            }
        }
        // Exited (and reaped): no longer one of the owner's children. Removed here, after the
        // await, so it always comes after `add`.
        children?.remove(process)
        guard let status else {
            return CommandResult(status: -1, stdout: "", stderr: err.string, timedOut: false)
        }
        // The process is gone; its pipes normally hit EOF immediately. A grandchild that inherited
        // the pipes could keep them open, so wait only briefly and then use what we have.
        await outDone.wait(upTo: .seconds(1))
        await errDone.wait(upTo: .seconds(1))
        return CommandResult(status: status, stdout: out.string, stderr: err.string,
                             timedOut: timeoutFired.take(process.processIdentifier))
    }

    /// Remembers which pids the watchdog fired for (a tiny shared flag set, lock-protected).
    private static let timeoutFired = PidSet()

    /// SIGTERM, then SIGKILL after 2 s if still alive (blocking variant used by `resolve`).
    private static func terminateHard(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
    }
}

// MARK: - Children of one owner

/// The programs `CommandBroker.run` started for one owner (a `PluginProcess`) that are still
/// running, so the owner can kill them when it ends: at app quit, a command a plugin started
/// shouldn't outlive the app. Holds only processes it was given, each until `run` has seen it exit.
public final class RunningChildren: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var closed = false

    public init() {}

    /// Adds a just-started process; false once `killAll` was called (the caller kills it).
    func add(_ process: Process) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            processes[ObjectIdentifier(process)] = process
            return true
        }
    }

    func remove(_ process: Process) {
        lock.withLock { _ = processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// How many are listed (for tests).
    public var count: Int { lock.withLock { processes.count } }

    /// SIGKILLs every listed process that is still running, and refuses new ones from now on.
    /// `isRunning` is false once Foundation has reaped the child, so a pid that may already
    /// belong to another program is never signalled.
    public func killAll() {
        let list: [Process] = lock.withLock {
            closed = true
            return Array(processes.values)
        }
        for process in list where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

// MARK: - Small thread-safe helpers

/// Accumulates bytes from a pipe on a background thread, keeping at most `cap`.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < cap { data.append(chunk.prefix(cap - data.count)) }
    }

    /// Reads until EOF. Keeps reading past the cap (and discarding) so the writer never blocks.
    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData        // blocks until data or EOF (empty Data)
            if chunk.isEmpty { break }
            append(chunk)
        }
        try? handle.close()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A one-shot "this reader finished" signal that async code can wait on with a limit.
private final class Completion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func finish() { semaphore.signal() }
    func wait(upTo limit: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
                _ = self.semaphore.wait(timeout: .now() + seconds)
                continuation.resume()
            }
        }
    }
}

private final class PidSet: @unchecked Sendable {
    private let lock = NSLock()
    private var pids = Set<Int32>()
    func set(_ pid: Int32) { lock.lock(); pids.insert(pid); lock.unlock() }
    func take(_ pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.remove(pid) != nil }
}
