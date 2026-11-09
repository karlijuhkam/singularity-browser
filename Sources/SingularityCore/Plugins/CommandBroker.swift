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

    /// Where `name` lives, as the user's login shell would find it (GUI apps don't inherit the
    /// shell's PATH, so we ask the shell). Returns nil for invalid or refused names, and for anything
    /// that isn't an absolute path to an executable regular file.
    public static func resolve(_ name: String, loginShell: String) -> String? {
        guard CommandPolicy.isValidName(name), !CommandPolicy.isRefused(name) else { return nil }
        // The name is passed as the positional argument $1, never pasted into the script text,
        // so it cannot inject shell syntax. "singularity-resolve" becomes $0.
        let output = runShortProcess(
            loginShell, ["-l", "-c", "command -v -- \"$1\"", "singularity-resolve", name], timeout: 5)
        return output.flatMap(accept)
    }

    /// Picks the answer out of a login shell's stdout and vets it. Internal so tests can call it directly.
    static func accept(_ output: String) -> String? {
        // Login shells can print noise from rc files first; the answer is the last non-empty line.
        guard let line = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return nil }
        guard line.hasPrefix("/") else { return nil }   // rejects aliases, functions, builtins ("alias ls=...")
        let real = URL(fileURLWithPath: line).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: real) else { return nil }
        // A friendly name can point at an interpreter (foo -> python3): check both names.
        if CommandPolicy.isRefused((line as NSString).lastPathComponent)
            || CommandPolicy.isRefused((real as NSString).lastPathComponent) { return nil }
        return line   // as printed, not the symlink target: the approval screen shows and pins this
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

    /// Runs `path` with `arguments` (no shell), empty stdin, the app's own environment. Collects
    /// stdout and stderr (each capped at 10 MB). After `timeout` it sends SIGTERM, then SIGKILL 2 s
    /// later, and reports `timedOut`. Never blocks a thread while waiting.
    public static func run(path: String, arguments: [String], timeout: Duration) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
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
