// singularity-mcp: the MCP server command an agent (e.g. Claude Code) starts.
//
// It contains no MCP logic. It connects to the running Singularity app over a Unix domain socket
// and copies bytes both ways: its stdin → app, app → its stdout. The app speaks MCP on the socket.
// If the app isn't running, it starts it (in the background) and waits for the socket.
//
// Register with Claude Code:
//   claude mcp add singularity -- /Applications/Singularity.app/Contents/MacOS/singularity-mcp

import Darwin
import Foundation

func socketPath() -> String {
    ProcessInfo.processInfo.environment["SINGULARITY_MCP_SOCKET"]
        ?? (NSHomeDirectory() + "/Singularity/.run/mcp.sock")
}

/// Connects to the app's socket, or returns nil if nobody is listening.
func connectToApp(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        return nil
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Copies everything from one file descriptor to another until end of input or an error.
func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(source, &buffer, buffer.count)
        if count <= 0 { return }
        var offset = 0
        while offset < count {
            let written = buffer[offset..<count].withUnsafeBytes { write(destination, $0.baseAddress, count - offset) }
            if written <= 0 { return }
            offset += written
        }
    }
}

func run() -> Int32 {
    let path = socketPath()
    var connection = connectToApp(path)

    if connection == nil {
        // Start the app without bringing it to the front, then wait up to 15 s for its socket.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-g", "-b", "dev.roosa.Singularity"]
        try? opener.run()
        opener.waitUntilExit()
        for _ in 0..<60 where connection == nil {
            usleep(250_000)
            connection = connectToApp(path)
        }
    }
    guard let fd = connection else {
        FileHandle.standardError.write(Data("singularity-mcp: could not reach Singularity at \(path). Is the app installed?\n".utf8))
        return 1
    }

    signal(SIGPIPE, SIG_IGN) // a closed pipe should end the copy loop, not kill the process
    let inbound = Thread {
        pump(from: STDIN_FILENO, to: fd)
        shutdown(fd, SHUT_WR) // agent closed stdin: tell the app we're done sending
    }
    inbound.start()
    pump(from: fd, to: STDOUT_FILENO) // returns when the app closes the connection
    return 0
}

exit(run())
