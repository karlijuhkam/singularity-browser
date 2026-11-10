import Foundation

/// What a site may do with the camera or the microphone.
public enum MediaPermission: String, Codable, CaseIterable, Sendable {
    /// WebKit asks every time (the default).
    case ask
    /// Granted without asking. macOS still asks once for the whole app.
    case allow
    /// Refused without asking.
    case block
}

/// The owner's choices for one site in one Space. A "site" is an origin: scheme + host + port
/// ("https://example.com", "http://localhost:3000"), the same notion the agent approvals use.
public struct SiteSettings: Codable, Hashable, Sendable {
    public var camera: MediaPermission
    public var microphone: MediaPermission
    /// "Let agents see console and network" for this site. Only counts while the Space's own
    /// switch (`Space.agentInspection`) is on as well.
    public var agentsCanInspect: Bool
    /// Plugins whose page script is not injected on this site. Only narrows what a plugin may do.
    public var disabledPlugins: Set<String>

    public init(camera: MediaPermission = .ask, microphone: MediaPermission = .ask, agentsCanInspect: Bool = false,
                disabledPlugins: Set<String> = []) {
        self.camera = camera
        self.microphone = microphone
        self.agentsCanInspect = agentsCanInspect
        self.disabledPlugins = disabledPlugins
    }

    /// Nothing chosen: such entries are not stored.
    public var isDefault: Bool { self == SiteSettings() }

    /// Tolerant decoding, so a file written by an older or newer version still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        camera = (try? container.decodeIfPresent(MediaPermission.self, forKey: .camera)) ?? .ask
        microphone = (try? container.decodeIfPresent(MediaPermission.self, forKey: .microphone)) ?? .ask
        agentsCanInspect = (try? container.decodeIfPresent(Bool.self, forKey: .agentsCanInspect)) ?? false
        disabledPlugins = Set((try? container.decodeIfPresent([String].self, forKey: .disabledPlugins)) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(camera, forKey: .camera)
        try container.encode(microphone, forKey: .microphone)
        try container.encode(agentsCanInspect, forKey: .agentsCanInspect)
        try container.encode(disabledPlugins.sorted(), forKey: .disabledPlugins) // sorted: stable files
    }

    private enum CodingKeys: String, CodingKey {
        case camera, microphone, agentsCanInspect, disabledPlugins
    }
}

/// Facts about a page's address that the site settings panel and the rules need.
public enum SiteInfo {
    public enum Connection: Equatable, Sendable {
        case secure     // https
        case local      // http on this Mac (localhost, 127.0.0.1, ::1)
        case notSecure  // any other http
    }

    /// The site (origin) of a page, or nil when the page has none we keep settings for
    /// (anything that isn't http or https).
    public static func site(of url: URL?) -> String? {
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return AgentApprovalRules.origin(of: url)
    }

    public static func connection(of url: URL) -> Connection? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        if scheme == "https" { return .secure }
        guard scheme == "http" else { return nil }
        let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        return local ? .local : .notSecure
    }

    /// "example.com" or "localhost:3000" for the panel's title.
    public static func displayName(ofSite site: String) -> String {
        guard let range = site.range(of: "://") else { return site }
        let rest = String(site[range.upperBound...])
        return rest.hasPrefix("www.") ? String(rest.dropFirst(4)) : rest
    }
}

/// Camera and microphone requests from pages.
public enum MediaRules {
    public enum Kind: Sendable { case camera, microphone, cameraAndMicrophone }
    public enum Decision: Equatable, Sendable { case prompt, grant, deny }

    /// - Parameters:
    ///   - requestingSite: the origin of the frame that asks.
    ///   - pageSite: the origin of the tab's page. The owner's choice is made for the page they
    ///     see, so "Allow" only covers the page itself, never a frame from somewhere else; "Block"
    ///     covers everything inside the page.
    public static func decide(_ kind: Kind, settings: SiteSettings, requestingSite: String?, pageSite: String?) -> Decision {
        let wanted: [MediaPermission]
        switch kind {
        case .camera: wanted = [settings.camera]
        case .microphone: wanted = [settings.microphone]
        case .cameraAndMicrophone: wanted = [settings.camera, settings.microphone]
        }
        if wanted.contains(.block) { return .deny }
        if wanted.allSatisfy({ $0 == .allow }), let pageSite, requestingSite == pageSite { return .grant }
        return .prompt
    }
}

/// "Let agents see console and network": off unless switched on twice.
public enum InspectionRules {
    /// The Space's own switch counts only while agents are enabled for the Space at all.
    public static func isSpaceOn(_ space: Space) -> Bool {
        space.agentsEnabled && space.agentInspection
    }

    /// Whether console and network of pages of `site` may be captured and read in this Space.
    public static func isAllowed(_ space: Space, site: String?) -> Bool {
        guard let site, isSpaceOn(space) else { return false }
        return space.siteSettings[site]?.agentsCanInspect == true
    }

    /// The sites to capture in this Space, sorted (the capture script is built from this list).
    public static func capturedSites(_ space: Space) -> [String] {
        guard isSpaceOn(space) else { return [] }
        return space.siteSettings.filter { $0.value.agentsCanInspect }.keys.sorted()
    }

    /// What an agent is told when it asks about a tab that isn't switched on. It says what the
    /// owner has to do, and nothing about the page.
    public static func refusal(space: Space, site: String?) -> String {
        guard let site else {
            return "This tab has no web page (http or https) whose console and network could be read."
        }
        let name = SiteInfo.displayName(ofSite: site)
        if !isSpaceOn(space) {
            return "Console and network are not open to agents in the “\(space.name)” Space. Ask the user to turn on "
                + "“Let agents see console and network” for this Space (Edit Space, or Settings → Agents), and then for \(name) "
                + "in the site settings (the button next to the address)."
        }
        return "Console and network of \(name) are not open to agents. Ask the user to turn on “Let agents see console and "
            + "network” for \(name) in the site settings (the button next to the address), then reload the page."
    }
}

extension Space {
    /// The settings of a site (defaults when nothing was chosen).
    public func settings(forSite site: String) -> SiteSettings {
        siteSettings[site] ?? SiteSettings()
    }

    /// Stores a site's settings; entries equal to the defaults are removed.
    public mutating func setSettings(_ settings: SiteSettings, forSite site: String) {
        siteSettings[site] = settings.isDefault ? nil : settings
    }

    /// Per plugin: the sites it is switched off on (for the plugin's page script).
    public func sitesWherePluginIsOff(_ pluginID: String) -> [String] {
        siteSettings.filter { $0.value.disabledPlugins.contains(pluginID) }.keys.sorted()
    }
}
