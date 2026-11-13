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
}
