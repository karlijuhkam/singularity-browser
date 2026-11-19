import Foundation

/// What a terminal tab's pane shows (its own terminal or one of its herdr-core children) and
/// what the sidebar highlights for it. The same rules hold for a tab's own row and for its chip
/// in a split's row, so a tab in a split can always be brought back to its own terminal.
/// Spec: `docs/superpowers/specs/2026-11-16-herdr-child-terminals-design.md`.
public enum HerdrShown {
    /// A tab's own row or chip is highlighted only while its own terminal is what its pane shows.
    public static func ownIsHighlighted(isSelected: Bool, shownChild: String?) -> Bool {
        isSelected && shownChild == nil
    }

    /// A child row is highlighted while its tab's pane is on screen and shows that child.
    /// (For a tab in a split: while the split is on screen, whichever pane is focused.)
    public static func childIsHighlighted(tabIsOnScreen: Bool, shownChild: String?, address: String) -> Bool {
        tabIsOnScreen && shownChild == address
    }

    /// A click on a tab's own place in the sidebar (its row, or its chip in a split's row) brings
    /// its own terminal back. A click inside a pane does not: that is typing to the child.
    public static func afterOwnClick(_ shown: [UUID: String], tabID: UUID) -> [UUID: String] {
        var shown = shown
        shown[tabID] = nil
        return shown
    }
}
