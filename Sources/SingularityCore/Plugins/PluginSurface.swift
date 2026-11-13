import Foundation

/// Size rules for the panel that shows a plugin's page beside the web page.
public enum PluginPanelLayout {
    public static let defaultWidth: Double = 380
    public static let minWidth: Double = 300
    public static let maxWidth: Double = 720

    /// A width the panel can have; anything that isn't a number becomes the default.
    public static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minWidth), maxWidth)
    }

    /// The page beside the panel keeps at least this much.
    public static let minPageWidth: Double = 320
    /// Narrower than this, the panel isn't drawn at all.
    public static let minShownWidth: Double = 200

    /// The width the panel is drawn at: its own width (`width`, clamped as above), but never so
    /// wide that the page gets less than `minPageWidth` in a window `windowWidth` wide whose
    /// sidebar takes `sidebarWidth`. Not below `minWidth` while the window has room for both; in a
    /// window too narrow for that, whatever is left after the page's 320, and nil (not drawn) when
    /// that is under `minShownWidth`. Only for drawing: the stored width stays as it is.
    public static func shownWidth(_ width: Double, windowWidth: Double, sidebarWidth: Double) -> Double? {
        let room = windowWidth - sidebarWidth - minPageWidth
        guard room.isFinite else { return clamp(width) }
        if room >= minWidth { return min(clamp(width), room) }
        return room >= minShownWidth ? room : nil
    }
}

/// Where a plugin's page is shown right now.
public enum PluginPagePlace: Equatable, Sendable {
    case hidden
    case panel
    case tab(space: UUID, tab: UUID)
}

/// Pure rules about a plugin's page: one page per plugin, a tab wins over the panel.
public enum PluginSurface {
    /// A tab wins over the panel. With several tabs (should not happen), the first in Space order.
    public static func place(of pluginID: String, panel: String?, spaces: [Space]) -> PluginPagePlace {
        for space in spaces {
            if let tab = space.tabs.first(where: { $0.pluginID == pluginID }) {
                return .tab(space: space.id, tab: tab.id)
            }
        }
        return panel == pluginID ? .panel : .hidden
    }

    /// Every tab of this plugin in the Space, so the caller can keep at most one.
    public static func tabsToRemove(for pluginID: String, in space: Space) -> [UUID] {
        space.tabs.filter { $0.pluginID == pluginID }.map(\.id)
    }

    /// While there is no page: is it on its way, so the page area says "starting" rather than why
    /// it doesn't run? Yes while the first look at the plugins folder hasn't finished and the
    /// plugin isn't known yet (`plugin` nil), and while a known plugin should run (`.launch`) and
    /// its background is not up yet (`.stopped`, or `.running` before the page is made). A plugin
    /// that isn't approved, is off, or failed has its own status text instead.
    public static func pageIsStarting(firstScanDone: Bool,
                                      plugin: (decision: PluginLaunch.Decision, run: PluginSupervisor.State)?) -> Bool {
        guard let plugin else { return !firstScanDone }
        guard plugin.decision == .launch else { return false }
        return plugin.run == .stopped || plugin.run == .running
    }
}
