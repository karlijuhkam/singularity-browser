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
        let configuration: WKWebViewConfiguration
        if let url = tab.url, let extensionPage = state?.extensions.pageConfiguration(for: url, spaceID: space.id) {
            // A browser extension's own page (its options page, a tab it opened): WebKit serves it
            // only in a web view made with that extension's configuration.
            configuration = extensionPage
        } else {
            configuration = Self.configuration(for: space)
            addExtensions(to: configuration, spaceID: space.id)
            pluginScripts?.attach(configuration.userContentController, spaceID: space.id)
        }
        let controller = WebTabController(
            tabID: tab.id,
            spaceID: space.id,
            configuration: configuration,
            state: state
        )
        controllers[tab.id] = controller
        state?.extensions.tabOpened(tab.id, spaceID: space.id)
        if let url = tab.url { loadWhenExtensionsAreReady(controller, url) }
        return controller
    }

    /// The Space's extension controller and the Chrome Web Store button. WebKit only takes the
    /// controller from the configuration a web view is made with, so every web page of a Space gets
    /// it, also while no extension is on (switching one on later then reaches open tabs).
    /// Artifact pages, plugin pages and notes never get it.
    private func addExtensions(to configuration: WKWebViewConfiguration, spaceID: UUID) {
        guard let extensions = state?.extensions else { return }
        configuration.webExtensionController = extensions.controller(for: spaceID)
        StoreButtonScript.install(in: configuration, spaceID: spaceID) { [weak extensions] id, spaceID in
            extensions?.addFromStore(id, fromSpace: spaceID)
        }
    }

    /// At launch the approved extensions load in the background (a moment); a restored page waits
    /// for them (at most 2 s), so their content scripts are there from its first load.
    private func loadWhenExtensionsAreReady(_ controller: WebTabController, _ url: URL) {
        guard let extensions = state?.extensions, !extensions.isReady else { return controller.load(url) }
        Task { @MainActor [weak controller] in
            await extensions.waitUntilReady()
            controller?.load(url)
        }
    }

    /// A little window's page (a link from another app). It is built exactly like a tab's page,
    /// with the Space's logins and plugin scripts, and lives in this registry under an id that no
    /// tab in the Space has. Opening it in the Space later just adds a tab with that id.
    func littleController(id: UUID, url: URL, in space: Space) -> WebTabController {
        let configuration = Self.configuration(for: space)
        addExtensions(to: configuration, spaceID: space.id)
        pluginScripts?.attach(configuration.userContentController, spaceID: space.id)
        let controller = WebTabController(tabID: id, spaceID: space.id, configuration: configuration, state: state)
        controller.makeLittle()
        controllers[id] = controller
        state?.extensions.tabOpened(id, spaceID: space.id)
        loadWhenExtensionsAreReady(controller, url)
        return controller
    }

    /// The pages of a Space that are in little windows.
    func littleControllers(in spaceID: UUID) -> [WebTabController] {
        controllers.values.filter { $0.spaceID == spaceID && $0.isLittle }
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
        // It is a copy of the opener's configuration, so it has the Space's extension controller already.
        let controller = WebTabController(tabID: tabID, spaceID: spaceID, configuration: configuration, state: state)
        controllers[tabID] = controller
        state?.extensions.tabOpened(tabID, spaceID: spaceID)
        return controller
    }

    /// The live web views of a Space's tabs.
    func controllers(in spaceID: UUID) -> [WebTabController] {
        controllers.values.filter { $0.spaceID == spaceID }
    }

    func removeControllers(for tabIDs: [UUID]) {
        for id in tabIDs {
            guard let controller = controllers.removeValue(forKey: id) else { continue }
            state?.extensions.tabClosed(id, spaceID: controller.spaceID)
            controller.tearDown()
        }
    }

    /// Builds the configuration for a new web view in a Space.
    ///
    /// The key line is `websiteDataStore`: `WKWebsiteDataStore(forIdentifier:)` (macOS 14+)
    /// gives each Space its own persistent cookie jar, localStorage, IndexedDB, cache, etc.
    /// WebKit stores them under ~/Library/WebKit/<bundle id>/WebsiteDataStore/<space id>/.
    static func configuration(for space: Space) -> WKWebViewConfiguration {
        let configuration = browserConfiguration(store: WKWebsiteDataStore(forIdentifier: space.id))
        // Agent tools (read_page, find, click, type), in an isolated world pages can't see.
        PageAgentScript.install(in: configuration)
        return configuration
    }

    /// A private window's page: the private windows' in-memory store and nothing of ours on top
    /// (no page agent, plugin scripts, extensions or capture). See `PrivateWindows`.
    static func privateConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        browserConfiguration(store: store)
    }

    /// What every page of the browser gets, whatever its data store.
    private static func browserConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        // Without "Version/x Safari/y" in the user agent, some sites (Google sign-in among them)
        // treat WKWebView as an insecure embedded browser. We append the installed Safari's version.
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        // Adds "Inspect Element" to the right-click menu. `webView.isInspectable` alone only lets
        // Safari's Develop menu attach; the menu item needs this WebKit preference, which has no
        // public Swift property (it is set by key, as other WKWebView browsers do).
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return configuration
    }

    private static let safariUserAgentSuffix: String = {
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let version = safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()
}
