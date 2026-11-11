import Foundation

/// The organising unit of the browser. Each Space has its own folder on disk, its own
/// website data store (cookies, storage), and its own tabs.
public struct Space: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// URL-safe name used for the folder on disk and the MCP tool names ("work.list_tabs").
    /// Fixed at creation: renaming a Space only changes `name`. The one exception: the Space a
    /// brand-new install makes at its first launch takes the name chosen in the welcome flow's
    /// Space step, slug included, while it has no tabs (`FirstRun.mayReslug`, `AppState.applyWelcomeSpace`).
    public var slug: String
    /// Colour as "#RRGGBB".
    public var colorHex: String
    /// Default working directory for terminal tabs (Phase 2). Stored with `~` unexpanded.
    public var workingDirectory: String
    public var folders: [Folder]
    /// All tabs in this Space. Order within each sidebar section is the order in this array.
    public var tabs: [BrowserTab]
    public var selectedTabID: UUID?
    /// Whether external agents may see and control this Space through the MCP server.
    /// Off by default; switched on per Space in the Space settings.
    public var agentsEnabled: Bool
    /// What agents may do without asking (when `agentsEnabled`). Default: ask before acting.
    public var agentPolicy: AgentPolicy
    /// Remembered split views (see SplitLayout.swift). A tab is in at most one.
    public var splits: [SplitGroup]
    /// "Let agents see console and network" for this Space (off by default). A site must be
    /// switched on as well (`SiteSettings.agentsCanInspect`); see `InspectionRules`.
    public var agentInspection: Bool
    /// The owner's per-site choices (camera, microphone, agents, plugins), keyed by site
    /// ("https://example.com"). Sites with nothing chosen are not listed.
    public var siteSettings: [String: SiteSettings]

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        colorHex: String,
        workingDirectory: String = "~",
        folders: [Folder] = [],
        tabs: [BrowserTab] = [],
        selectedTabID: UUID? = nil,
        agentsEnabled: Bool = false,
        agentPolicy: AgentPolicy = .ask,
        splits: [SplitGroup] = [],
        agentInspection: Bool = false,
        siteSettings: [String: SiteSettings] = [:]
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.colorHex = colorHex
        self.workingDirectory = workingDirectory
        self.folders = folders
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.agentsEnabled = agentsEnabled
        self.agentPolicy = agentPolicy
        self.splits = splits
        self.agentInspection = agentInspection
        self.siteSettings = siteSettings
    }

    /// Decoding by hand so that space.json files written before a field existed still load
    /// (a missing field gets its default instead of failing the whole file).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "~"
        folders = try container.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        tabs = try container.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? []
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        agentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentsEnabled) ?? false
        agentPolicy = try container.decodeIfPresent(AgentPolicy.self, forKey: .agentPolicy) ?? .ask
        splits = try container.decodeIfPresent([SplitGroup].self, forKey: .splits) ?? []
        agentInspection = try container.decodeIfPresent(Bool.self, forKey: .agentInspection) ?? false
        siteSettings = (try? container.decodeIfPresent([String: SiteSettings].self, forKey: .siteSettings)) ?? [:]
    }

    // MARK: - Reading

    public func tab(_ id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    public var selectedTab: BrowserTab? {
        selectedTabID.flatMap { tab($0) }
    }

    public func tabs(in section: SidebarSection) -> [BrowserTab] {
        tabs.filter { $0.section == section }
    }

    /// Tabs in the order they appear in the sidebar: pinned, then the folders, then open tabs.
    public var tabsInSidebarOrder: [BrowserTab] {
        sidebarSections.flatMap { tabs(in: $0) }
    }

    /// The sidebar's sections from top to bottom. A folder shows the folders inside it first and
    /// its own tabs after them, so its section comes after those of the folders inside it.
    public var sidebarSections: [SidebarSection] {
        var result: [SidebarSection] = [.pinned]
        func visit(_ parentID: UUID?) {
            for folder in childFolders(of: parentID) {
                visit(folder.id)
                result.append(.folder(folder.id))
            }
        }
        visit(nil)
        return result + [.open]
    }

    // MARK: - Folders (a tree: see `Folder.parentID`)

    public func folder(_ id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    /// The folders directly inside a folder, or the top-level ones for nil. A folder whose parent
    /// no longer exists counts as top-level, so it can never disappear from the sidebar.
    public func childFolders(of parentID: UUID?) -> [Folder] {
        folders.filter { child in
            let parent = child.parentID.flatMap { folder($0) }?.id
            return parent == parentID
        }
    }

    /// Every folder with how deep it is nested (0 = top level), parents before their children.
    public var foldersInTreeOrder: [(folder: Folder, depth: Int)] {
        var result: [(folder: Folder, depth: Int)] = []
        func visit(_ parentID: UUID?, _ depth: Int) {
            for folder in childFolders(of: parentID) {
                result.append((folder, depth))
                visit(folder.id, depth + 1)
            }
        }
        visit(nil, 0)
        return result
    }

    /// "Outer / Inner": a folder's name with the folders it is inside.
    public func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var seen = Set<UUID>()
        var current = folder(id)
        while let folder = current, seen.insert(folder.id).inserted {
            names.insert(folder.name, at: 0)
            current = folder.parentID.flatMap { self.folder($0) }
        }
        return names.joined(separator: " / ")
    }

    /// Whether `id` is `ancestorID` or somewhere inside it.
    public func isFolder(_ id: UUID, inside ancestorID: UUID) -> Bool {
        var seen = Set<UUID>()
        var current = folder(id)
        while let folder = current, seen.insert(folder.id).inserted {
            if folder.id == ancestorID { return true }
            current = folder.parentID.flatMap { self.folder($0) }
        }
        return false
    }

    /// Puts a folder inside another one (nil = top level), as the last folder there. Refused when
    /// the target is the folder itself or inside it: that would cut the folder off from the tree.
    public mutating func moveFolder(_ id: UUID, into parentID: UUID?) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        if let parentID {
            guard folder(parentID) != nil, !isFolder(parentID, inside: id) else { return }
        }
        var moved = folders.remove(at: index)
        moved.parentID = parentID
        folders.append(moved)
    }

    // MARK: - Changing

    /// Adds a tab to the end of its section (array order is per-section, so appending is enough).
    public mutating func append(_ tab: BrowserTab) {
        tabs.append(tab)
    }

    /// Inserts a tab right after another tab (used for links opened from a page).
    public mutating func insert(_ tab: BrowserTab, after otherID: UUID?) {
        if let otherID, let index = tabs.firstIndex(where: { $0.id == otherID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    public mutating func updateTab(_ id: UUID, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    /// Removes a tab. If it was selected, selects its neighbour in sidebar order
    /// (the next one, or the previous one when it was last).
    public mutating func closeTab(_ id: UUID) {
        // A tab in a split hands its selection to a neighbouring pane, so the split stays on screen.
        let splitNeighbour = splitGroup(containing: id)?.root.tabIDs.first { $0 != id }
        removeFromSplit(id)
        let order = tabsInSidebarOrder.map(\.id)
        tabs.removeAll { $0.id == id }
        guard selectedTabID == id else { return }
        if let splitNeighbour {
            selectedTabID = splitNeighbour
            return
        }
        guard let position = order.firstIndex(of: id) else {
            selectedTabID = nil
            return
        }
        let remaining = order.filter { $0 != id }
        if remaining.isEmpty {
            selectedTabID = nil
        } else {
            selectedTabID = remaining[min(position, remaining.count - 1)]
        }
    }

    /// Reorders tabs within one section, using SwiftUI's `onMove` semantics:
    /// `offsets` and `destination` are indices into `tabs(in: section)`.
    /// Tabs in other sections keep their positions in the array.
    public mutating func moveTabs(in section: SidebarSection, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        // Indices in `tabs` that belong to this section, in order.
        let slots = tabs.indices.filter { tabs[$0].section == section }
        var sectionTabs = slots.map { tabs[$0] }

        let moving = offsets.sorted().map { sectionTabs[$0] }
        // Destination is expressed before removal; shift it left for every moved item above it.
        let adjusted = destination - offsets.filter { $0 < destination }.count
        for offset in offsets.sorted(by: >) {
            sectionTabs.remove(at: offset)
        }
        sectionTabs.insert(contentsOf: moving, at: adjusted)

        // Write the reordered tabs back into the same array slots.
        for (slot, tab) in zip(slots, sectionTabs) {
            tabs[slot] = tab
        }
    }

    /// Moves a tab to another section. It is appended at the end of that section.
    public mutating func moveTab(_ id: UUID, to section: SidebarSection) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs.remove(at: index)
        switch section {
        case .pinned:
            tab.isPinned = true
            tab.folderID = nil
        case .open:
            tab.isPinned = false
            tab.folderID = nil
        case .folder(let folderID):
            tab.folderID = folderID
        }
        tabs.append(tab)
    }

    /// Deletes a folder and keeps what was in it: its tabs and the folders inside it move one
    /// level up (tabs of a top-level folder go to the open section).
    public mutating func deleteFolder(_ id: UUID) {
        guard let deleted = folder(id) else { return }
        let parentID = deleted.parentID.flatMap { folder($0) }?.id
        folders.removeAll { $0.id == id }
        for index in folders.indices where folders[index].parentID == id {
            folders[index].parentID = parentID
        }
        for index in tabs.indices where tabs[index].folderID == id {
            tabs[index].folderID = parentID
            if parentID == nil { tabs[index].isPinned = false }
        }
    }
}

/// Preset colours offered when creating or editing a Space.
public enum SpaceColors {
    public static let presets: [String] = [
        "#5E81F4", // blue
        "#9B6BDF", // violet
        "#E8618C", // pink
        "#F07B4F", // orange
        "#E9B949", // yellow
        "#4FB286", // green
        "#3BA7B5", // teal
        "#8A8F98", // grey
    ]
}
