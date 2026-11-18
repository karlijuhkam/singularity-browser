import Foundation

/// A window's place on screen, in screen coordinates (AppKit's: origin at the bottom left).
public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One browser window as `state.json` keeps it (spec 2026-11-18-multi-window-design.md).
///
/// Tabs belong to Spaces, never to windows: a window only says which Space it shows, which tab
/// it has selected in each Space it showed, whether its sidebar is hidden, and where it was.
/// While a window is the front one, the app's live fields (`AppState.selectedSpaceID`, each
/// `Space.selectedTabID`) are its truth and this record is brought up to date on save and swap.
public struct BrowserWindowState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The Space this window shows; nil only while there is no Space at all.
    public var spaceID: UUID?
    /// Space id → the tab this window has selected there.
    public var selectedTabIDs: [UUID: UUID]
    public var sidebarHidden: Bool
    /// nil = let macOS place the window.
    public var frame: WindowFrame?

    public init(id: UUID = UUID(), spaceID: UUID? = nil, selectedTabIDs: [UUID: UUID] = [:],
                sidebarHidden: Bool = false, frame: WindowFrame? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.selectedTabIDs = selectedTabIDs
        self.sidebarHidden = sidebarHidden
        self.frame = frame
    }

    /// The tab this window has selected in the Space it shows.
    public var selectedTabID: UUID? {
        spaceID.flatMap { selectedTabIDs[$0] }
    }

    private enum CodingKeys: String, CodingKey { case id, spaceID, selectedTabIDs, sidebarHidden, frame }

    // `[UUID: UUID]` would be written as a flat array of keys and values (JSON objects need
    // string keys), so the map is written as `{"<space id>": "<tab id>"}` instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spaceID = try container.decodeIfPresent(UUID.self, forKey: .spaceID)
        let raw = (try? container.decodeIfPresent([String: String].self, forKey: .selectedTabIDs)) ?? [:]
        var map: [UUID: UUID] = [:]
        for (key, value) in raw {
            if let space = UUID(uuidString: key), let tab = UUID(uuidString: value) { map[space] = tab }
        }
        selectedTabIDs = map
        sidebarHidden = try container.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
        frame = try? container.decodeIfPresent(WindowFrame.self, forKey: .frame)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(spaceID, forKey: .spaceID)
        var raw: [String: String] = [:]
        for (space, tab) in selectedTabIDs { raw[space.uuidString] = tab.uuidString }
        try container.encode(raw, forKey: .selectedTabIDs)
        try container.encode(sidebarHidden, forKey: .sidebarHidden)
        try container.encodeIfPresent(frame, forKey: .frame)
    }
}

/// The rules that keep several windows apart. Pure: the app calls them after every change.
///
/// The one rule that matters: a tab is on screen in one window at most (its web view or terminal
/// view can only be in one place). The front window always wins; every other window that would
/// show the same tab (or a tab of the same split) moves to a free neighbour, or shows nothing.
public enum WindowLayout {
    /// What a window with `selected` selected in `space` shows: the tab and its whole split.
    public static func shownTabIDs(in space: Space, selected: UUID?) -> Set<UUID> {
        guard let selected, space.tab(selected) != nil else { return [] }
        return Set(space.splitGroup(containing: selected)?.root.tabIDs ?? [selected])
    }

    /// The tab a window should select in `space` when the tabs in `taken` are on screen elsewhere:
    /// `preferring` while it (with its split) is free, else the nearest free tab after it in sidebar
    /// order, then before it; without a usable `preferring`, the first free tab. nil when none is free.
    public static func freeTab(in space: Space, preferring: UUID?, taken: Set<UUID>) -> UUID? {
        func isFree(_ id: UUID) -> Bool { shownTabIDs(in: space, selected: id).isDisjoint(with: taken) }
        let order = space.tabsInSidebarOrder.map(\.id)
        guard let preferring, let position = order.firstIndex(of: preferring) else {
            return order.first(where: isFree)
        }
        if isFree(preferring) { return preferring }
        if let after = order[(position + 1)...].first(where: isFree) { return after }
        return order[..<position].reversed().first(where: isFree)
    }

    /// Fixes every window except the front one: a Space that is gone becomes the first Space; a
    /// selection that is gone or on screen in the front window (or an earlier window, in order)
    /// moves to `freeTab`; entries for Spaces or tabs that no longer exist are dropped. The front
    /// window's record is returned as it was: its truth is the live fields passed in.
    public static func reconcile(_ windows: [BrowserWindowState], frontID: UUID?, frontSpaceID: UUID?,
                                 frontSelected: UUID?, spaces: [Space]) -> [BrowserWindowState] {
        let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Space id → the tabs on screen in windows already settled.
        var taken: [UUID: Set<UUID>] = [:]
        if let frontSpaceID, let space = byID[frontSpaceID] {
            taken[frontSpaceID] = shownTabIDs(in: space, selected: frontSelected)
        }
        var result = windows
        for index in result.indices where result[index].id != frontID {
            var window = result[index]
            if window.spaceID.flatMap({ byID[$0] }) == nil { window.spaceID = spaces.first?.id }
            window.selectedTabIDs = window.selectedTabIDs.filter { spaceID, tabID in
                byID[spaceID]?.tab(tabID) != nil
            }
            if let spaceID = window.spaceID, let space = byID[spaceID] {
                let current = window.selectedTabIDs[spaceID]
                let needsMove = current == nil
                    || !shownTabIDs(in: space, selected: current).isDisjoint(with: taken[spaceID] ?? [])
                // A window whose tab vanished keeps showing something when it can; one that never
                // had a tab here (an empty Space shown) is left empty until the owner picks one.
                let hadSelection = windows[index].selectedTabIDs[spaceID] != nil
                if needsMove && (current != nil || hadSelection) {
                    window.selectedTabIDs[spaceID] = freeTab(in: space, preferring: current, taken: taken[spaceID] ?? [])
                }
                taken[spaceID, default: []].formUnion(shownTabIDs(in: space, selected: window.selectedTabIDs[spaceID]))
            }
            result[index] = window
        }
        return result
    }
}
