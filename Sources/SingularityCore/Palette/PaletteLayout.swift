import Foundation

/// Where the command palette sits in the window: centred over the page, not the whole window,
/// so with the sidebar open (or a plugin's panel at the right) it is still in the middle of
/// what the owner is looking at.
public enum PaletteLayout {
    /// The palette's width when the page has room for it.
    public static let preferredWidth: Double = 640
    /// Kept free between the palette and the page's edges.
    public static let margin: Double = 16
    /// A page that can't fit a palette this wide (plus the margins) is too narrow to centre
    /// over; the palette is then centred over the whole window.
    public static let minWidth: Double = 360

    public struct Frame: Equatable, Sendable {
        /// From the window's left edge.
        public var x: Double
        public var width: Double
    }

    /// The palette's left edge and width in a window `windowWidth` wide whose page starts
    /// `pageLeading` from the window's left edge and ends `pageTrailing` from its right edge.
    public static func frame(windowWidth: Double, pageLeading: Double, pageTrailing: Double) -> Frame {
        guard windowWidth.isFinite, pageLeading.isFinite, pageTrailing.isFinite, windowWidth > 0 else {
            return Frame(x: 0, width: preferredWidth)
        }
        let leading = max(pageLeading, 0)
        let pageWidth = windowWidth - leading - max(pageTrailing, 0)
        if pageWidth - 2 * margin >= minWidth {
            let width = min(preferredWidth, pageWidth - 2 * margin)
            return Frame(x: leading + (pageWidth - width) / 2, width: width)
        }
        let width = min(preferredWidth, max(windowWidth - 2 * margin, 0))
        return Frame(x: (windowWidth - width) / 2, width: width)
    }
}
