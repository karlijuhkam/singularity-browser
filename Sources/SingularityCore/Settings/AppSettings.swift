import Foundation

/// Where the palette sends searches.
public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case duckDuckGo, google, kagi, bing, ecosia, custom

    public var title: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .kagi: return "Kagi"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .custom: return "Custom"
        }
    }

    /// Search URL with `%s` where the (escaped) query goes; nil for `.custom`.
    public var template: String? {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .google: return "https://www.google.com/search?q=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        case .custom: return nil
        }
    }
}

/// App-wide preferences, stored in `~/Singularity/settings.json`.
/// Every field has a default, and a file missing a field (older or hand-edited) still loads.
public struct AppSettings: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine = .duckDuckGo
    /// Used when `searchEngine` is `.custom`: a URL containing `%s`, e.g. "https://example.com/?q=%s".
    public var customSearchTemplate: String = ""
    /// Font family for terminal tabs; nil = the system's monospaced font.
    public var terminalFontName: String?
    public var terminalFontSize: Double = 13
    /// `exit` (or Ctrl-D) at the prompt closes the terminal tab.
    public var closeTerminalOnExit: Bool = true
    /// Run terminal tabs through the owner's installed herdr-core (`hc`), so shells outlive the
    /// app (see `HerdrCore`). Off by default; falls back to the built-in terminal when `hc` is missing.
    public var terminalUsesHerdrCore: Bool = false
    /// How long an agent approval waits in the inbox before counting as "Deny".
    public var agentApprovalTimeoutSeconds: Int = 120
    /// Check for updates by itself (only copies that `UpdatePolicy` allows to update).
    public var checksForUpdates: Bool = true
    /// The launcher buttons in the sidebar's bottom row (Settings → Terminal → Launchers). A file
    /// without this key gets Claude Code and Codex; an empty list stays empty.
    public var launchers: [Launcher] = Launcher.defaults
    /// The sidebar's width in points, one for all Spaces (see `SidebarLayout`).
    public var sidebarWidth: Double = SidebarLayout.defaultWidth
    /// View → Hide Sidebar. Hidden, it slides out at the window's left edge (`SidebarPeek`).
    public var sidebarHidden: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        searchEngine = (try? container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? defaults.searchEngine
        // `try?` everywhere: one field of the wrong type falls back to its default instead of
        // resetting every setting.
        customSearchTemplate = (try? container.decodeIfPresent(String.self, forKey: .customSearchTemplate)) ?? defaults.customSearchTemplate
        terminalFontName = (try? container.decodeIfPresent(String.self, forKey: .terminalFontName)) ?? nil
        terminalFontSize = (try? container.decodeIfPresent(Double.self, forKey: .terminalFontSize)) ?? defaults.terminalFontSize
        closeTerminalOnExit = (try? container.decodeIfPresent(Bool.self, forKey: .closeTerminalOnExit)) ?? defaults.closeTerminalOnExit
        terminalUsesHerdrCore = (try? container.decodeIfPresent(Bool.self, forKey: .terminalUsesHerdrCore)) ?? defaults.terminalUsesHerdrCore
        agentApprovalTimeoutSeconds = (try? container.decodeIfPresent(Int.self, forKey: .agentApprovalTimeoutSeconds))
            ?? defaults.agentApprovalTimeoutSeconds
        checksForUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checksForUpdates)) ?? defaults.checksForUpdates
        launchers = Launcher.decodeList(from: container, forKey: .launchers) ?? defaults.launchers
        sidebarWidth = SidebarLayout.clamp((try? container.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? defaults.sidebarWidth)
        sidebarHidden = (try? container.decodeIfPresent(Bool.self, forKey: .sidebarHidden)) ?? defaults.sidebarHidden
    }

    /// The search template in effect. A custom template that isn't an http(s) URL containing `%s`
    /// falls back to DuckDuckGo, so a typo never breaks searching.
    public var searchTemplate: String {
        if let template = searchEngine.template { return template }
        return Self.isValidSearchTemplate(customSearchTemplate) ? customSearchTemplate : SearchEngine.duckDuckGo.template!
    }

    /// Name shown in the palette ("Search Google"); "DuckDuckGo" when a custom template is invalid.
    public var searchEngineName: String {
        if searchEngine != .custom { return searchEngine.title }
        guard Self.isValidSearchTemplate(customSearchTemplate),
              let host = URL(string: customSearchTemplate.replacingOccurrences(of: "%s", with: "x"))?.host() else {
            return SearchEngine.duckDuckGo.title
        }
        return host
    }

    public static func isValidSearchTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "test")),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return false }
        return true
    }
}
