import Foundation

/// What a tab shows.
public enum TabKind: Codable, Hashable, Sendable {
    case web(url: URL)
    /// A login shell. `workingDirectory` is where it starts (stored with `~` unexpanded) and is
    /// updated as the shell moves, so a restored terminal reopens in its last directory.
    /// The process itself is not restored: a fresh shell starts when the tab is first shown.
    case terminal(workingDirectory: String)
    /// A locally generated HTML file. `path` is relative to the Space's `artifacts/` folder
    /// (e.g. "report/index.html"). It is served by the Space's local server, never via file://;
    /// the server's port changes on every launch, so only the path is stored.
    case artifact(path: String)
    /// A plugin's own page (its manifest `panel`), shown as a tab. Only the plugin's id is stored;
    /// the page itself is found again from the plugin folder at launch.
    case plugin(pluginID: String)
    /// A note: a Markdown file, edited in Singularity's own editor. `path` is relative to the
    /// Space's `notes/` folder (e.g. "Journal/2026-11-16.md"); see NoteFiles.swift.
    case note(path: String)
    /// The Space's home: what a new tab (⌘T) opens as. Native, nothing stored beyond the kind; the
    /// moment it becomes something else it is no longer a home (see HomeRules.swift).
    case home
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
    /// The tab was opened by an agent (shown with an agent badge in the sidebar).
    public var openedByAgent: Bool
    /// For a terminal: the project it was started in (see Project.swift). Stored, because the
    /// terminal's `workingDirectory` follows the shell as it moves and so can't tell.
    public var projectID: UUID?

    public init(id: UUID = UUID(), kind: TabKind, title: String = "", isPinned: Bool = false, folderID: UUID? = nil,
                openedByAgent: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isPinned = isPinned
        self.folderID = folderID
        self.openedByAgent = openedByAgent
    }

    /// Decoding by hand so files written before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TabKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        openedByAgent = try container.decodeIfPresent(Bool.self, forKey: .openedByAgent) ?? false
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
    }

    public static func web(_ url: URL, title: String = "") -> BrowserTab {
        BrowserTab(kind: .web(url: url), title: title)
    }

    public static func terminal(workingDirectory: String) -> BrowserTab {
        BrowserTab(kind: .terminal(workingDirectory: workingDirectory))
    }

    public static func artifact(path: String) -> BrowserTab {
        BrowserTab(kind: .artifact(path: path))
    }

    /// A tab for a plugin's page. `title` is the manifest's panel title when it is known.
    public static func plugin(pluginID: String, title: String = "") -> BrowserTab {
        BrowserTab(kind: .plugin(pluginID: pluginID), title: title)
    }

    /// A tab for a note file (`path` inside the Space's `notes/` folder).
    public static func note(path: String) -> BrowserTab {
        BrowserTab(kind: .note(path: path), title: NoteFiles.title(ofPath: path))
    }

    /// The Space's home tab (⌘T).
    public static func home() -> BrowserTab {
        BrowserTab(kind: .home, title: "Home")
    }

    /// The page URL for web tabs; nil for other kinds.
    public var url: URL? {
        switch kind {
        case .web(let url): return url
        case .terminal, .artifact, .plugin, .note, .home: return nil
        }
    }

    /// The directory for terminal tabs; nil for other kinds.
    public var workingDirectory: String? {
        switch kind {
        case .web, .artifact, .plugin, .note, .home: return nil
        case .terminal(let directory): return directory
        }
    }

    /// The path inside the artifacts folder for artifact tabs; nil for other kinds.
    public var artifactPath: String? {
        switch kind {
        case .artifact(let path): return path
        case .web, .terminal, .plugin, .note, .home: return nil
        }
    }

    /// The plugin's id for plugin tabs; nil for other kinds.
    public var pluginID: String? {
        if case .plugin(let id) = kind { return id }
        return nil
    }

    /// The path inside the notes folder for note tabs; nil for other kinds.
    public var notePath: String? {
        if case .note(let path) = kind { return path }
        return nil
    }

    public var isTerminal: Bool { workingDirectory != nil }
    public var isArtifact: Bool { artifactPath != nil }
    public var isPlugin: Bool { pluginID != nil }
    public var isNote: Bool { notePath != nil }
    public var isHome: Bool { kind == .home }
    /// Tabs no agent tool lists, reads or acts on: a plugin's own page, the owner's notes and the
    /// Space's home. `front` never names the first two; a home it names by kind only.
    public var isHiddenFromAgents: Bool { isPlugin || isNote || isHome }

    /// Title to show in the UI: the page title, else the host, else the raw URL.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        return untitledDisplayTitle
    }

    /// What `displayTitle` falls back to without a page title: the address's host, the file name…
    public var untitledDisplayTitle: String {
        if isTerminal { return "Terminal" }
        if isHome { return "Home" }
        if let artifactPath { return (artifactPath as NSString).lastPathComponent }
        if let pluginID { return pluginID }
        if let notePath { return NoteFiles.title(ofPath: notePath) }
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
