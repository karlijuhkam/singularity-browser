import Foundation
import Observation
import SingularityCore
import WebKit

/// Owns one `WebTabController` (and so one live WKWebView) per open tab.
///
/// Web views are created lazily, the first time a tab is shown, and then kept alive when
/// you switch tabs or Spaces, so pages keep their scroll position, form input, media, etc.
@MainActor
@Observable
final class WebViewRegistry {
    @ObservationIgnored weak var state: AppState?
    /// Adds plugins' page scripts to each new web view (set by AppState).
    @ObservationIgnored var pluginScripts: PluginScripts?
    private var controllers: [UUID: WebTabController] = [:]

    func existingController(_ tabID: UUID) -> WebTabController? {
        controllers[tabID]
    }

    /// The tab a web view belongs to (for messages from page scripts, which name their web view).
    func tabID(for webView: WKWebView) -> UUID? {
        controllers.first { $0.value.webView === webView }?.key
    }

    /// Returns the tab's controller, creating it (and starting the page load) if needed.
    func controller(for tab: BrowserTab, in space: Space) -> WebTabController {
        if let existing = controllers[tab.id] { return existing }
        let configuration = Self.configuration(for: space)
        pluginScripts?.attach(configuration.userContentController, spaceID: space.id)
        let controller = WebTabController(
            tabID: tab.id,
            spaceID: space.id,
            configuration: configuration,
            state: state
        )
        controllers[tab.id] = controller
        if let url = tab.url { controller.load(url) }
        return controller
    }

    /// Artifact tabs: same Space data store, plus the `window.singularity` bridge.
    func artifactController(for tab: BrowserTab, in space: Space, host: ArtifactHost, request: URLRequest) -> WebTabController {
        if let existing = controllers[tab.id] { return existing }
        let configuration = Self.configuration(for: space)
        if let port = host.port {
            ArtifactBridge(state: state, spaceID: space.id, port: port).install(in: configuration)
        }
        // After the app's own scripts: those are kept whenever plugin scripts change.
        pluginScripts?.attach(configuration.userContentController, spaceID: space.id)
        let controller = WebTabController(tabID: tab.id, spaceID: space.id, configuration: configuration, state: state, isArtifact: true)
        controllers[tab.id] = controller
        controller.webView.load(request)
        return controller
    }

    /// Registers a web view that WebKit created for a pop-up (see `AppState.openPopup`).
    func adoptPopup(tabID: UUID, spaceID: UUID, configuration: WKWebViewConfiguration) -> WebTabController {
        // WebKit's popup configuration shares the opener's content controller, which is already
        // managed; attach does nothing then.
        pluginScripts?.attach(configuration.userContentController, spaceID: spaceID)
        let controller = WebTabController(tabID: tabID, spaceID: spaceID, configuration: configuration, state: state)
        controllers[tabID] = controller
        return controller
    }

    func removeControllers(for tabIDs: [UUID]) {
        for id in tabIDs {
            controllers.removeValue(forKey: id)?.tearDown()
        }
    }

    /// Builds the configuration for a new web view in a Space.
    ///
    /// The key line is `websiteDataStore`: `WKWebsiteDataStore(forIdentifier:)` (macOS 14+)
    /// gives each Space its own persistent cookie jar, localStorage, IndexedDB, cache, etc.
    /// WebKit stores them under ~/Library/WebKit/<bundle id>/WebsiteDataStore/<space id>/.
    static func configuration(for space: Space) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: space.id)
        // Without "Version/x Safari/y" in the user agent, some sites (Google sign-in among them)
        // treat WKWebView as an insecure embedded browser. We append the installed Safari's version.
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        // Agent tools (read_page, find, click, type), in an isolated world pages can't see.
        PageAgentScript.install(in: configuration)
        return configuration
    }

    private static let safariUserAgentSuffix: String = {
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let version = safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()
}
