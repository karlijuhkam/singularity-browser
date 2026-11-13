import Foundation

/// A project of a Space: a name and a folder on disk (usually a repository). It decides where a
/// terminal starts; nothing else hangs off it. A sidebar folder and a terminal tab can point at
/// one through their `projectID`.
///
/// Everywhere in this file, an id that matches no project of the Space counts as "no project":
/// a removed project must never leave a stale name or a crash behind.
public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The folder, stored with `~` unexpanded like `Space.workingDirectory`.
    public var path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// The name to show: the trimmed name, or the folder's own name when that is empty.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultName(forPath: path) : trimmed
    }

    /// A project for a folder chosen in a file panel (an absolute path): named after the folder,
    /// with a path under the home folder stored as "~/…" so space.json stays portable.
    public static func forFolder(_ absolutePath: String, home: String = NSHomeDirectory()) -> Project {
        var path = absolutePath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let stored = HomePath.abbreviate(path, home: home)
        return Project(name: defaultName(forPath: stored), path: stored)
    }

    /// "~/Developer/acme-web" → "acme-web"; "~" → "Home".
    public static func defaultName(forPath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        if last == "~" { return "Home" }
        return last.isEmpty ? path : last
    }
}

/// What "New Terminal" should do.
public enum TerminalStart: Equatable, Sendable {
    /// Start a shell here, right away. `projectID` is nil for the Space's own folder.
    case start(directory: String, projectID: UUID?)
    /// Show the picker.
    case ask
}

/// One row of the "New terminal in" picker.
public struct ProjectChoice: Equatable, Identifiable, Sendable {
    /// nil = the Space's own folder.
    public var projectID: UUID?
    public var name: String
    public var path: String

    public var id: String { projectID?.uuidString ?? "space-folder" }
}

extension Space {
    // MARK: - Reading

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// The project chosen on this folder itself (what its header shows).
    public func ownProject(ofFolder id: UUID?) -> Project? {
        guard let id else { return nil }
        return project(folder(id)?.projectID)
    }

    /// The folder's own project, else that of the nearest folder it is inside.
    public func effectiveProject(ofFolder id: UUID?) -> Project? {
        var seen = Set<UUID>() // a damaged file could hold folders that are each other's parent
        var current = id.flatMap { folder($0) }
        while let folder = current, seen.insert(folder.id).inserted {
            if let project = project(folder.projectID) { return project }
            current = folder.parentID.flatMap { self.folder($0) }
        }
        return nil
    }

    /// The folder a new terminal lands in: the one the selected tab is shown in (nil = none).
    public var folderForNewTerminal: UUID? {
        selectedTab.flatMap { folderShowing($0) }
    }

    /// The folder a tab is shown in: its own, or, for a pane of a split, the folder the split's
    /// row is in. (A split is one sidebar row in the section of its first tab; a terminal opened
    /// in that split is itself placed in Tabs, but to the user it is in that folder.)
    public func folderShowing(_ tab: BrowserTab) -> UUID? {
        if let own = tab.folderID.flatMap({ folder($0) }) { return own.id }
        guard let group = splitGroup(containing: tab.id) else { return nil }
        let members = Set(group.root.tabIDs)
        let home = tabsInSidebarOrder.first { members.contains($0.id) }
        return home?.folderID.flatMap { folder($0) }?.id
    }

    /// Where a new terminal starts, or that the picker must ask.
    /// - A Space without projects never asks: the Space's folder.
    /// - `alwaysAsk` is "New Terminal in…".
    /// - Inside a folder with a project (own or inherited): that project.
    /// - Otherwise: ask.
    public func terminalStart(inFolder folderID: UUID?, alwaysAsk: Bool) -> TerminalStart {
        if projects.isEmpty { return .start(directory: workingDirectory, projectID: nil) }
        if alwaysAsk { return .ask }
        if let project = effectiveProject(ofFolder: folderID) {
            return .start(directory: project.path, projectID: project.id)
        }
        return .ask
    }

    /// A terminal opened in a split never asks. It starts in the project of the tab it is put
    /// beside when that is a terminal; a terminal without a project means the Space's folder.
    /// Beside any other tab: that tab's folder's project, else the Space's folder.
    public func splitTerminalStart(beside tabID: UUID) -> (directory: String, projectID: UUID?) {
        let spaceFolder: (String, UUID?) = (workingDirectory, nil)
        guard let tab = tab(tabID) else { return spaceFolder }
        let chosen = tab.isTerminal ? project(tab.projectID) : effectiveProject(ofFolder: folderShowing(tab))
        return chosen.map { ($0.path, $0.id) } ?? spaceFolder
    }

    /// The picker's rows: the last used project, the others in the Space's order, the Space's folder.
    public var projectChoices: [ProjectChoice] {
        var ordered = projects
        if let index = ordered.firstIndex(where: { $0.id == lastProjectID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered.map { ProjectChoice(projectID: $0.id, name: $0.displayName, path: $0.path) }
            + [ProjectChoice(projectID: nil, name: "Space folder", path: workingDirectory)]
    }

    /// The project's name for a terminal that has one (tooltips, the agents' `list_tabs`).
    public func projectName(of tab: BrowserTab) -> String? {
        guard tab.isTerminal else { return nil }
        return project(tab.projectID)?.displayName
    }

    /// The tag on a terminal's sidebar row. Only shown when it says something new: the terminal
    /// is in no folder, or its folder's project (own or inherited) is a different one.
    public func projectTag(of tab: BrowserTab) -> String? {
        guard tab.isTerminal, let project = project(tab.projectID) else { return nil }
        if effectiveProject(ofFolder: tab.folderID)?.id == project.id { return nil }
        return project.displayName
    }

    // MARK: - Changing

    /// Adds a terminal tab at the end of `folderID` (or of Tabs, when that folder doesn't exist).
    /// With `select`, that folder and the folders around it are opened, so the selected tab's
    /// row is on screen (folders imported from Arc start closed).
    @discardableResult
    public mutating func addTerminal(directory: String, projectID: UUID?, inFolder folderID: UUID?, select: Bool) -> UUID {
        var tab = BrowserTab.terminal(workingDirectory: directory)
        tab.projectID = project(projectID)?.id
        tab.folderID = folderID.flatMap { folder($0) }?.id
        append(tab)
        if select {
            selectedTabID = tab.id
            var seen = Set<UUID>()
            var current = tab.folderID
            while let id = current, seen.insert(id).inserted, let index = folders.firstIndex(where: { $0.id == id }) {
                folders[index].isExpanded = true
                current = folders[index].parentID
            }
        }
        return tab.id
    }

    /// A choice made in the picker. A project becomes the "last used" one. When `folderID` names
    /// a folder that has no project (own or inherited), the project also becomes that folder's.
    /// The Space's folder (nil) is not remembered and is never adopted.
    public mutating func recordPickerChoice(_ projectID: UUID?, adoptForFolder folderID: UUID?) {
        guard let project = project(projectID) else { return }
        lastProjectID = project.id
        if let folderID, folder(folderID) != nil, effectiveProject(ofFolder: folderID) == nil {
            setFolderProject(folderID, project.id)
        }
    }

    public mutating func setFolderProject(_ folderID: UUID, _ projectID: UUID?) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].projectID = project(projectID)?.id
    }

    /// Replaces the project list (Edit Space). Folders, terminals and "last used" that pointed at
    /// a removed project are cleared; running shells are not touched.
    public mutating func setProjects(_ newProjects: [Project]) {
        projects = newProjects
        let known = Set(newProjects.map(\.id))
        func kept(_ id: UUID?) -> UUID? { id.flatMap { known.contains($0) ? $0 : nil } }
        for index in folders.indices { folders[index].projectID = kept(folders[index].projectID) }
        for index in tabs.indices { tabs[index].projectID = kept(tabs[index].projectID) }
        lastProjectID = kept(lastProjectID)
    }
}
