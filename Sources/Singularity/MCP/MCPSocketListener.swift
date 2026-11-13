import Darwin
import Foundation

/// Listens on a Unix domain socket (a socket that is a file on disk, reachable only from this
/// Mac) and hands every accepted connection's file descriptor to `onConnection`, with the pid of
/// the process that connected (nil when the kernel can't tell).
///
/// `singularity-mcp`, the stdio launcher an agent starts, connects here. Access control is the
/// file system: the folder is 0700 and the socket 0600, so only this macOS user can connect, and
/// we double-check the connecting process's user id.
final class MCPSocketListener: @unchecked Sendable {
    private let path: String
    private let onConnection: @Sendable (Int32, pid_t?) -> Void
    private let queue = DispatchQueue(label: "dev.roosa.Singularity.mcp-listener")
    // Only touched on `queue` after start().
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, onConnection: @escaping @Sendable (Int32, pid_t?) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        chmod(folder, 0o700)
        unlink(path) // a socket file left over from a previous run (or crash)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        // A dispatch source calls us whenever the socket has connections waiting.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        self.source = source
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if listenFD >= 0 { close(listenFD) }
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return } // EAGAIN: nothing more waiting

            // Only accept processes running as the same user (belt and braces; see the 0600 above).
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            // Without this, writing to a client that has gone away would kill the app with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // The process that connected, as the kernel recorded it at connect(): the agent door
            // checks whether it descends from a plugin's own program.
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            let peer: pid_t? = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
            onConnection(client, peer)
        }
    }
}
