import Foundation

/// Plain words for what an extension asks for (the approval sheet and run-time questions).
public enum ExtensionWording {
    /// One line for a manifest permission. Unknown ones are named as they are.
    public static func permission(_ name: String) -> String {
        switch name {
        case "activeTab": return "Read and change the tab you're on when you click its button"
        case "alarms": return "Run on a schedule"
        case "clipboardRead": return "Read what you copied"
        case "clipboardWrite": return "Put text on the clipboard"
        case "contextMenus", "menus": return "Add items to the right-click menu"
        case "cookies": return "Read and change cookies of the sites it can reach"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": return "Block or change requests pages make"
        case "declarativeNetRequestFeedback": return "See which requests it blocked or changed"
        case "nativeMessaging": return "Talk to programs on this Mac (not available in Singularity)"
        case "notifications": return "Show notifications"
        case "scripting": return "Run scripts on the sites it can reach"
        case "storage", "unlimitedStorage": return "Keep its own data"
        case "tabs": return "See the addresses and titles of this Space's tabs"
        case "webNavigation": return "See where this Space's tabs go"
        case "webRequest": return "See the requests pages make"
        default: return "“\(name)”"
        }
    }

    /// The sites a match pattern covers, in words.
    public static func sites(_ pattern: String) -> String {
        if pattern == "<all_urls>" || pattern == "*://*/*" || pattern == "http://*/*" || pattern == "https://*/*" {
            return "Every site"
        }
        guard let range = pattern.range(of: "://") else { return pattern }
        var host = String(pattern[range.upperBound...])
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host == "*" { return "Every site" }
        if host.hasPrefix("*.") { return "\(host.dropFirst(2)) and its subdomains" }
        return host
    }

    /// True when the patterns reach every site (the sheet says so loudly).
    public static func reachesEverySite(_ patterns: [String]) -> Bool {
        patterns.contains { sites($0) == "Every site" }
    }
}
