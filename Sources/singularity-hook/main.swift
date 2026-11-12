// singularity-hook: the command Claude Code runs as a hook (PreToolUse for AskUserQuestion,
// PermissionRequest, Stop). It hands the hook's input to the running Singularity app, which shows
// the question or request in its inbox, and prints the app's reply as the hook's output.
//
// It is installed for every Claude Code session the owner starts, so outside a Singularity
// terminal tab (or with Singularity not running) it must do nothing at all: no output (stdout or
// stderr), exit status 0, at once. Empty output with status 0 is "no decision" to Claude Code,
// which then shows its own prompt. In order:
//
//   1. Read all of stdin, the hook input. Always to its end, even when it is not used: a hook that
//      exits while Claude Code is still writing (input over the pipe's ~64 KB) makes Claude Code
//      report a failed hook. Over ClaudeHook.maxWireBytes the input is read and thrown away.
//   2. SINGULARITY_TAB (the tab's id) and SINGULARITY_HOOK_SOCKET (the app's socket) are set by
//      Singularity's terminal tabs. Either missing, or the input too long: exit.
//   3. Connect to the socket. Nobody listening (app not running, or a socket file left behind
//      by a crash) fails at once: exit. It never starts the app.
//   4. Send the input as one line: {"hook":<input>,"tab":"<id>"}.
//   5. Wait up to 5 s for the app's acknowledgement byte (ClaudeHook.ack), written from its main
//      thread: none (the app is stuck) or anything else: exit.
//   6. Wait for the reply until the app closes the connection, and write it to stdout unchanged
//      (without the acknowledgement byte). The app closing without a reply = no decision.
//
// No dependencies (not even SingularityCore), so it starts quickly; the few lines of the wire
// format are copied from ClaudeHook.wireLine (see `wireLine` below).

import Darwin
import Foundation

/// Same value as `ClaudeHook.maxWireBytes` in SingularityCore.
let maxWireBytes = 2_000_000
/// Same value as `ClaudeHook.ack` in SingularityCore (pinned by `wireLineFormatIsPinned`).
let ackByte: UInt8 = 0x06
/// How long the app has to acknowledge a request.
let ackWaitMilliseconds = 5_000

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

/// Reads `fd` to its end, always. Nil when it held more than `limit` bytes (the rest was read and
/// thrown away); `limit` nil: no limit.
func readAll(_ fd: Int32, limit: Int?) -> Data? {
    var data = Data()
    var tooLong = false
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            break
        }
        if tooLong { continue }
        data.append(contentsOf: buffer[0..<count])
        if let limit, data.count > limit {
            tooLong = true
            data = Data()
        }
    }
    return tooLong ? nil : data
}

/// Waits up to `ackWaitMilliseconds` for the app's acknowledgement byte. False: none came in
/// time, the app hung up, or it sent something else.
func receivedAck(_ fd: Int32) -> Bool {
    var waitFor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(ackWaitMilliseconds) * 1_000_000
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return false }
        let ready = poll(&waitFor, 1, Int32((deadline - now) / 1_000_000) + 1)
        if ready < 0, errno == EINTR { continue }
        guard ready > 0 else { return false }
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        if count < 0, errno == EINTR { continue }
        return count == 1 && byte == ackByte
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

    // First, whatever happens next: Claude Code must be able to write all of its input.
    let input = readAll(STDIN_FILENO, limit: maxWireBytes)

    let environment = ProcessInfo.processInfo.environment
    guard let input,
          let tab = environment["SINGULARITY_TAB"], !tab.isEmpty,
          let path = environment["SINGULARITY_HOOK_SOCKET"], !path.isEmpty else { return }
    guard let fd = connectToApp(path) else { return }

    let line = wireLine(tabID: tab, hookInput: input)
    guard line.count <= maxWireBytes, writeAll(fd, line) else { return }
    // The write side stays open on purpose (no shutdown(SHUT_WR)): the app learns that Claude Code
    // gave up (it kills this process on Esc or Ctrl-C) from the connection closing, and macOS
    // reports a half-closed connection exactly like a closed one. The line's newline is its end.

    guard receivedAck(fd) else { return }
    guard let reply = readAll(fd, limit: nil), !reply.isEmpty else { return }
    _ = writeAll(STDOUT_FILENO, reply)
}

run()
exit(0)
