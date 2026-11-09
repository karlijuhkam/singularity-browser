import Foundation

/// What a tab shows. Phase 1 only has web pages; terminals and artifacts are added as new cases later.
public enum TabKind: Codable, Hashable, Sendable {
    case web(url: URL)
}

/// A tab belongs to exactly one Space. Its position in the sidebar is determined by
/// `isPinned` and `folderID` (see `SidebarSection`) plus its order in `Space.tabs`.
public struct BrowserTab: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: TabKind
    public var title: String
    public var isPinned: Bool
    /// When set, the tab is shown inside that folder (regardless of `isPinned`).
    public var folderID: UUID?

    public init(id: UUID = UUID(), kind: TabKind, title: String = "", isPinned: Bool = false, folderID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isPinned = isPinned
        self.folderID = folderID
    }

    public static func web(_ url: URL, title: String = "") -> BrowserTab {
        BrowserTab(kind: .web(url: url), title: title)
    }

    public var url: URL? {
        switch kind {
        case .web(let url): return url
        }
    }

    /// Title to show in the UI: the page title, else the host, else the raw URL.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host(), !host.isEmpty { return host }
        return url?.absoluteString ?? "New Tab"
    }

    public var section: SidebarSection {
        if let folderID { return .folder(folderID) }
        return isPinned ? .pinned : .open
    }
}

/// The three places a tab can live in the sidebar, top to bottom.
public enum SidebarSection: Hashable, Sendable {
    case pinned
    case folder(UUID)
    case open
}
