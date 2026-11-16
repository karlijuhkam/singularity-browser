import Foundation

// Two small things a plugin may ask the app to do, each behind its own permission (owner decision
// 2026-11-16, spec `docs/superpowers/specs/2026-11-16-plugin-terminal-and-notify-design.md`):
// open a terminal tab that runs a declared program (`openTerminals`), and show a macOS
// notification (`notifications`). The rules are here, pure and tested; `PluginManager` applies them.

/// What may be typed into a new terminal tab for a plugin.
///
/// The line is `<pinned path> <arguments>`, typed into the tab's login shell as a launcher's
/// command is. The path is the one resolved and shown at approval; the arguments are the
/// plugin's, so each must be made only of characters the shell reads as plain text. Anything
/// else (a space, a quote, `;`, `$`, `|`, a newline) refuses the whole request: a plugin can pick
/// arguments for its declared program, never a second command.
public enum PluginTerminalRules {
    public static let maxArguments = 16
    public static let maxArgumentLength = 200

    public static func isSafeArgument(_ argument: String) -> Bool {
        guard (1...maxArgumentLength).contains(argument.utf8.count) else { return false }
        return argument.utf8.allSatisfy { b in
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)   // 0-9 A-Z a-z
                || b == 45 || b == 46 || b == 95 || b == 47 || b == 58 || b == 61 || b == 64 || b == 43 || b == 44
        }                                                                           // - . _ / : = @ + ,
    }

    /// The line to type, or nil when an argument is not plain text or there are too many.
    public static func commandLine(path: String, arguments: [String]) -> String? {
        guard path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\u{0}" }),
              arguments.count <= maxArguments, arguments.allSatisfy(isSafeArgument) else { return nil }
        return ([quote(path)] + arguments).joined(separator: " ")
    }

    /// The path as one shell word: as it is when it is plain, else in single quotes (inside which
    /// the shell reads everything literally; a quote in the path is closed, escaped, reopened).
    static func quote(_ path: String) -> String {
        isSafeArgument(path) ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// "At most this many in this long, and not two closer than this": so a plugin gone wrong can't
/// flood the sidebar with terminals or the screen with banners.
public struct PluginRateLimit: Sendable {
    public let limit: Int
    public let window: TimeInterval
    public let minimumGap: TimeInterval
    private var times: [Date] = []

    public init(limit: Int, window: TimeInterval, minimumGap: TimeInterval) {
        self.limit = limit
        self.window = window
        self.minimumGap = minimumGap
    }

    /// Terminals a plugin may open: 5 a minute, 2 s apart.
    public static let terminals = PluginRateLimit(limit: 5, window: 60, minimumGap: 2)
    /// Notifications: 20 an hour, 5 s apart.
    public static let notifications = PluginRateLimit(limit: 20, window: 3600, minimumGap: 5)

    /// True, and counted, when one more is fine now.
    public mutating func allow(now: Date) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= window }
        if let last = times.last, now.timeIntervalSince(last) < minimumGap { return false }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}

/// A plugin's notification as it is shown. The plugin's own name always leads the title, so a
/// banner can't pass for Singularity's or another program's; the text is cleaned and cut.
public enum PluginNotice {
    public static func text(pluginName: String, title: String, body: String) -> (title: String, body: String)? {
        let name = InboxText.clean(pluginName, limit: 40)
        let cleanTitle = InboxText.clean(title, limit: 80)
        let cleanBody = InboxText.clean(body, limit: 300)
        guard !name.isEmpty, !(cleanTitle.isEmpty && cleanBody.isEmpty) else { return nil }
        return (cleanTitle.isEmpty ? name : name + ": " + cleanTitle, cleanBody)
    }
}
