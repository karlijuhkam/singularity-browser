import AppKit
import SingularityCore
import SwiftUI

extension InboxCenter {
    /// Opens the inbox beside the rail's tray button.
    /// - Parameter takingFocus: true when the owner opened it (tray, menu, shortcut, palette);
    ///   false when the app opens it by itself.
    func showPanel(takingFocus: Bool) {
        let wasShown = isPanelShown
        panelController.show(relativeTo: railAnchor, takingFocus: takingFocus)
        // Just appeared, maybe under a click meant for the window: answers wait a moment.
        if !wasShown, isPanelShown { panelAppeared() }
    }

    func closePanel() {
        panelController.close()
    }

    /// A button on a card was pressed.
    func perform(_ action: InboxCardAction) {
        switch action {
        case .goTo(let entry): goTo(entry)
        case .dismiss(let id): dismiss(id)
        case .decideApproval(let id, let outcome): answerFromCard(id, outcome)
        case .showApprovalTab(let id): showApprovalTab(id)
        case .answerQuestion(let id, let answers): answerQuestionFromCard(id, answers: answers)
        case .decidePermission(let id, let allow): decidePermissionFromCard(id, allow: allow)
        }
    }
}

/// The inbox's floating panel: a borderless `NSPanel`, child of the main window, 330 pt wide,
/// as tall as its cards up to 70 % of the window, then the cards scroll.
///
/// Why a panel and not a SwiftUI `.popover`: a popover takes key focus when it opens. The inbox
/// also opens by itself (a browser approval arrives while the owner types in a page or terminal),
/// and then it must not take the keyboard: a Return or Space meant for the terminal must never
/// press a button in it (see the spec's "Keyboard and the self-opening panel"). A non-activating
/// panel can be shown without becoming key, and we decide when it may become key.
@MainActor
final class InboxPanelController {
    static let width: CGFloat = 330
    /// The panel is at most this share of the window's height.
    static let maxHeightShare: CGFloat = 0.7
    /// Gap between the tray button and the panel.
    static let gap: CGFloat = 6

    private weak var center: InboxCenter?
    private var inboxPanel: InboxPanel?
    var panel: NSPanel? { inboxPanel }

    /// The window the panel belongs to when it is opened without the tray button (menu, palette).
    /// Tests replace it.
    var parentWindow: () -> NSWindow? = {
        NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
    }
    /// The panel is made key only while the app is active: a non-activating panel could otherwise
    /// take the keyboard from another app. Tests replace it.
    var appIsActive: () -> Bool = { NSApp.isActive }

    private(set) var isShown = false
    /// Height of the panel's content without scrolling, as SwiftUI last measured it.
    private(set) var contentHeight: CGFloat = 0

    private weak var anchor: NSView?
    private weak var parent: NSWindow?
    private var mouseMonitor: Any?
    private var parentObservers: [NSObjectProtocol] = []

    init(center: InboxCenter) {
        self.center = center
    }

    func show(relativeTo anchor: NSView?, takingFocus: Bool) {
        guard let center else { return }
        // The tray button's window when it is on screen (it is not while the welcome flow covers
        // the window), else the main window.
        let anchor = anchor?.window == nil ? nil : anchor
        guard let parent = anchor?.window ?? parentWindow() else { return }
        let panel = inboxPanel ?? makePanel(center: center)
        inboxPanel = panel

        if isShown, self.parent !== parent { detach() }
        self.anchor = anchor
        if !isShown {
            self.parent = parent
            // Opened by itself, it may never become key (not even when clicked); opened by the
            // owner, it may. Already open: the owner's request upgrades it, the app's never downgrades.
            panel.allowsKey = takingFocus
            layoutPanel()
            // A child window moves with its parent and always stays just above it.
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            installMonitors()
            isShown = true
        } else {
            if takingFocus { panel.allowsKey = true }
            layoutPanel()
        }
        if takingFocus, appIsActive() {
            panel.makeKey()
        }
        center.isPanelShown = true
    }

    func close() {
        defer { center?.isPanelShown = false }
        guard isShown else { return }
        let wasKey = inboxPanel?.isKeyWindow ?? false
        let parent = self.parent
        detach()
        // Hand the keyboard back to the window it came from.
        if wasKey { parent?.makeKey() }
    }

    /// Takes the panel off screen without touching the inbox's state.
    private func detach() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        for observer in parentObservers { NotificationCenter.default.removeObserver(observer) }
        parentObservers = []
        if let panel = inboxPanel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.allowsKey = false
        }
        parent = nil
        isShown = false
    }

    // MARK: The panel

    private func makePanel(center: InboxCenter) -> InboxPanel {
        let panel = InboxPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Transparent window; the rounded material view below is what you see, and the shadow
        // follows its shape.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in self?.close() }

        // The same translucent material as menus and popovers, in light and dark mode.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 10)

        let content = InboxPanelContent(center: center) { [weak self] height in
            self?.contentHeightChanged(height)
        }
        let hosting = FirstClickHostingView(rootView: content)
        // The panel's size is set here (layoutPanel), not by the SwiftUI content.
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background
        return panel
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height != contentHeight else { return }
        contentHeight = height
        // SwiftUI reports this during its own layout pass; resize the window right after it.
        DispatchQueue.main.async { [weak self] in self?.layoutPanel() }
    }

    /// Size and place: top-left `gap` pt right of the tray button, tops level; without the button,
    /// at the same spot measured from the window's top-left corner.
    private func layoutPanel() {
        guard let panel = inboxPanel, let parent else { return }
        let cap = (parent.frame.height * Self.maxHeightShare).rounded(.down)
        let height = min(max(contentHeight, 44), cap)
        let topLeft: NSPoint
        if let anchor, anchor.window === parent {
            let onScreen = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            topLeft = NSPoint(x: onScreen.maxX + Self.gap, y: onScreen.maxY)
        } else {
            // From `SidebarView`: the rail is 48 pt wide (`SpaceRail().frame(width: 48)`) and
            // starts below the 40 pt navigation row, plus the rail's 2 pt top padding.
            topLeft = NSPoint(x: parent.frame.minX + 48 + Self.gap, y: parent.frame.maxY - 42)
        }
        let frame = NSRect(x: topLeft.x, y: topLeft.y - height, width: Self.width, height: height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: Closing on a click elsewhere

    private func installMonitors() {
        // A "local monitor" sees every mouse-down of this app before the window gets it.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { _ = self?.handleMouseDown(event) }
            return event
        }
        // The panel stays beside the button when the window is resized (a child window keeps its
        // offset from the parent's bottom-left corner, not the top).
        if let parent {
            parentObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutPanel() }
            })
        }
    }

    /// A click in the main window outside the panel closes it, except one on the tray button
    /// (the button itself toggles the panel). The click always goes on to where it was aimed.
    func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard isShown, let parent, event.window === parent else { return event }
        if let anchor, anchor.window === parent {
            let point = anchor.convert(event.locationInWindow, from: nil)
            if anchor.bounds.contains(point) { return event }
        }
        close()
        return event
    }

    /// A rounded rectangle that stretches without distorting its corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The panel window. Borderless windows cannot become key by default; this one can, but only
/// while `allowsKey` is set (the owner opened it). Esc closes it and goes nowhere else.
final class InboxPanel: NSPanel {
    var allowsKey = false
    var onEscape: () -> Void = {}

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // 53 = Esc. Handled here, before any view, so it never reaches a terminal or a page.
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}

/// A hosting view whose buttons work on the first click, also while the panel is not key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the panel shows: the header, then the cards in a scroll view. Reports its full height
/// (header plus every card) so the controller can size the window.
///
/// Holds the inbox weakly: the inbox owns the panel, the panel this view, so a strong reference
/// here would keep both alive for ever. (Observation still sees what `body` reads through it.)
struct InboxPanelContent: View {
    weak var center: InboxCenter?
    let onHeightChange: (CGFloat) -> Void
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            InboxHeader(workingCount: center?.inbox.workingCount ?? 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                InboxListView(center: center, onAction: { [weak center] in center?.perform($0) })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: InboxPanelController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: headerHeight + listHeight, initial: true) { _, total in
            if headerHeight > 0, listHeight > 0 { onHeightChange(total.rounded(.up)) }
        }
    }
}
