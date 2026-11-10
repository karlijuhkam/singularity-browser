import Darwin
import Foundation

/// Running terminal tabs through herdr-core (`hc`, github.com/herdrdev/herdr-core), the owner's
/// own installed copy. Optional (Settings → Terminal), off by default, never bundled.
///
/// What herdr-core adds: the shell belongs to herdr-core's background "holder", not to
/// Singularity. Quitting or crashing Singularity leaves it running, and opening the tab again
/// shows the same shell with its screen as it was ("first paint"). Other herdr tools see the
/// terminal too (`hc ls`, Herdr Desktop).
///
/// How Singularity uses it, with nothing of herdr-core re-implemented:
/// 1. `hc run --bg --json --name sg-<tab id> …` starts the shell as a herdr terminal (once per tab).
/// 2. The tab's terminal view runs `hc attach sg-<tab id>` where it would otherwise run the
///    login shell. `hc attach` is a plain terminal program: bytes both ways, resizes follow.
/// 3. Closing the tab ends the herdr terminal (`hc kill`, `hc rm`). Quitting the app only ends
///    `hc attach`, so the shell lives on.
///
/// herdr-core calls its interface a preview (0.x). Everything read from it is checked, and any
/// surprise falls back to the built-in terminal.
public enum HerdrCore {
    /// Where `hc` is looked for: the installer's place first, then Homebrew's, then `PATH`.
    /// (An app started from the Dock has a short `PATH` without `~/.local/bin`.)
    public static func candidatePaths(home: String, path: String?) -> [String] {
        var candidates = [home + "/.local/bin/hc", "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
        for folder in (path ?? "").split(separator: ":") where !folder.isEmpty {
            let candidate = String(folder) + "/hc"
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        return candidates
    }

    /// The installed `hc`, or nil.
    public static func locate(home: String = NSHomeDirectory(),
                              path: String? = ProcessInfo.processInfo.environment["PATH"],
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidatePaths(home: home, path: path).first(where: isExecutable)
    }

    /// "0.1.19" from `hc --version` ("hc 0.1.19").
    public static func parseVersion(_ output: String) -> String? {
        let words = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count >= 2, words[0] == "hc", words[1].first?.isNumber == true else { return nil }
        return String(words[1])
    }

    /// The herdr terminal of a tab: "sg-" and the first 24 hex digits of the tab's id. herdr
    /// names are 1–32 of a-z 0-9 - _. The same tab gets the same name after a restart, which is
    /// how it finds its shell again.
    public static func terminalName(tabID: UUID) -> String {
        "sg-" + String(tabID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(24))
    }

    /// Arguments for `hc run`: a login shell in `directory`, labelled as Singularity's.
    ///
    /// herdr-core starts programs with its own environment, not the caller's, so the Space's
    /// name travels through `/usr/bin/env` (agents in the terminal read SINGULARITY_SPACE to
    /// know which browser tools are theirs). `--no-parent`: when Singularity itself was started
    /// from a herdr terminal, the tab must not become that terminal's child and end with it.
    public static func runArguments(name: String, directory: String, spaceSlug: String, shell: String) -> [String] {
        ["run", "--bg", "--json", "--no-parent", "--no-notify", "--name", name, "--cwd", directory,
         "--label", "app=singularity", "--label", "space=" + spaceSlug,
         "--", "/usr/bin/env", "SINGULARITY_SPACE=" + spaceSlug, shell, "-l"]
    }

    /// Arguments for `hc attach`, with some scrollback so a re-opened tab isn't a bare screen.
    public static func attachArguments(name: String) -> [String] {
        ["attach", name, "--history", "2000"]
    }

    /// What `hc get <name> --json` says about a terminal.
    public struct Terminal: Equatable, Sendable {
        public enum State: Equatable, Sendable { case live, finished, other(String) }
        public var state: State
        /// The shell's process id on this Mac (for its current directory and foreground program).
        public var pid: pid_t?
        public var exitCode: Int32?
    }

    public enum Lookup: Equatable, Sendable {
        case found(Terminal)
        /// herdr-core has no terminal of that name.
        case missing
        /// Not understood (a newer herdr-core, or an error of another kind).
        case unreadable(String)
    }

    public static func parseGet(_ output: String) -> Lookup {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            return .unreadable("hc gave no JSON")
        }
        if let error = object["error"] as? [String: Any] {
            if error["kind"] as? String == "not_found" { return .missing }
            return .unreadable(error["message"] as? String ?? "hc reported an error")
        }
        guard let state = object["state"] as? String else { return .unreadable("hc's answer has no state") }
        let parsed: Terminal.State = state == "live" ? .live : (state == "finished" ? .finished : .other(state))
        let pid = (object["pid"] as? Int).flatMap { $0 > 0 ? pid_t(exactly: $0) : nil }
        let exitCode = (object["exit_code"] as? Int).flatMap { Int32(exactly: $0) }
        return .found(Terminal(state: parsed, pid: pid, exitCode: exitCode))
    }

    /// The message of an `{"error": …}` answer, for showing to the owner.
    public static func errorMessage(_ output: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

extension ProcessInspector {
    /// The foreground process group of the terminal that process `pid` sits in, asked of the
    /// kernel by process id. For terminals whose PTY another program owns (herdr-core), where
    /// there is no file descriptor to ask with `tcgetpgrp`.
    public static func foregroundProcessGroup(ofTerminalOf pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // e_tpgid: "tty process group id". 0 when the process has no terminal.
        let group = pid_t(info.e_tpgid)
        return group > 0 ? group : nil
    }
}
