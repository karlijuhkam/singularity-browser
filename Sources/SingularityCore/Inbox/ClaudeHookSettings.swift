import Foundation

/// Adds, finds and removes Singularity's three hook entries in the text of Claude Code's
/// `~/.claude/settings.json`. Text in, text out: no file access here.
///
/// The file belongs to the owner and to another program, so the rules are strict:
/// - Everything that is not our hook stays as it was (values, order of arrays; key order and
///   spacing may change, because the file is written out again, sorted and pretty-printed).
/// - A file we don't fully understand is refused (`Unreadable`), never rewritten.
///
/// How values survive: the text is first checked with `JSONText` (strict: no comments, no
/// trailing commas, no duplicate keys), then read with `JSONSerialization`, which keeps integers
/// of any size exactly, `true`/`false` as booleans and `null`. What changes when the file is
/// written out again (all the same value, different spelling): key order (sorted) and spacing;
/// some doubles get 17 significant digits (`3.141592653589793` becomes `3.1415926535897931`);
/// exponents are written `e+100`, `1e3` becomes `1000`, `1.0` becomes `1`, `-0` becomes `0`;
/// string escapes are normalised (`\/` becomes `/`, `\u00e9` becomes `é`).
public enum ClaudeHookSettings {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// Our hooks, pointing at another helper path (the path as stored, unquoted).
        case otherCopy(String)
        /// Not a JSON object, or `hooks` has a shape we don't understand.
        case unreadable
    }

    public struct Unreadable: Error {}

    public static let helperName = "singularity-hook"

    /// The question hook, the permission hook and the end-of-turn hook.
    static let askEvent = "PreToolUse"
    static let permissionEvent = "PermissionRequest"
    static let stopEvent = "Stop"
    static let askMatcher = "AskUserQuestion"
    static let stopTimeoutSeconds = 10

    public static func file(home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Public operations

    /// `settingsText` nil = no file. Empty text counts as no file.
    /// `.installed` means all three entries are exactly what `install` would write for this
    /// helper and timeout (right matcher, right timeout, nothing of ours elsewhere). Ours with
    /// this helper but not exactly right, or only some of the three: `.notInstalled` (install
    /// repairs it). Ours pointing at another helper: `.otherCopy`.
    public static func status(settingsText: String?, helper: String, timeoutSeconds: Int) -> Status {
        guard let root = try? load(settingsText) else { return .unreadable }
        let events = (root["hooks"] as? [String: Any]) ?? [:]
        for name in events.keys.sorted() {
            for hook in allHooks(in: events[name]) {
                if let path = ourPath(hook), path != helper { return .otherCopy(path) }
            }
        }
        let outsideThree = events.contains { name, value in
            ![askEvent, permissionEvent, stopEvent].contains(name)
                && allHooks(in: value).contains { ourPath($0) != nil }
        }
        if outsideThree { return .notInstalled }
        let exact = wanted(timeoutSeconds).allSatisfy { item in
            alreadyInPlace(events[item.event] as? [Any] ?? [],
                           hook: makeHook(helper: helper, timeout: item.timeout), matcher: item.matcher)
        }
        return exact ? .installed : .notInstalled
    }

    /// The three entries: event, matcher, timeout.
    private static func wanted(_ timeoutSeconds: Int) -> [(event: String, matcher: String?, timeout: Int)] {
        [(askEvent, askMatcher, timeoutSeconds),
         (permissionEvent, nil, timeoutSeconds),
         (stopEvent, nil, stopTimeoutSeconds)]
    }

    /// Adds (or repoints) our three entries; everything else is kept.
    public static func install(settingsText: String?, helper: String, timeoutSeconds: Int) throws -> String {
        guard var root = try? load(settingsText) else { throw Unreadable() }
        var events = (root["hooks"] as? [String: Any]) ?? [:]
        for item in wanted(timeoutSeconds) {
            let hook = makeHook(helper: helper, timeout: item.timeout)
            var groups = (events[item.event] as? [Any]) ?? []
            if alreadyInPlace(groups, hook: hook, matcher: item.matcher) { continue }
            // Otherwise: take all of ours out, then add one fresh group at the end.
            groups = removingOurs(from: groups).groups
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = item.matcher { group["matcher"] = matcher }
            groups.append(group)
            events[item.event] = groups
        }
        // Old entries of ours under other event names (not written by us, but harmless to clear).
        for name in Array(events.keys) where ![askEvent, permissionEvent, stopEvent].contains(name) {
            let cleaned = removingOurs(from: events[name] as? [Any] ?? [])
            if cleaned.changed { events[name] = cleaned.groups.isEmpty ? nil : cleaned.groups }
        }
        root["hooks"] = events
        return try write(root)
    }

    /// Removes our entries (any helper path). No hooks of ours: the text is returned unchanged.
    public static func remove(settingsText: String) throws -> String {
        guard var root = try? load(settingsText) else { throw Unreadable() }
        guard var events = root["hooks"] as? [String: Any] else { return settingsText }
        var changed = false
        for name in events.keys {
            let cleaned = removingOurs(from: events[name] as? [Any] ?? [])
            guard cleaned.changed else { continue }
            changed = true
            events[name] = cleaned.groups.isEmpty ? nil : cleaned.groups
        }
        guard changed else { return settingsText }
        root["hooks"] = events.isEmpty ? nil : events
        return try write(root)
    }

    // MARK: - Reading

    /// Parses the file into its top-level object, after checking the shape of `hooks`.
    /// Nil text and blank text give an empty object.
    private static func load(_ text: String?) throws -> [String: Any] {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return [:] }
        let data = Data(text.utf8)
        // Strict check first: JSONSerialization would accept some things we want to refuse.
        guard case .object = try? JSONText.parse(data) else { throw Unreadable() }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unreadable() }
        if let hooks = root["hooks"] {
            guard let events = hooks as? [String: Any] else { throw Unreadable() }
            for value in events.values {
                guard let groups = value as? [Any] else { throw Unreadable() }
                for group in groups {
                    guard let group = group as? [String: Any] else { throw Unreadable() }
                    guard let inner = group["hooks"] else { continue }
                    guard let list = inner as? [Any] else { throw Unreadable() }
                    for hook in list where !(hook is [String: Any]) { throw Unreadable() }
                }
            }
        }
        return root
    }

    private static func write(_ root: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { throw Unreadable() }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Our hooks

    private static func makeHook(helper: String, timeout: Int) -> [String: Any] {
        ["type": "command", "command": AgentConnect.shellQuote(helper), "timeout": timeout]
    }

    /// The hooks of every group of one event (the shape was checked in `load`).
    private static func allHooks(in event: Any?) -> [[String: Any]] {
        guard let groups = event as? [Any] else { return [] }
        return groups.flatMap { (($0 as? [String: Any])?["hooks"] as? [Any]) ?? [] }.compactMap { $0 as? [String: Any] }
    }

    /// The helper path when this hook is one of ours: a command hook whose command, unquoted,
    /// ends in `singularity-hook`.
    private static func ourPath(_ hook: [String: Any]) -> String? {
        guard hook["type"] as? String == "command", let command = hook["command"] as? String else { return nil }
        let path = unquote(command)
        return path.split(separator: "/").last.map(String.init) == helperName ? path : nil
    }

    /// The first word of a shell command with its quoting removed: the inverse of
    /// `AgentConnect.shellQuote` (`'it'\''s'` gives `it's`), and also hand-written double quotes
    /// (inside them a backslash escapes only `"`, `\`, `$` and a backtick, as in a shell).
    /// Stops at unquoted whitespace.
    static func unquote(_ command: String) -> String {
        var out = ""
        var quote: Character?          // the quote character we are inside, if any
        var escaped = false            // the previous character was an unquoted backslash
        var pendingBackslash = false   // inside double quotes: a backslash was just seen
        for ch in command {
            if escaped { out.append(ch); escaped = false; continue }
            if quote == "'" {
                if ch == "'" { quote = nil } else { out.append(ch) }
            } else if quote == "\"" {
                if pendingBackslash {
                    pendingBackslash = false
                    if !"\"\\$`".contains(ch) { out.append("\\") }
                    out.append(ch)
                } else if ch == "\\" { pendingBackslash = true }
                else if ch == "\"" { quote = nil }
                else { out.append(ch) }
            } else if ch == "'" || ch == "\"" { quote = ch }
            else if ch == "\\" { escaped = true }
            else if ch.isWhitespace { break }
            else { out.append(ch) }
        }
        return out
    }

    /// True when the event already holds exactly one hook of ours, equal to `hook`, in a group
    /// with the right matcher. Then install leaves the event alone (nothing moves or duplicates).
    private static func alreadyInPlace(_ groups: [Any], hook: [String: Any], matcher: String?) -> Bool {
        var found = 0
        var good = false
        for case let group as [String: Any] in groups {
            for case let candidate as [String: Any] in (group["hooks"] as? [Any]) ?? [] where ourPath(candidate) != nil {
                found += 1
                good = (candidate as NSDictionary).isEqual(to: hook) && (group["matcher"] as? String) == matcher
            }
        }
        return found == 1 && good
    }

    /// Takes our hook objects out of the groups. A group that ends up with no hooks because of
    /// that is dropped; other hooks and keys in a group stay.
    private static func removingOurs(from groups: [Any]) -> (groups: [Any], changed: Bool) {
        var changed = false
        var result: [Any] = []
        for item in groups {
            guard var group = item as? [String: Any], let list = group["hooks"] as? [Any] else {
                result.append(item)
                continue
            }
            let kept = list.filter { ($0 as? [String: Any]).flatMap(ourPath) == nil }
            if kept.count == list.count { result.append(item); continue }
            changed = true
            if kept.isEmpty { continue }
            group["hooks"] = kept
            result.append(group)
        }
        return (result, changed)
    }
}
