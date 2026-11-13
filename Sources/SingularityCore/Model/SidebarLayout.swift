import Foundation

/// The sidebar's width (Settings: `sidebarWidth`; dragged at its right edge).
public enum SidebarLayout {
    public static let defaultWidth: Double = 270
    public static let minWidth: Double = 220
    public static let maxWidth: Double = 480

    /// A width the sidebar can have; anything that isn't a number becomes the default.
    public static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minWidth), maxWidth)
    }
}

/// What the slide-out's rules look at. The slide-out is the hidden sidebar shown over the page
/// while the pointer is at the window's left edge (as in Arc).
public struct SidebarPeekFacts: Equatable, Sendable {
    /// The sidebar is hidden (View → Hide Sidebar).
    public var hidden = true
    /// The browser window is the key window.
    public var windowIsKey = true
    /// Something covers the window: the welcome flow or a sheet.
    public var covered = false
    /// The pointer is in the thin strip at the window's left edge.
    public var pointerAtEdge = false
    /// The pointer is over the slid-out sidebar.
    public var pointerInside = false
    /// A context menu or pull-down is open.
    public var menuOpen = false
    /// A mouse button is held down: a tab is being dragged out of the sidebar, or its width dragged.
    public var mouseButtonDown = false
    /// The inbox panel is open beside the sidebar's tray button.
    public var inboxOpenFromTray = false

    public init() {}
}

/// When the slide-out opens and when it stays. Pure, so the rules have tests; the app feeds it.
public enum SidebarPeek {
    /// Only the pointer reaching the edge opens it, and only in the key window with nothing over it.
    public static func shouldOpen(_ facts: SidebarPeekFacts) -> Bool {
        facts.hidden && facts.windowIsKey && !facts.covered && facts.pointerAtEdge
    }

    /// Once open it must not close under the owner's hand: not while the pointer is in it, a menu
    /// from it is showing, a drag that began in it is in the air, or the inbox panel hangs off its
    /// tray button (the panel can be the key window then, so that case doesn't ask for key).
    public static func shouldStay(_ facts: SidebarPeekFacts) -> Bool {
        guard facts.hidden, !facts.covered else { return false }
        if facts.inboxOpenFromTray { return true }
        guard facts.windowIsKey else { return false }
        return facts.pointerInside || facts.pointerAtEdge || facts.menuOpen || facts.mouseButtonDown
    }
}
