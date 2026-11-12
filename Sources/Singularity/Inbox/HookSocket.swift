import Darwin
import Foundation
import SingularityCore

/// What the inbox needs from a held Claude Code hook call. `HookConnection` is the real one; the
/// tests use a fake that records the replies.
protocol HookReplying: AnyObject, Sendable {
    /// The process id of the helper on the other end, as the kernel reports it; nil if unknown.
    var peerPID: pid_t? { get }
    /// Writes the acknowledgement byte (`ClaudeHook.ack`) at once, before any reply: the helper
    /// gives up after a few seconds without it. Called from the main actor, so it shows the app is
    /// alive. Only the first call counts.
    func acknowledge()
    /// Writes `data` as the hook's output and closes the connection. Only the first call counts.
    /// `ClaudeHook.noDecision` (empty) means "no decision": Claude Code shows its own prompt.
    func reply(_ data: Data)
    /// Called once, on any thread, when the helper went away before a reply (Claude Code killed it:
    /// the owner pressed Esc or Ctrl-C there, or quit). Set it after the request is held; if the
    /// helper already went, setting it calls it at once.
    var onClosedByPeer: (@Sendable () -> Void)? { get set }
}

/// The socket `singularity-hook` connects to (`~/Singularity/.run/hook.sock`). The listening part
/// is `MCPSocketListener`, reused as is: folder 0700, socket 0600, only processes of this user.
///
/// One connection carries one hook call: the helper sends one line (`ClaudeHook.wireLine`), then
/// waits until the app writes the reply and closes. Each connection reads on its own queue, so a
/// slow or silent helper never holds up the next one, the accept loop or the main thread.
final class HookSocket: @unchecked Sendable {
    /// Gets each well-formed request (tab id, hook input) with its connection, on a background
    /// queue. Must reply on the connection exactly once, now or later.
    typealias Handler = @Sendable (UUID, Data, HookConnection) -> Void

    /// A helper that has not sent its whole line by then is dropped (it sends at once).
    static let defaultIdleLimit: Duration = .seconds(10)

    private let listener: MCPSocketListener

    init(path: String, idleLimit: Duration = defaultIdleLimit, onRequest: @escaping Handler) {
        listener = MCPSocketListener(path: path) { fd in
            HookConnection(fd: fd, idleLimit: idleLimit, onRequest: onRequest).start()
        }
    }

    func start() throws {
        try listener.start()
    }

    /// Stops accepting and removes the socket file. Connections already accepted go on until
    /// they are answered (the inbox hands every held one back when the app quits).
    func stop() {
        listener.stop()
    }
}

/// One accepted helper connection: read one line, hand it over, later write the reply and close.
///
/// How it works, for readers new to sockets: the file descriptor `fd` is the app's end of the
/// connection. A dispatch read source calls `readAvailable` on our private queue whenever there is
/// something to read, including "the other side hung up" (a read of 0 bytes). While a request is
/// held that is the only thing that can come, so it tells us the helper went away.
final class HookConnection: HookReplying, @unchecked Sendable {
    let peerPID: pid_t?
    private let fd: Int32
    private let idleLimit: Duration
    private let onRequest: HookSocket.Handler
    private let queue = DispatchQueue(label: "dev.roosa.Singularity.hook-connection")

    // Only touched on `queue`.
    private enum Phase { case reading, held, finished }
    private var phase = Phase.reading
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?

    // Touched from any thread (the inbox sets the handler on the main actor while `queue` may be
    // noticing the helper leave), so guarded by `lock`.
    private let lock = NSLock()
    private var closedHandler: (@Sendable () -> Void)?
    private var peerLeft = false
    private var peerLeftReported = false
    private var replied = false
    private var acknowledged = false

    fileprivate init(fd: Int32, idleLimit: Duration, onRequest: @escaping HookSocket.Handler) {
        self.fd = fd
        self.idleLimit = idleLimit
        self.onRequest = onRequest
        // The process that connected (the kernel records it for Unix sockets). The inbox checks it
        // runs inside the tab's shell.
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 {
            peerPID = pid
        } else {
            peerPID = nil
        }
    }

    func acknowledge() {
        let first = lock.withLock {
            defer { acknowledged = true }
            return !acknowledged && !replied
        }
        guard first else { return }
        queue.async {
            guard self.phase == .held else { return }
            // One byte into an empty socket buffer: a non-blocking write cannot come up short.
            var byte = ClaudeHook.ack
            _ = write(self.fd, &byte, 1)
        }
    }

    var onClosedByPeer: (@Sendable () -> Void)? {
        get { lock.withLock { closedHandler } }
        set {
            let callNow: (@Sendable () -> Void)? = lock.withLock {
                if peerLeft {
                    guard !peerLeftReported, !replied, let newValue else { return nil }
                    peerLeftReported = true
                    return newValue
                }
                closedHandler = newValue
                return nil
            }
            callNow?()
        }
    }

    func reply(_ data: Data) {
        let first = lock.withLock {
            defer { replied = true }
            return !replied
        }
        guard first else { return }
        queue.async { self.writeAndClose(data) }
    }

    // MARK: On `queue`

    fileprivate func start() {
        queue.async { [self] in
            // Non-blocking: a read returns at once with what is there (or EAGAIN), so one
            // connection never waits inside the queue.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            // A descriptor watched by a dispatch source may only be closed once the source is
            // cancelled, so closing happens here (see `finish`).
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source

            let timer = DispatchSource.makeTimerSource(queue: queue)
            let limit = idleLimit.components
            let nanoseconds = Int(limit.seconds) * 1_000_000_000 + Int(limit.attoseconds / 1_000_000_000)
            timer.schedule(deadline: .now() + .nanoseconds(nanoseconds))
            timer.setEventHandler { [self] in
                // Still no whole line: drop it. Closing without a reply is "no decision".
                if phase == .reading { finish() }
            }
            idleTimer = timer
            timer.resume()
            source.resume()
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while phase != .finished {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                // While held, anything more is not part of the protocol: read and forget it.
                guard phase == .reading else { continue }
                buffer.append(contentsOf: chunk[0..<count])
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer = Data()
                    lineArrived(line)
                } else if buffer.count > ClaudeHook.maxWireBytes {
                    finish()   // longer than any real hook call: drop it without reading the rest
                }
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }   // all read for now
            if count < 0, errno == EINTR { continue }
            // 0: the helper hung up; < 0: the connection broke. Either way it is gone.
            let wasHeld = phase == .held
            finish()
            if wasHeld { peerHasLeft() }
            return
        }
    }

    private func lineArrived(_ line: Data) {
        idleTimer?.cancel()
        idleTimer = nil
        guard line.count <= ClaudeHook.maxWireBytes, let request = ClaudeHook.parseWireLine(line) else {
            finish()   // not a request we understand: no decision
            return
        }
        phase = .held
        onRequest(request.tabID, request.hookInput, self)
    }

    private func writeAndClose(_ data: Data) {
        guard phase != .finished else { return }   // the helper is gone (and the descriptor closed)
        if !data.isEmpty {
            // Back to blocking for the write, with a time limit, so a helper that stopped reading
            // cannot hold this queue for long.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            data.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let written = write(fd, pointer, left)
                    if written < 0, errno == EINTR { continue }
                    if written <= 0 { return }
                    pointer += written
                    left -= written
                }
            }
        }
        finish()
    }

    /// Ends the connection: no more reading, the descriptor is closed (in the cancel handler).
    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        idleTimer?.cancel()
        idleTimer = nil
        source?.cancel()
        source = nil
    }

    private func peerHasLeft() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            peerLeft = true
            guard !replied, !peerLeftReported, let closedHandler else { return nil }
            peerLeftReported = true
            self.closedHandler = nil
            return closedHandler
        }
        handler?()
    }
}
