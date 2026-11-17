import Foundation

/// The rules of a Space's home (spec docs/superpowers/specs/2026-11-17-space-home-design.md):
/// which home ⌘T reuses, which new tab takes a home's place, the order of the Terminals section,
/// the "(new)" mark and the Recent list. Pure; the app only feeds and shows them.
public enum HomeRules {
    /// The Space's home tab ⌘T selects instead of making another: the first one in `tabs`.
    public static func reusableHome(in space: Space) -> UUID? {
        space.tabs.first(where: \.isHome)?.id
    }

    /// After an action started from a home: the tab that should take the home's place. That is the
    /// selected tab when it didn't exist before the action (`before`: the tab ids then) and is not
    /// a home itself; going to an existing tab, or nothing selected, replaces nothing.
    public static func tabToReplaceHome(before: Set<UUID>, after space: Space) -> UUID? {
        guard let selected = space.selectedTab, !before.contains(selected.id), !selected.isHome else { return nil }
        return selected.id
    }

    /// The Terminals section's order: waiting, working, done, idle, unknown; within a state the
    /// newest `since` first.
    public static func terminalOrder(_ rows: [(id: UUID, state: TerminalBoard.State, since: Date)]) -> [UUID] {
        func rank(_ state: TerminalBoard.State) -> Int {
            switch state {
            case .waiting: return 0
            case .working: return 1
            case .done: return 2
            case .idle: return 3
            case .unknown: return 4
            }
        }
        return rows.enumerated().sorted { a, b in
            let ra = rank(a.element.state), rb = rank(b.element.state)
            if ra != rb { return ra < rb }
            if a.element.since != b.element.since { return a.element.since > b.element.since }
            return a.offset < b.offset
        }.map(\.element.id)
    }

    /// A row is "(new)" when its state changed after the owner last left this Space's home.
    /// Never before the first visit (`lastLeft` nil). The times live in memory only.
    public static func isNew(since: Date, lastLeft: Date?) -> Bool {
        guard let lastLeft else { return false }
        return since > lastLeft
    }

    /// The Recent section: the files changed most recently, newest first, at most `limit`.
    public static func recent(_ files: [HomeRecentFile], limit: Int = 8) -> [HomeRecentFile] {
        Array(files.sorted { $0.modified > $1.modified }.prefix(max(0, limit)))
    }
}

/// One file the home's Recent section can list: a note, an artifact page or an app.
public struct HomeRecentFile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case note, artifact, app }

    public let kind: Kind
    /// Relative to the Space's `notes/` or `artifacts/` folder.
    public let path: String
    public let modified: Date

    public init(kind: Kind, path: String, modified: Date) {
        self.kind = kind
        self.path = path
        self.modified = modified
    }
}

extension Space {
    /// The tab `newTabID` takes the place of the home `homeID`: its row in `tabs`, its pin and
    /// folder, its pane in a split. The home is removed and the new tab selected. Changes nothing
    /// when either id is missing, or `homeID` isn't a home.
    public mutating func replaceHome(_ homeID: UUID, with newTabID: UUID) {
        guard homeID != newTabID, let home = tab(homeID), home.isHome,
              let newIndex = tabs.firstIndex(where: { $0.id == newTabID }) else { return }
        var newTab = tabs.remove(at: newIndex)
        newTab.isPinned = home.isPinned
        newTab.folderID = home.folderID
        guard let homeIndex = tabs.firstIndex(where: { $0.id == homeID }) else { return }
        tabs.insert(newTab, at: homeIndex)
        // The new tab shows in the home's pane (it leaves any other split first). If both were in
        // the same split this swaps them, so the home is taken out of the split after.
        replaceInSplit(homeID, with: newTabID)
        removeFromSplit(homeID)
        tabs.removeAll { $0.id == homeID }
        selectedTabID = newTabID
    }
}
