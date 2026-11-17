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
