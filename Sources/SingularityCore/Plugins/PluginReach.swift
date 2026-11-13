import Foundation

/// The tab in front, as a plugin with the `frontTab` permission may know it. Ids and kinds match
/// what the agent tool `list_tabs` reports.
public struct FrontTab: Equatable, Sendable, Codable {
    public struct SpaceRef: Equatable, Sendable, Codable {
        public var slug: String
        public var name: String
        public init(slug: String, name: String) { self.slug = slug; self.name = name }
    }
    public struct TabRef: Equatable, Sendable, Codable {
        /// Lowercased UUID, as `list_tabs` gives it.
        public var id: String
        /// "web", "artifact" or "terminal".
        public var kind: String
        /// Web and artifact tabs only, cut to 300 characters.
        public var title: String?
        /// Web and artifact tabs only, cut to 2000 characters. For an artifact: its file path.
        public var url: String?
        public init(id: String, kind: String, title: String? = nil, url: String? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.url = url
        }
    }
    public var space: SpaceRef
    public var tab: TabRef
    public init(space: SpaceRef, tab: TabRef) { self.space = space; self.tab = tab }
}

/// Where a plugin may reach into a Space: the switches and the tab in front. Pure rules.
public enum PluginReach {
    static let titleLimit = 300
    static let urlLimit = 2000

    /// The Space is switched on for the plugin (approved, and its id in enabledSpaces).
    public static func spaceIsOpen(_ space: Space, approval: PluginApproval?, status: PluginStatus) -> Bool {
        status == .approved && approval?.enabledSpaces.contains(space.id) == true
    }

    /// The owner switched this plugin off for the site of `url` in this Space.
    public static func siteIsOff(_ space: Space, pluginID: String, url: URL?) -> Bool {
        guard let site = SiteInfo.site(of: url) else { return false }
        return space.settings(forSite: site).disabledPlugins.contains(pluginID)
    }

    /// Listed in the site settings panel: switched on for the Space and (a page script that runs
    /// on `url`, or the plugin reaches Spaces).
    public static func listedForSite(manifest: PluginManifest, approval: PluginApproval, space: Space, url: URL) -> Bool {
        guard approval.enabledSpaces.contains(space.id) else { return false }
        if manifest.reachesSpaces { return true }
        return manifest.page != nil
            && PluginPageAccess(manifest: manifest, approved: approval.permissions).runsOn(url)
    }

    /// Why there is no front tab, for the native strip and the chip's wording.
    public enum Hidden: Equatable, Sendable { case spaceOff, siteOff, nothing }
    public enum Front: Equatable, Sendable { case tab(FrontTab), hidden(Hidden) }

    /// `lastOtherPane`: in the selected tab's split, the pane focused last that is not a plugin
    /// tab (nil if none). It is used only when the selected tab is a plugin tab.
    ///
    /// `liveURL`: the address of a tab's live page, when it has one (the app passes its web view's
    /// URL). For web and artifact tabs alike, the site switch is checked against it (a web tab's
    /// stored address too), so a page that was redirected or navigated elsewhere counts where it is now. An artifact tab whose live page
    /// is no longer on `artifactOrigin` (the Space's artifact server) is reported as the web page it
    /// shows: kind "web" with that address, never as an artifact with a file path.
    public static func front(pluginID: String, space: Space?, spaceIsOpen: Bool, welcomeCoversWindow: Bool,
                             lastOtherPane: UUID?, liveURL: (UUID) -> URL? = { _ in nil },
                             artifactOrigin: URL? = nil) -> Front {
        if welcomeCoversWindow { return .hidden(.nothing) }
        guard let space, let selected = space.selectedTab else { return .hidden(.nothing) }
        guard spaceIsOpen else { return .hidden(.spaceOff) }

        var tab = selected
        if selected.isPlugin {
            guard let other = lastOtherPane.flatMap({ space.tab($0) }), !other.isPlugin else { return .hidden(.nothing) }
            tab = other
        }

        let live = liveURL(tab.id)
        var ref = FrontTab.TabRef(id: tab.id.uuidString.lowercased(), kind: "terminal")
        func webPage(_ url: URL) {
            ref.kind = "web"
            ref.title = String(tab.displayTitle.prefix(titleLimit))
            ref.url = String(url.absoluteString.prefix(urlLimit))
        }
        switch tab.kind {
        case .web(let stored):
            // The stored address follows the page (`webTabDidChange`); either one on a switched-off
            // site hides the tab, so a page that just moved counts at once.
            if siteIsOff(space, pluginID: pluginID, url: stored)
                || live.map({ siteIsOff(space, pluginID: pluginID, url: $0) }) == true { return .hidden(.siteOff) }
            webPage(stored)
        case .artifact(let path):
            if let live {
                if siteIsOff(space, pluginID: pluginID, url: live) { return .hidden(.siteOff) }
                let onArtifactServer = artifactOrigin.flatMap { SiteInfo.site(of: $0) }.map { $0 == SiteInfo.site(of: live) } ?? false
                if !onArtifactServer {
                    webPage(live)
                    break
                }
            }
            ref.kind = "artifact"
            ref.title = String(tab.displayTitle.prefix(titleLimit))
            ref.url = String(path.prefix(urlLimit))
        case .terminal:
            break
        case .plugin:
            return .hidden(.nothing) // unreachable: resolved above
        }
        return .tab(FrontTab(space: .init(slug: space.slug, name: space.name), tab: ref))
    }
}
