import AppKit
import Observation
import SingularityCore
import SwiftUI

/// The sidebar's width while it is dragged, and the slide-out of a hidden sidebar: with
/// View → Hide Sidebar the sidebar is off screen and comes out over the page while the pointer
/// is at the window's left edge (as in Arc). The rules are Core's `SidebarPeek`; this class
/// collects the facts and keeps `isPeeking`.
///
/// How it notices things: the edge strip (`SidebarEdgeTrigger`) reports the pointer arriving,
/// which opens it. While it is open a timer looks at the facts every 0.15 s and closes it after
/// two looks in a row that say "no reason to stay" (about 0.3 s). A timer and not mouse-exited
/// events: those are not delivered while a menu or a drag has the mouse, and the answer must be
/// right the moment either ends.
@MainActor
@Observable
final class SidebarPeekController {
    @ObservationIgnored weak var state: AppState?
    /// The hidden sidebar is slid out over the page. Set only here (and by a test, for a picture).
    var isPeeking = false
    /// The width under the pointer while the edge is dragged; nil otherwise. The setting is
    /// written once, when the drag ends.
    var liveWidth: Double?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var looksWithoutReason = 0
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var menuObservers: [NSObjectProtocol] = []

    static let edgeWidth: CGFloat = 8
    private static let pollInterval: TimeInterval = 0.15
    private static let looksBeforeClosing = 2

    /// The pointer reached the window's left edge.
    func pointerReachedEdge() {
        guard !isPeeking else { return }
        var facts = self.facts()
        facts.pointerAtEdge = true
        guard SidebarPeek.shouldOpen(facts) else { return }
        isPeeking = true
        looksWithoutReason = 0
        watchMenus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // Timers scheduled from the main thread fire on the main thread.
            MainActor.assumeIsolated { self?.look() }
        }
        // Also while a menu or a drag runs its own event loop.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// The sidebar was shown for good, or something covers the window: no slide-out.
    func close() {
        timer?.invalidate()
        timer = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []
        menuOpen = false
        isPeeking = false
    }

    private func look() {
        if SidebarPeek.shouldStay(facts()) {
            looksWithoutReason = 0
            return
        }
        looksWithoutReason += 1
        if looksWithoutReason >= Self.looksBeforeClosing { close() }
    }

    /// The facts right now, read from the window and the pointer.
    func facts() -> SidebarPeekFacts {
        var facts = SidebarPeekFacts()
        guard let state, let window = state.mainWindow else {
            facts.hidden = false
            return facts
        }
        facts.hidden = state.settings.sidebarHidden
        facts.windowIsKey = window.isKeyWindow
        facts.covered = state.welcomeCoversWindow || window.attachedSheet != nil
        facts.menuOpen = menuOpen
        facts.mouseButtonDown = NSEvent.pressedMouseButtons != 0
        facts.inboxOpenFromTray = state.inbox.isPanelShown && state.inbox.panelController.isAnchoredToTray

        // The pointer in window coordinates (origin bottom-left), wherever the last event went.
        let pointer = window.mouseLocationOutsideOfEventStream
        let inWindow = pointer.x >= 0 && pointer.y >= 0 && pointer.y <= window.frame.height
        facts.pointerAtEdge = inWindow && pointer.x <= Self.edgeWidth
        // A few points of slack past the right edge, so resting on the width strip counts.
        facts.pointerInside = inWindow && pointer.x <= state.sidebarWidth + 4
        return facts
    }

    private func watchMenus() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = false }
            },
        ]
    }
}

// MARK: - The edge strip

/// A thin invisible strip at the window's left edge, there only while the sidebar is hidden. It
/// lies in the margin left of the page, never over it, and only watches the pointer: it takes no
/// clicks, scrolls or drops (`hitTest` gives nil).
struct SidebarEdgeTrigger: NSViewRepresentable {
    let entered: () -> Void

    func makeNSView(context: Context) -> EdgeView {
        let view = EdgeView()
        view.entered = entered
        return view
    }

    func updateNSView(_ view: EdgeView, context: Context) {
        view.entered = entered
    }

    final class EdgeView: NSView {
        var entered: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // `.mouseMoved` as well: a pointer that was already in the strip when the sidebar was
            // hidden never "enters" it.
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { entered?() }
        override func mouseMoved(with event: NSEvent) { entered?() }
    }
}

// MARK: - The width strip

/// The strip along the sidebar's right edge that drags its width. AppKit, because its top end
/// lies in the window's invisible title-bar strip, where macOS starts a window drag before asking
/// the view: as `PaneDragHandleView` does, the window's `isMovable` is switched off while the
/// pointer is over it. (And no SwiftUI `.help()` here: it adds a view that eats the click.)
struct SidebarResizeHandle: NSViewRepresentable {
    /// The width when a drag starts.
    let width: Double
    /// A new width while dragging (not yet clamped).
    let dragged: (Double) -> Void
    let ended: () -> Void
    /// Double-click: back to the default width.
    let reset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        update(view)
    }

    private func update(_ view: HandleView) {
        view.width = width
        view.dragged = dragged
        view.ended = ended
        view.reset = reset
    }

    final class HandleView: NSView {
        var width: Double = SidebarLayout.defaultWidth
        var dragged: ((Double) -> Void)?
        var ended: (() -> Void)?
        var reset: (() -> Void)?
        /// Where the drag began: the pointer's x in the window and the width then.
        private var start: (x: CGFloat, width: Double)?
        /// The window whose `isMovable` we switched off (so we can always switch it back on).
        private weak var pinnedWindow: NSWindow?

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            window.isMovable = false
            pinnedWindow = window
        }

        override func mouseExited(with event: NSEvent) {
            // Not in the middle of a drag: the pointer runs ahead of the strip then.
            if start == nil { releaseWindow() }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { releaseWindow() }
        }

        private func releaseWindow() {
            pinnedWindow?.isMovable = true
            pinnedWindow = nil
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                start = nil
                reset?()
            } else {
                start = (event.locationInWindow.x, width)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            dragged?(start.width + Double(event.locationInWindow.x - start.x))
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            ended?()
            // The pointer may have left the strip during the drag without a mouse-exited we acted on.
            if let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { releaseWindow() }
        }
    }
}
