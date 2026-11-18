import AppKit
import Observation
import SingularityCore
import SwiftUI
import WebKit

/// One private window: a page whose cookies and site data live only in memory and that leaves
/// nothing behind (spec: docs/superpowers/specs/2026-11-18-private-window-design.md).
///
/// The page is a `WebTabController` made with `isPrivate`, owned by this window. It is in no Space
/// and not in `WebViewRegistry`, so no agent tool, plugin or extension can reach it.
@MainActor
@Observable
final class PrivateWindow: NSObject, Identifiable, NSWindowDelegate {
    let id = UUID()
    let controller: WebTabController
    /// True for a window opened by the owner with no page yet: the note on what the window keeps
    /// shows until a page arrives. Pop-ups never show it.
    let showsNote: Bool
    @ObservationIgnored let window: NSWindow
    @ObservationIgnored weak var owner: PrivateWindows?
    /// The title-bar controls; kept alive here (a toolbar holds its delegate weakly).
    @ObservationIgnored var chrome: PrivateWindowChrome?

    init(controller: WebTabController, window: NSWindow, showsNote: Bool) {
        self.controller = controller
        self.window = window
        self.showsNote = showsNote
        super.init()
        window.delegate = self
    }

    // NSWindowDelegate. The red button ends here.
    func windowWillClose(_ notification: Notification) {
        owner?.close(self, windowIsClosing: true)
    }

    // "Main", not "key", as for little windows: a sheet on the window takes key, and ⌘W must still
    // not reach a tab of the browser window behind it.
    func windowDidBecomeMain(_ notification: Notification) {
        owner?.setFront(self, isFront: true)
    }

    func windowDidResignMain(_ notification: Notification) {
        owner?.setFront(self, isFront: false)
    }

    static let minimumSize = NSSize(width: 480, height: 340)

    /// Enforced here because the toolbar and the SwiftUI content view overwrite the window's own
    /// minimum sizes (see `LittleWindow`).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, Self.minimumSize.width), height: max(frameSize.height, Self.minimumSize.height))
    }

    /// Lets go of everything the window holds, so the window, its title bar and its page are freed.
    func dismantle() {
        window.delegate = nil
        window.contentView = nil
        window.toolbar = nil
        chrome = nil
    }
}

/// Opens, tracks and closes the private windows, and owns their shared in-memory data store.
@MainActor
@Observable
final class PrivateWindows {
    @ObservationIgnored weak var state: AppState?
    private(set) var windows: [PrivateWindow] = []
    /// The private window that is the app's main window, if one is. Page commands act on its page.
    private(set) var frontWindowID: UUID?
    /// Tests: windows are placed far off screen and never take the keyboard.
    @ObservationIgnored var staysOffScreen = false
    @ObservationIgnored private var opened = 0
    /// The private windows' cookies, logins and site data, in memory only. Shared by every private
    /// window open at the same time (so a pop-up sign-in works), emptied and dropped when the last
    /// one closes; the next private window gets a new one.
    @ObservationIgnored private(set) var dataStore: WKWebsiteDataStore?

    var frontWindow: PrivateWindow? {
        guard let frontWindowID else { return nil }
        return windows.first { $0.id == frontWindowID }
    }

    /// True for the NSWindow of a private window (the inbox never uses one as its parent).
    func owns(_ window: NSWindow) -> Bool {
        windows.contains { $0.window === window }
    }

    /// A new private window, empty (the address field takes the keyboard) or with `url` loading.
    @discardableResult
    func open(_ url: URL? = nil) -> PrivateWindow {
        let store = currentStore()
        let controller = makeController(configuration: WebViewRegistry.privateConfiguration(store: store))
        let entry = add(controller, showsNote: url == nil)
        if let url { controller.load(url) }
        show(entry, focusAddress: url == nil)
        return entry
    }

    /// A pop-up of a private page (`target="_blank"`, `window.open`), or a ⌘-click when
    /// `configuration` is nil. A pop-up's web view must be made from WebKit's configuration and is
    /// loaded by WebKit itself; a ⌘-click is an ordinary new window.
    func openPopup(configuration: WKWebViewConfiguration?, request: URLRequest) -> WKWebView? {
        guard let configuration else {
            if let url = request.url { open(url) }
            return nil
        }
        // WebKit's pop-up configuration is a copy of the opener's, so it has the private store.
        let controller = makeController(configuration: configuration)
        controller.closesWhenOnlyADownload = true
        let popup = add(controller, showsNote: false)
        show(popup, focusAddress: false)
        return controller.webView
    }

    /// Throws the page away. When the last private window goes, so does the data store.
    /// - Parameter windowIsClosing: the owner closed the window, so AppKit is taking it off screen.
    func close(_ entry: PrivateWindow, windowIsClosing: Bool = false) {
        guard let index = windows.firstIndex(where: { $0 === entry }) else { return }
        windows.remove(at: index)
        if frontWindowID == entry.id { frontWindowID = nil }
        // From code it is `orderOut`, never `close()`: closing the last window quits the app.
        if !windowIsClosing { entry.window.orderOut(nil) }
        entry.dismantle()
        entry.controller.onPrivatePopup = nil
        entry.controller.onPrivateClose = nil
        entry.controller.tearDown()
        if windows.isEmpty { dropStore() }
    }

    func setFront(_ entry: PrivateWindow, isFront: Bool) {
        if isFront {
            frontWindowID = entry.id
        } else if frontWindowID == entry.id {
            frontWindowID = nil
        }
    }

    // MARK: - Pieces

    private func currentStore() -> WKWebsiteDataStore {
        if let dataStore { return dataStore }
        let store = WKWebsiteDataStore.nonPersistent()
        dataStore = store
        return store
    }

    /// Empties the store (it is in memory anyway; this also covers a download that still holds a
    /// page, and so the store, for a while) and forgets it.
    private func dropStore() {
        guard let store = dataStore else { return }
        dataStore = nil
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    private func makeController(configuration: WKWebViewConfiguration) -> WebTabController {
        // A fresh space id that names no Space: nothing the page does can find one.
        WebTabController(tabID: UUID(), spaceID: UUID(), configuration: configuration, state: state, isPrivate: true)
    }

    private func add(_ controller: WebTabController, showsNote: Bool) -> PrivateWindow {
        let window = makeWindow()
        let entry = PrivateWindow(controller: controller, window: window, showsNote: showsNote)
        entry.owner = self
        controller.onPrivatePopup = { [weak self] configuration, request in
            self?.openPopup(configuration: configuration, request: request)
        }
        controller.onPrivateClose = { [weak self, weak entry] in
            if let entry { self?.close(entry) }
        }
        entry.chrome = PrivateWindowChrome(entry: entry, state: state)
        let page = NSHostingView(rootView: PrivatePageView(entry: entry))
        page.sizingOptions = []
        window.contentView = page
        window.setFrame(frame(forWindowNumber: opened), display: false)
        opened += 1
        windows.append(entry)
        return entry
    }

    private func show(_ entry: PrivateWindow, focusAddress: Bool) {
        if staysOffScreen {
            entry.window.orderFront(nil)
            return
        }
        entry.window.makeKeyAndOrderFront(nil)
        if focusAddress {
            entry.chrome?.focusAddress()
        } else {
            entry.window.makeFirstResponder(entry.controller.webView)
        }
    }

    private static let size = NSSize(width: 1100, height: 760)

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        // We keep the object; AppKit must not free it when it closes.
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.title = "Private Window"
        // Never in macOS's saved window state (~/Library/Saved Application State), which can
        // keep window titles: a private page's title must not be written anywhere.
        window.isRestorable = false
        return window
    }

    /// Centred on the pointer's screen, each further window shifted down and right a entry.
    private func frame(forWindowNumber number: Int) -> NSRect {
        if staysOffScreen { return NSRect(origin: NSPoint(x: -5000, y: -5000), size: Self.size) }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: Self.size) }
        let width = min(Self.size.width, visible.width), height = min(Self.size.height, visible.height)
        let shift = CGFloat(number % 8) * 28
        var origin = NSPoint(x: visible.midX - width / 2 + shift, y: visible.midY - height / 2 - shift)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}
