import Foundation

/// The coding agents that get a Connect button (onboarding and Settings → Agents).
public enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode, codex

    /// The name shown to the user.
    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The command-line program the user has installed.
    public var program: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }
}

/// What an agent's row shows.
public enum AgentConnectStatus: Equatable, Sendable {
    case separateDataFolder    // this copy has its own data folder (SINGULARITY_HOME): no button
    case translocated          // app runs from a temporary path: no button
    case notInstalled          // agent not found: show the command to copy
    case notConnected          // Connect button
    case connected             // registered == launcher
    case otherCopy(String)     // registered elsewhere (the path): Update button
}

/// The pure part of connecting an agent to Singularity: the shell commands the app runs (through
/// the user's login shell) and reading where the agent's existing entry points. Reading the config
/// file, rather than asking the agent (`claude mcp get`), matters: asking health-checks the entry,
/// which would start the registered `singularity-mcp` and possibly another copy of the app.
/// The config files are only ever read here; changes go through the agents' own `mcp add/remove`.
public enum AgentConnect {
    /// The MCP server name Singularity is registered under in both agents.
    public static let serverName = "singularity"

    /// POSIX single-quote quoting: abc → 'abc', it's → 'it'\''s'.
    /// Inside single quotes the shell treats every character literally except the closing quote,
    /// so each ' is written as: close quote, escaped quote, open quote.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True for a path macOS made by translocation (contains "/AppTranslocation/"): an app opened
    /// straight from a download runs from a random read-only path that changes on every launch,
    /// so registering it with an agent would break next time.
    public static func isTranslocated(_ launcherPath: String) -> Bool {
        launcherPath.contains("/AppTranslocation/")
    }

    /// claude: `claude mcp add -s user singularity -- '<launcher>'`
    /// codex:  `codex mcp add singularity -- '<launcher>'`
    public static func addCommand(_ agent: AgentKind, launcher: String) -> String {
        switch agent {
        case .claudeCode: return "claude mcp add -s user \(serverName) -- \(shellQuote(launcher))"
        case .codex: return "codex mcp add \(serverName) -- \(shellQuote(launcher))"
        }
    }

    /// claude: `claude mcp remove -s user singularity`; codex: `codex mcp remove singularity`
    public static func removeCommand(_ agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: return "claude mcp remove -s user \(serverName)"
        case .codex: return "codex mcp remove \(serverName)"
        }
    }

    /// `command -v <program>` (run through the login shell; exit 0 = installed).
    public static func findCommand(_ agent: AgentKind) -> String {
        "command -v \(agent.program)"
    }

    /// The config file that holds the user-wide entry: ~/.claude.json, ~/.codex/config.toml.
    public static func configFile(_ agent: AgentKind, home: URL) -> URL {
        switch agent {
        case .claudeCode: return home.appendingPathComponent(".claude.json")
        case .codex: return home.appendingPathComponent(".codex").appendingPathComponent("config.toml")
        }
    }

    /// The command registered for the server named "singularity", or nil when there is none
    /// or the text can't be read as expected. Never throws.
    public static func registeredLauncher(_ agent: AgentKind, configText: String) -> String? {
        let command: String?
        switch agent {
        case .claudeCode: command = claudeLauncher(configText)
        case .codex: command = codexLauncher(configText)
        }
        guard let command, !command.isEmpty else { return nil }
        return command
    }

    /// Combines the facts into what the row shows. An existing entry is reported even when the
    /// program wasn't found (it may just not be on the login shell's PATH).
    ///
    /// A copy with its own data folder (a development copy) never offers to change the agents' setup:
    /// that setup belongs to the owner's real copy, so this check comes first.
    public static func status(installed: Bool, registered: String?, launcher: String,
                              separateDataFolder: Bool = false) -> AgentConnectStatus {
        if separateDataFolder { return .separateDataFolder }
        if isTranslocated(launcher) { return .translocated }
        if let registered {
            return standardized(registered) == standardized(launcher) ? .connected : .otherCopy(registered)
        }
        return installed ? .notConnected : .notInstalled
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Claude Code: ~/.claude.json

    /// The user-scope entry is top-level `mcpServers.singularity.command`. Per-project entries
    /// (under `projects.<path>.mcpServers`) are ignored on purpose.
    private static func claudeLauncher(_ text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = object as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any]
        else { return nil }
        return entry["command"] as? String
    }

    // MARK: - Codex: ~/.codex/config.toml

    /// A small line scanner, not a TOML parser. It understands the two shapes an entry takes:
    ///
    ///     [mcp_servers.singularity]          (also [mcp_servers."singularity"])
    ///     command = "/path/singularity-mcp"
    ///
    ///     [mcp_servers]
    ///     singularity = { command = "/path/singularity-mcp", args = [] }
    ///
    /// Anything else (multi-line strings, dotted keys) reads as "no entry".
    private static func codexLauncher(_ text: String) -> String? {
        enum Section { case singularity, mcpServers, other }
        var section = Section.other

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                section = .other
                // "[[x]]" is an array of tables: never ours.
                guard !line.hasPrefix("[["), let close = line.firstIndex(of: "]") else { continue }
                // Drop spaces and quotes so `[ mcp_servers."singularity" ]` reads as mcp_servers.singularity.
                let name = line[line.index(after: line.startIndex)..<close]
                    .filter { $0 != " " && $0 != "\t" && $0 != "\"" && $0 != "'" }
                if name == "mcp_servers.\(serverName)" { section = .singularity }
                if name == "mcp_servers" { section = .mcpServers }
                continue
            }

            switch section {
            case .singularity:
                if let value = valueAfterKey("command", in: Substring(line)) {
                    return quotedString(value)
                }
            case .mcpServers:
                guard let value = valueAfterKey(serverName, in: Substring(line))
                        ?? valueAfterKey("\"\(serverName)\"", in: Substring(line)),
                      value.hasPrefix("{") else { continue }
                return inlineCommand(value.dropFirst())
            case .other:
                continue
            }
        }
        return nil
    }

    /// For `key = value`, the text after `=` with leading blanks removed; nil when the line
    /// sets some other key.
    private static func valueAfterKey(_ key: String, in line: Substring) -> Substring? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard rest.first == "=" else { return nil }
        return rest.dropFirst().drop { $0 == " " || $0 == "\t" }
    }

    /// The `command` value inside an inline table body (the text after `{`). Walks key = value
    /// pairs so a "command" inside some other value's string is not mistaken for the key.
    private static func inlineCommand(_ body: Substring) -> String? {
        var rest = body
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "," }
            if rest.isEmpty || rest.first == "}" { return nil }
            if let value = valueAfterKey("command", in: rest) {
                return quotedString(value)
            }
            // Skip this pair: up to the next comma that is outside strings and brackets.
            // Each round must move forward, or a damaged file could make this loop forever.
            guard let next = afterValue(rest), next.startIndex > rest.startIndex else { return nil }
            rest = next
        }
    }

    /// The text after the current `key = value` pair's value, or nil when the text is damaged
    /// (a string never ends, or a `]` closes nothing).
    private static func afterValue(_ text: Substring) -> Substring? {
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if let open = quote {
                if escaped { escaped = false }
                else if char == "\\" && open == "\"" { escaped = true }
                else if char == open { quote = nil }
            } else {
                switch char {
                case "\"", "'": quote = char
                case "[", "{": depth += 1
                case "]", "}":
                    if depth == 0 {
                        // "}" ends the inline table; a "]" with nothing open is damage.
                        return char == "}" ? text[index...] : nil
                    }
                    depth -= 1
                case ",":
                    if depth == 0 { return text[text.index(after: index)...] }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return quote == nil ? text[text.endIndex...] : nil
    }

    /// Reads a TOML string at the start of `text`: '…' is literal, "…" unescapes \" and \\
    /// (other escapes are kept as written; launcher paths don't use them). Nil when `text`
    /// doesn't start with a quote or the string never ends.
    private static func quotedString(_ text: Substring) -> String? {
        guard let open = text.first, open == "\"" || open == "'" else { return nil }
        var result = ""
        var escaped = false
        for char in text.dropFirst() {
            if escaped {
                if char != "\"" && char != "\\" { result.append("\\") }
                result.append(char)
                escaped = false
            } else if char == "\\" && open == "\"" {
                escaped = true
            } else if char == open {
                return result
            } else {
                result.append(char)
            }
        }
        return nil
    }
}
