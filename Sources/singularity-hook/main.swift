// singularity-hook: the command Claude Code runs as a hook (PreToolUse for AskUserQuestion,
// PermissionRequest, Stop). It hands the hook's input to the running Singularity app, which shows
// the question or request in its inbox, and prints the app's reply as the hook's output.
//
// It is installed for every Claude Code session the owner starts, so outside a Singularity
// terminal tab (or with Singularity not running) it must do nothing at all: no output (stdout or
// stderr), exit status 0, at once. Empty output with status 0 is "no decision" to Claude Code,
// which then shows its own prompt. In order:
//
//   1. SINGULARITY_TAB (the tab's id) and SINGULARITY_HOOK_SOCKET (the app's socket) are set by
//      Singularity's terminal tabs. Either missing: exit.
//   2. Connect to the socket. Nobody listening (app not running, or a socket file left behind
//      by a crash) fails at once: exit. It never starts the app.
//   3. Read the hook input from stdin (at most ClaudeHook.maxWireBytes; more: exit) and send it
//      as one line: {"hook":<input>,"tab":"<id>"}.
//   4. Wait for the reply until the app closes the connection, and write it to stdout unchanged.
//      The app closing without a reply = empty output = no decision.
//
// No dependencies (not even SingularityCore), so it starts quickly; the few lines of the wire
// format are copied from ClaudeHook.wireLine (see `wireLine` below).

import Darwin
import Foundation

/// Same value as `ClaudeHook.maxWireBytes` in SingularityCore.
let maxWireBytes = 2_000_000

/// Connects to the app's socket, or returns nil (no socket file, nobody listening, path too long).
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

/// Reads `fd` to its end. Nil when it holds more than `limit` bytes (or `limit` is nil: no limit).
func readAll(_ fd: Int32, limit: Int?) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { return data }
        if count < 0 {
            if errno == EINTR { continue }
            return data
        }
        data.append(contentsOf: buffer[0..<count])
        if let limit, data.count > limit { return nil }
    }
}

/// Writes all of `data`; false if the other side went away.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard var pointer = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let written = write(fd, pointer, left)
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            pointer += written
            left -= written
        }
        return true
    }
}

/// `{"hook":<hook input>,"tab":"<id>"}` plus a newline: keys sorted, slashes not escaped, the hook
/// input re-serialised so the line has no other newline; input that is not JSON is sent as `{}`.
///
/// A copy of `ClaudeHook.wireLine` (SingularityCore), which the app reads with
/// `ClaudeHook.parseWireLine`. Keep the two identical: the Core test `wireLineFormatIsPinned`
/// fixes the format, and the app test `helperSendsTheSameLineAsCore` compares this helper's real
/// output with `ClaudeHook.wireLine`.
func wireLine(tabID: String, hookInput: Data) -> Data {
    let hook = (try? JSONSerialization.jsonObject(with: hookInput, options: [.fragmentsAllowed])) ?? [String: Any]()
    let root: [String: Any] = ["tab": tabID, "hook": hook]
    var data = Data("{}".utf8)
    // `data(withJSONObject:)` traps on anything it cannot write, so ask first.
    if JSONSerialization.isValidJSONObject(root),
       let line = try? JSONSerialization.data(withJSONObject: root,
                                              options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
        data = line
    }
    data.append(0x0A)
    return data
}

func run() {
    // A reader that went away (Claude Code, or the app) must end us quietly, not by SIGPIPE.
    signal(SIGPIPE, SIG_IGN)

    let environment = ProcessInfo.processInfo.environment
    guard let tab = environment["SINGULARITY_TAB"], !tab.isEmpty,
          let path = environment["SINGULARITY_HOOK_SOCKET"], !path.isEmpty else { return }
    guard let fd = connectToApp(path) else { return }

    guard let input = readAll(STDIN_FILENO, limit: maxWireBytes) else { return }
    let line = wireLine(tabID: tab, hookInput: input)
    guard line.count <= maxWireBytes, writeAll(fd, line) else { return }
    // The write side stays open on purpose (no shutdown(SHUT_WR)): the app learns that Claude Code
    // gave up (it kills this process on Esc or Ctrl-C) from the connection closing, and macOS
    // reports a half-closed connection exactly like a closed one. The line's newline is its end.

    guard let reply = readAll(fd, limit: nil), !reply.isEmpty else { return }
    _ = writeAll(STDOUT_FILENO, reply)
}

run()
exit(0)
