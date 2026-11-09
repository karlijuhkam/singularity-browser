import Foundation

/// Which programs a plugin may ask Singularity to run, and with which arguments.
public enum CommandPolicy {
    /// General-purpose programs that would make the plugin sandbox pointless
    /// (shells, interpreters, network tools, `open`, `osascript`...). Refused at install.
    public static let refused: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "env", "sudo", "su",
        "curl", "wget", "ssh", "scp", "sftp", "nc", "ncat", "telnet", "ftp", "rsync",
        "osascript", "open", "python", "python3", "perl", "ruby", "php", "node", "bun",
        "deno", "npx", "bunx",
        "rbash", "nodejs", "pip", "pip3", "npm", "pnpm", "yarn", "xargs", "nice", "nohup", "exec",
        "command", "launchctl", "swift", "lua", "awk", "gawk", "tclsh", "expect",
    ]

    /// True when the name, lowercased, is refused, or becomes refused after dropping a version
    /// suffix ("python3.12", "zsh-5.9", "perl5.34" reduce to "python", "zsh", "perl").
    public static func isRefused(_ name: String) -> Bool {
        let lower = name.lowercased()
        if refused.contains(lower) { return true }
        var stem = Substring(lower)
        // Strip trailing digits and dots, then one optional "-" or "." before them.
        while let last = stem.last, last.isNumber || last == "." { stem.removeLast() }
        if stem.count < lower.count {
            if let last = stem.last, last == "-" || last == "." { stem.removeLast() }
            return refused.contains(String(stem))
        }
        return false
    }

    /// A command name is a bare program name: letters, digits, `.`, `_`, `-`, starting with a
    /// letter or digit (so "-c", "." and ".." are out). No slashes, no spaces.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
              first.properties.isAlphabetic || ("0"..."9").contains(Character(first)) else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))))
                || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// True when `command` is declared, not refused, and `arguments` start with one of its
    /// sub-commands, word for word (case-sensitive). "item list" allows `item list --format json`.
    public static func allows(command: String, arguments: [String], declared: [String: [String]]) -> Bool {
        guard !isRefused(command), let subcommands = declared[command] else { return false }
        for sub in subcommands {
            let words = sub.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // An empty sub-command would match every call, so it never matches.
            if !words.isEmpty, arguments.count >= words.count, Array(arguments.prefix(words.count)) == words {
                return true
            }
        }
        return false
    }
}
