import Foundation

/// The rules for private windows: a page with an in-memory data store that leaves nothing behind
/// (spec: docs/superpowers/specs/2026-11-18-private-window-design.md). Pure, so they are unit-tested.
public enum PrivateWindowRules {
    /// What the address field loads for the text typed into it: an address, or a search with the
    /// owner's search engine, exactly as the palette decides. Nil for empty text.
    public static func destination(typed text: String, searchTemplate: String) -> URL? {
        URLInput.classify(text, searchTemplate: searchTemplate)?.url
    }

    /// What the address field shows for the page: its full address, or nothing before the first
    /// page (and for `about:blank`), so the placeholder shows.
    public static func fieldText(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    /// Whether a pop-up (`target="_blank"`, `window.open`, ⌘-click) gets a new private window: a web
    /// address, or no address yet (`window.open('')`, which a script fills in afterwards; the
    /// opener needs the window for that). Anything else (`file:`, `javascript:`, …) is refused.
    public static func opensPopup(_ url: URL?) -> Bool {
        guard let url, !url.absoluteString.isEmpty else { return true }
        if url.absoluteString == "about:blank" { return true }
        return LittleWindowRules.accepts(url)
    }
}
