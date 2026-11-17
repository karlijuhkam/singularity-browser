import Foundation

/// Where a relative path that the owner Cmd-clicked in a terminal points.
///
/// SwiftTerm finds paths in terminal output and resolves a relative one against the directory the
/// shell reported with OSC 7. The login shells we start (zsh, bash on macOS) don't send OSC 7
/// outside Apple's Terminal, so SwiftTerm falls back to the *app's* working directory, `/`, finds
/// no file there and shows "Link blocked". We know the directory ourselves (the program in front,
/// or the shell), so the view turns such a path into an absolute one before SwiftTerm checks it.
/// SwiftTerm's own checks (the file exists, isn't an app or script, `:line` suffixes) still apply.
public enum TerminalLinkPath {
    /// The absolute path for `link`, or nil to leave the link as it is: it is a URL, an absolute
    /// or `~` path, or there is no absolute directory to resolve it against.
    public static func absolute(_ link: String, in directory: String?) -> String? {
        guard !link.isEmpty, let directory, directory.hasPrefix("/") else { return nil }
        guard !link.hasPrefix("/"), !link.hasPrefix("~"), !hasURLScheme(link) else { return nil }
        return (directory as NSString).appendingPathComponent(link)
    }

    /// The path the view hands SwiftTerm for a detected link, or nil to leave the link as it is.
    ///
    /// Besides making a relative path absolute (`absolute(_:in:)`), it drops punctuation that ends
    /// the sentence around a path: SwiftTerm's detection takes "see /a/notes.md." whole, finds no
    /// file "notes.md." and says "Link blocked". Characters are dropped from the end one at a time
    /// (`trailingPunctuation`), and only while the path with them names no file (`exists`; a `:line`
    /// or `:line:column` suffix counts as SwiftTerm counts it), so a file whose name really ends in
    /// one keeps it. When no shorter path names a file either, the link is left as it was (made
    /// absolute, if relative), and SwiftTerm reports it as before.
    public static func target(
        _ link: String,
        in directory: String?,
        home: String,
        exists: (String) -> Bool
    ) -> String? {
        guard !link.isEmpty, !hasURLScheme(link) else { return nil }
        let path: String
        if link.hasPrefix("/") {
            path = link
        } else if link == "~" || link.hasPrefix("~/") {
            guard home.hasPrefix("/") else { return nil }
            path = (home as NSString).appendingPathComponent(String(link.dropFirst()))
        } else if link.hasPrefix("~") {
            return nil // ~user: SwiftTerm expands it
        } else {
            guard let absolute = absolute(link, in: directory) else { return nil }
            path = absolute
        }
        var candidate = path
        while true {
            if namesFile(candidate, exists: exists) {
                return candidate == link ? nil : candidate
            }
            guard let last = candidate.last, trailingPunctuation.contains(last),
                  candidate.count > 1 else { break }
            candidate.removeLast()
        }
        return path == link ? nil : path
    }

    /// What may end a sentence or close a bracket or quote around a path in prose.
    static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\"", "`", "\u{2019}", "\u{201D}", "\u{2026}",
    ]

    /// True when `path` is a file or folder, or is one followed by a `:line` or `:line:column`
    /// suffix (SwiftTerm's `defaultLinkURL` rule).
    static func namesFile(_ path: String, exists: (String) -> Bool) -> Bool {
        if exists(path) { return true }
        guard let range = path.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) else {
            return false
        }
        return exists(String(path[..<range.lowerBound]))
    }

    /// SwiftTerm's rule (`TerminalView.hasURLScheme`, internal there): Foundation reads
    /// "main.swift:12" as a URL with the scheme "main.swift", so a name with a `:line` or
    /// `:line:column` suffix is a path, except for schemes whose target can be only digits.
    static func hasURLScheme(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme else { return false }
        if numericURLSchemes.contains(scheme.lowercased()) { return true }
        return link.range(of: #"^[^:/]+:[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) == nil
    }

    static let numericURLSchemes: Set<String> = [
        "tel", "sms", "facetime", "facetime-audio", "callto", "fax",
    ]
}
