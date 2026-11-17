import AppKit
import SingularityCore
import WebKit

/// One of a Space's web tabs (or a little window's page) as WebKit's extension machinery sees it.
///
/// WebKit asks the app about tabs and windows instead of keeping its own list: a content script's
/// `chrome.runtime.sendMessage` fails with "Tab not found" until some window's `tabs(for:)` returns
/// the tab whose `webView(for:)` is the page's web view. These adapters answer from `AppState`;
/// `ExtensionCenter` keeps one per tab id so WebKit always gets the same object for a tab.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let tabID: UUID
    let spaceID: UUID
    weak var center: ExtensionCenter?

    init(tabID: UUID, spaceID: UUID, center: ExtensionCenter) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.center = center
    }

    private var state: AppState? { center?.state }
    private var controller: WebTabController? { state?.web.existingController(tabID) }
    private var tab: BrowserTab? { state?.space(spaceID)?.tab(tabID) }
    /// A little window's page: no tab in the Space, a window of its own.
    var isLittle: Bool { controller?.isLittle == true }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        center?.windowAdapter(for: self)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard !isLittle, let space = state?.space(spaceID) else { return 0 }
        return ExtensionCenter.webTabIDs(of: space).firstIndex(of: tabID) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { controller?.webView }

    func title(for context: WKWebExtensionContext) -> String? {
        if isLittle { return controller?.pageTitle }
        return tab?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        controller?.webView.url ?? tab?.url
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned ?? false }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        isLittle || state?.space(spaceID)?.selectedTabID == tabID
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let controller else { return false }
        return !controller.isLoading
    }

    func size(for context: WKWebExtensionContext) -> CGSize { controller?.webView.bounds.size ?? .zero }

    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(controller?.webView.pageZoom ?? 1) }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let controller else { return completionHandler(ExtensionCenter.failure("The tab isn't open.")) }
        controller.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { controller?.webView.reloadFromOrigin() } else { controller?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        controller?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        controller?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard !isLittle, tab != nil, let state else { return completionHandler(nil) }
        // Selecting a tab of another Space would switch the owner's whole window: only within the
        // Space on screen. Otherwise the tab becomes the Space's selected tab for when he returns.
        if state.selectedSpaceID == spaceID {
            state.selectTab(tabID)
        } else {
            state.mutateSpace(spaceID) { $0.selectedTabID = tabID }
        }
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if selected { activate(for: context, completionHandler: completionHandler) } else { completionHandler(nil) }
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let state else { return completionHandler(nil) }
        if isLittle {
            if let little = state.little.windows.first(where: { $0.controller.tabID == tabID }) { state.little.close(little) }
        } else if tab != nil {
            state.closeTab(tabID, in: spaceID, confirmIfBusy: false)
        }
        completionHandler(nil)
    }

    /// The `activeTab` permission: a click on the extension's button gives it this tab.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// The main window as one Space's window (its web tabs, the selected one active), or one little
/// window. Another Space's tabs are never in it: each Space has its own extension controller.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    enum Kind: Equatable { case space(UUID), little(UUID) }
    let kind: Kind
    weak var center: ExtensionCenter?

    init(kind: Kind, center: ExtensionCenter) {
        self.kind = kind
        self.center = center
    }

    private var state: AppState? { center?.state }

    private var nsWindow: NSWindow? {
        switch kind {
        case .space: return state?.mainWindow
        case .little(let id): return state?.little.windows.first { $0.controller.tabID == id }?.window
        }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let center else { return [] }
        switch kind {
        case .space(let spaceID):
            guard let space = state?.space(spaceID) else { return [] }
            return ExtensionCenter.webTabIDs(of: space).map { center.tabAdapter($0, spaceID: spaceID) }
        case .little(let id):
            guard let controller = state?.web.existingController(id) else { return [] }
            return [center.tabAdapter(id, spaceID: controller.spaceID)]
        }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let center else { return nil }
        switch kind {
        case .space(let spaceID):
            guard let space = state?.space(spaceID), let selected = space.selectedTabID,
                  space.tab(selected).map(ExtensionCenter.isWebTab) == true else { return nil }
            return center.tabAdapter(selected, spaceID: spaceID)
        case .little(let id):
            guard let controller = state?.web.existingController(id) else { return nil }
            return center.tabAdapter(id, spaceID: controller.spaceID)
        }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        nsWindow?.isMiniaturized == true ? .minimized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // An extension can't pull the window forward or switch Spaces: the owner decides that.
        completionHandler(nil)
    }
}
