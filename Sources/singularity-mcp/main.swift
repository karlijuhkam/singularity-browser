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

/// "/x/Singularity.app/Contents/MacOS/singularity-mcp" -> "/x/Singularity.app".
/// Returns nil when the path is not inside an .app bundle's Contents/MacOS folder.
func appBundle(forLauncherAt path: String) -> String? {
    let macOS = URL(fileURLWithPath: path).deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let bundle = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS",
          contents.lastPathComponent == "Contents",
          bundle.pathExtension == "app" else { return nil }
    return bundle.path
}

/// Arguments for /usr/bin/open: start the bundle this launcher lives in. Several bundles can share
/// the bundle ID (an installed copy, a development copy), so the ID alone is only the fallback.
func openArguments(launcherPath: String) -> [String] {
    if let bundle = appBundle(forLauncherAt: launcherPath) { return ["-g", bundle] }
    return ["-g", "-b", "dev.roosa.Singularity"]
}

/// True while Sparkle's installer process is running (exit code of pgrep only).
func updateInstallerRunning() -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "Autoupdate"]
    pgrep.standardOutput = FileHandle.nullDevice
    pgrep.standardError = FileHandle.nullDevice
    guard (try? pgrep.run()) != nil else { return false }
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0
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
    // The real location of this executable (symlinks resolved), so we start our own bundle.
    // realpath(3) rather than Foundation's resolvingSymlinksInPath, which rewrites /private/tmp to /tmp.
    let launcherPath = Bundle.main.executableURL.flatMap { realpath($0.path, nil) }
        .map { pointer in defer { free(pointer) }; return String(cString: pointer) }
        ?? CommandLine.arguments[0]

    // Dry run for tests: say what we would start, and do nothing else. Checked first so that no
    // socket is touched and no process (open, pgrep) is started.
    if ProcessInfo.processInfo.environment["SINGULARITY_MCP_DRY_RUN"] == "1" {
        print((["open"] + openArguments(launcherPath: launcherPath)).joined(separator: " "))
        return 0
    }

    let path = socketPath()
    var connection = connectToApp(path)

    if connection == nil {
        // Mid-update: while Sparkle's installer (Autoupdate) replaces the bundle, it relaunches the
        // app itself. Starting a copy now would collide with that one on the instance lock, so wait
        // (up to 60 s) for the socket of the relaunched app before falling through to open.
        var waited = 0
        while connection == nil, waited < 240, updateInstallerRunning() {
            usleep(250_000)
            waited += 1
            connection = connectToApp(path)
        }
    }

    if connection == nil {
        // Start the app we live in without bringing it to the front, then wait up to 15 s for its socket.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = openArguments(launcherPath: launcherPath)
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
