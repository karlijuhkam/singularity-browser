import Foundation

/// The rules for little windows: the throwaway window a link from another app opens in
/// (spec: docs/superpowers/specs/2026-11-12-little-window-design.md). Pure, so they are unit-tested.
public enum LittleWindowRules {
    /// A web link (http/https with a host). Pop-ups inside a little window follow only these.
    public static func accepts(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host() ?? "").isEmpty
    }

    /// A local HTML file. macOS hands these to the default browser too (Finder, `open page.html`).
    public static func isHTMLFile(_ url: URL) -> Bool {
        url.isFileURL && ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }

    /// What opens a little window when another app hands it to us: a web link or an HTML file.
    /// Anything else is ignored.
    public static func opens(_ url: URL) -> Bool {
        accepts(url) || isHTMLFile(url)
    }

    /// What the title bar shows: host and path, without scheme, "www.", query or fragment.
    /// "github.com/roosa/singularity/pull/42". A file shows its path. The view shortens it in the
    /// middle when it is long.
    public static func addressText(_ url: URL?) -> String {
        if let url, url.isFileURL { return url.path(percentEncoded: false) }
        guard let url, var host = url.host(), !host.isEmpty else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = url.port { host += ":\(port)" }
        let path = url.path()
        return path == "/" ? host : host + path
    }

    /// The Space a new little window belongs to: the one selected in the main window when the
    /// link arrived, or the first Space when none is selected.
    public static func homeSpace(selected: UUID?, spaces: [UUID]) -> UUID? {
        if let selected, spaces.contains(selected) { return selected }
        return spaces.first
    }

    public enum OpenAction: Equatable, Sendable {
        /// The home Space: the live page becomes a tab, nothing reloads.
        case move
        /// Another Space: logins can't move, so this address is loaded there in a new tab.
        case reload(URL)
    }

    /// What "Open in <Space>" does.
    /// - Parameters:
    ///   - current: the address the page shows now (it may have navigated since the click).
    ///   - failed: the address whose load failed, while the error page for it is showing.
    ///   - first: the link that opened the window (used when nothing has loaded yet).
    public static func openAction(home: UUID, chosen: UUID, current: URL?, failed: URL?, first: URL) -> OpenAction {
        if chosen == home { return .move }
        if let failed { return .reload(failed) }
        if let current, opens(current) { return .reload(current) }
        return .reload(first)
    }
}
