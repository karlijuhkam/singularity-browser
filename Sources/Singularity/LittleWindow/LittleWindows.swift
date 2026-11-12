import AppKit
import Observation
import SingularityCore
import SwiftUI

/// One little window: a link from another app, shown in its own throwaway window
/// (spec: docs/superpowers/specs/2026-11-12-little-window-design.md).
///
/// The page is an ordinary `WebTabController` in the `WebViewRegistry`, with the logins and
/// plugins of its *home Space* (the Space that was open when the link arrived). What makes it
/// "little" is only that the Space has no tab for it yet.
@MainActor
@Observable
final class LittleWindow: NSObject, Identifiable, NSWindowDelegate {
    /// Also the page's tab id, should it become a tab.
    let id: UUID
    let homeSpaceID: UUID
    /// The link that opened the window.
    let firstURL: URL
    /// The Space the "Open in …" button points at. Starts as the home Space.
    var chosenSpaceID: UUID
    let controller: WebTabController
    @ObservationIgnored let window: NSWindow
    @ObservationIgnored weak var owner: LittleWindows?
    /// The title-bar controls; kept alive here (a toolbar holds its delegate weakly).
    @ObservationIgnored var chrome: LittleWindowChrome?

    init(homeSpaceID: UUID, firstURL: URL, controller: WebTabController, window: NSWindow) {
        self.id = controller.tabID
        self.homeSpaceID = homeSpaceID
        self.firstURL = firstURL
        self.chosenSpaceID = homeSpaceID
        self.controller = controller
        self.window = window
        super.init()
        window.delegate = self
    }

    // NSWindowDelegate. The red button ends here.
    func windowWillClose(_ notification: Notification) {
        owner?.close(self, windowIsClosing: true)
    }

    // "Main", not "key": while a sheet is open on the window (a page's alert, a login dialog, the
    // print sheet) the sheet is the key window, but this window is still the main one, and ⌘W
    // must still not reach a tab of the browser window behind it.
    func windowDidBecomeMain(_ notification: Notification) {
        owner?.setFront(self, isFront: true)
    }

    func windowDidResignMain(_ notification: Notification) {
        owner?.setFront(self, isFront: false)
    }

    /// Lets go of everything the window holds once it is closed or its page has moved to a tab.
    /// The window's content view holds this object (through `LittlePageView`), and this object
    /// holds the window: without this the pair, the title bar and the page would never be freed.
    func dismantle() {
        window.delegate = nil
        window.contentView = nil
        window.toolbar = nil
        chrome = nil
    }
}

/// Opens, tracks and closes the little windows. One per link, never reused.
@MainActor
@Observable
final class LittleWindows {
    @ObservationIgnored weak var state: AppState?
    private(set) var windows: [LittleWindow] = []
    /// The little window that is in front (the app's main window), if one is. The menu commands
    /// (⌘W, ⌘O, Reload, Find, …) act on it instead of the browser window's tab while it is set.
    private(set) var frontWindowID: UUID?
    /// Tests: windows are placed far off screen and never take the keyboard.
    @ObservationIgnored var staysOffScreen = false
    /// How many windows were opened so far; each new one is shifted a little from the last.
    @ObservationIgnored private var opened = 0

    var frontWindow: LittleWindow? {
        guard let frontWindowID else { return nil }
        return windows.first { $0.id == frontWindowID }
    }

    /// Opens a link in a new little window. Returns nil for anything that is not a web link.
    @discardableResult
    func open(_ url: URL) -> LittleWindow? {
        guard LittleWindowRules.accepts(url), let state,
              let homeID = LittleWindowRules.homeSpace(selected: state.selectedSpaceID, spaces: state.spaces.map(\.id)),
              let space = state.space(homeID) else { return nil }

        let controller = state.web.littleController(id: UUID(), url: url, in: space)
        let window = makeWindow()
        let little = LittleWindow(homeSpaceID: homeID, firstURL: url, controller: controller, window: window)
        little.owner = self
        controller.onLittleClose = { [weak self, weak little] in
            if let little { self?.close(little) }
        }
        little.chrome = LittleWindowChrome(little: little, state: state)
        window.contentView = NSHostingView(rootView: LittlePageView(little: little))
        windows.append(little)

        if staysOffScreen {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(controller.webView)
        }
        return little
    }

    /// Throws the page away: nothing is kept, nothing asks.
    /// - Parameter windowIsClosing: the user closed the window (red button), so AppKit is already
    ///   taking it off screen.
    func close(_ little: LittleWindow, windowIsClosing: Bool = false) {
        guard let index = windows.firstIndex(where: { $0 === little }) else { return }
        windows.remove(at: index)
        if frontWindowID == little.id { frontWindowID = nil }
        retire(little, windowIsClosing: windowIsClosing)
        state?.web.removeControllers(for: [little.id])
    }

    /// Takes the window off screen and frees it. When we do it ourselves it is `orderOut`, not
    /// `close()`: closing the last window quits the app, and "Open in …" may run while the browser
    /// window is only just being opened again.
    private func retire(_ little: LittleWindow, windowIsClosing: Bool) {
        if !windowIsClosing { little.window.orderOut(nil) }
        little.dismantle()
    }

    /// "Open in <Space>": the home Space gets the live page as a tab; any other Space loads the
    /// address again, because logins belong to a Space.
    func openInSpace(_ little: LittleWindow) {
        guard let state, windows.contains(where: { $0 === little }) else { return }
        let chosen = state.space(little.chosenSpaceID) != nil ? little.chosenSpaceID : little.homeSpaceID
        guard state.space(chosen) != nil else { return }
        let action = LittleWindowRules.openAction(home: little.homeSpaceID, chosen: chosen,
                                                  current: little.controller.webView.url,
                                                  failed: little.controller.failedAddress, first: little.firstURL)
        // The main window first: if it was closed and the little window were the last one, closing
        // it would quit the app (`applicationShouldTerminateAfterLastWindowClosed`).
        state.showMainWindow()
        switch action {
        case .move:
            // Give up the window but keep the page: the registry still holds the controller, and
            // the main window's pane takes the web view when the new tab is shown.
            windows.removeAll { $0 === little }
            if frontWindowID == little.id { frontWindowID = nil }
            little.controller.webView.removeFromSuperview()
            retire(little, windowIsClosing: false)
            state.adoptLittlePage(little.controller, fallbackURL: little.firstURL)
        case .reload(let url):
            close(little)
            state.userSelectSpace(chosen)
            state.openInNewTab(url, spaceID: chosen)
        }
    }

    /// A Space is being deleted: its little windows go, and windows of other Spaces that pointed
    /// their button at it point at their own Space again.
    func spaceWillBeDeleted(_ spaceID: UUID) {
        for little in windows where little.homeSpaceID == spaceID { close(little) }
        for little in windows where little.chosenSpaceID == spaceID { little.chosenSpaceID = little.homeSpaceID }
    }

    func setFront(_ little: LittleWindow, isFront: Bool) {
        if isFront {
            frontWindowID = little.id
        } else if frontWindowID == little.id {
            frontWindowID = nil
        }
    }

    // MARK: - The window

    private static let size = NSSize(width: 1000, height: 700)

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        // We keep the object (in `LittleWindow`); AppKit must not free it when it closes.
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        // The title is the page's title (Mission Control, the Window menu); the title bar itself
        // shows the address and the controls instead (`LittleWindowChrome`).
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.setFrame(frame(forWindowNumber: opened), display: false)
        opened += 1
        return window
    }

    /// Centred on the screen the pointer is on, each further window 28 points down and right of
    /// the one before (starting over after eight), so none hides another completely.
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
