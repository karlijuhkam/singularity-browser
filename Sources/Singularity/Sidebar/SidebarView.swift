import SingularityCore
import SwiftUI

/// Left side of the window: navigation buttons, the address row, the vertical Space rail,
/// and the current Space's tab list.
struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            NavigationButtons()
                .frame(height: 40)
                .padding(.leading, 78) // room for the window's traffic-light buttons
                .padding(.trailing, 8)

            HStack(alignment: .top, spacing: 0) {
                SpaceRail()
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 6) {
                    // The site settings button is a sibling of the address button, not inside it:
                    // a click on it must not open the palette.
                    HStack(spacing: 2) {
                        AddressRow()
                        SiteSettingsButton()
                    }
                    if let space = state.selectedSpace {
                        TabList(space: space)
                    }
                    if !state.downloads.items.isEmpty {
                        DownloadsPane()
                    }
                }
                .padding(.trailing, 6)
                .padding(.bottom, 4)
            }

            // The bottom row runs under the rail too, from the sidebar's left edge to its right:
            // New Tab, then New Terminal and the launchers (Settings → Terminal → Launchers).
            BottomRow()
                .padding(.trailing, 6)
                .padding(.bottom, 8)
        }
    }
}

private struct BottomRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let launchers = state.launchers
        HStack(spacing: 0) {
            NewTabButton()
            NewTerminalButton()
            ForEach(launchers.prefix(LauncherRow.shown)) { launcher in
                LauncherButton(launcher: launcher)
            }
            if launchers.count > LauncherRow.shown {
                LauncherOverflowMenu(launchers: Array(launchers.dropFirst(LauncherRow.shown)))
            }
        }
    }
}

// MARK: - Toolbar row

private struct NavigationButtons: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let controller = state.selectedTab.flatMap { state.web.existingController($0.id) }
        HStack(spacing: 2) {
            Spacer()
            iconButton("chevron.left", help: "Back (⌘[)", enabled: controller?.canGoBack == true) { controller?.goBack() }
            iconButton("chevron.right", help: "Forward (⌘])", enabled: controller?.canGoForward == true) { controller?.goForward() }
            iconButton("arrow.clockwise", help: "Reload (⌘R)", enabled: controller != nil) { controller?.reload() }
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Address row

/// Shows the selected tab's host. Clicking it opens the palette to navigate the current tab.
private struct AddressRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.showPalette(state.selectedTab == nil ? .newTab : .navigateCurrent)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: addressSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(addressText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(state.selectedTab == nil ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search or enter address")
    }

    private var addressSymbol: String {
        guard let tab = state.selectedTab else { return "magnifyingglass" }
        if tab.isArtifact { return "doc.richtext" }
        if tab.isTerminal { return "terminal" }
        return tab.url?.scheme == "https" ? "lock.fill" : "magnifyingglass"
    }

    private var addressText: String {
        if let path = state.selectedTab?.artifactPath { return "artifacts/\(path)" }
        if let directory = state.selectedTab?.workingDirectory { return directory }
        guard let url = state.selectedTab?.url else { return "Search or enter address" }
        if let host = url.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }
}

// MARK: - Tab list

private struct TabList: View {
    @Environment(AppState.self) private var state
    let space: Space
    /// True while a tab is being dragged (from the sidebar or a pane header).
    @State private var isDraggingTab = false

    var body: some View {
        // Selecting a row in the List selects the tab.
        let selection = Binding<UUID?>(
            get: { space.selectedTabID },
            set: { id in if let id { state.selectTab(id) } }
        )

        List(selection: selection) {
            let pinned = space.sidebarItems(in: .pinned)
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { item in
                        SidebarItemRow(item: item, space: space)
                    }
                    .onMove { state.moveSidebarItems(in: .pinned, fromOffsets: $0, toOffset: $1) }
                    .onInsert(of: TabDrop.types) { row, providers in drop(providers, in: .pinned, atRow: row) }
                } header: {
                    SectionDropHeader(title: "Pinned", section: .pinned)
                }
            }

            if !space.folders.isEmpty {
                Section("Folders") {
                    // Top-level folders; each FolderGroup lists the folders inside it itself.
                    ForEach(space.childFolders(of: nil)) { folder in
                        FolderGroup(folder: folder, space: space)
                    }
                }
            }

            Section {
                ForEach(space.sidebarItems(in: .open)) { item in
                    SidebarItemRow(item: item, space: space)
                }
                .onMove { state.moveSidebarItems(in: .open, fromOffsets: $0, toOffset: $1) }
                .onInsert(of: TabDrop.types) { row, providers in drop(providers, in: .open, atRow: row) }
            } header: {
                SectionDropHeader(title: "Tabs", section: .open)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // With nothing pinned there is no Pinned section to drop on, so one appears for the drag.
        .overlay(alignment: .top) {
            if isDraggingTab, space.sidebarItems(in: .pinned).isEmpty {
                PinDropZone()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TabDragSession.didBegin)) { _ in isDraggingTab = true }
        .onReceive(NotificationCenter.default.publisher(for: TabDragSession.didEnd)) { _ in isDraggingTab = false }
    }

    /// A tab dropped between two rows of a section (`onMove` only covers drags within one section).
    private func drop(_ providers: [NSItemProvider], in section: SidebarSection, atRow row: Int) {
        TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: section, atRow: row) }
    }
}

/// A section title that also takes a dropped tab (it goes to the end of the section). Needed
/// when the section has no rows to drop between.
private struct SectionDropHeader: View {
    @Environment(AppState.self) private var state
    let title: String
    let section: SidebarSection
    @State private var isTargeted = false

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(dropHighlight(isTargeted))
            .onDrop(of: TabDrop.types, isTargeted: $isTargeted) { providers in
                TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: section) }
            }
    }
}

/// Shown at the top of the tab list while a tab is dragged and nothing is pinned yet.
private struct PinDropZone: View {
    @Environment(AppState.self) private var state
    @State private var isTargeted = false

    var body: some View {
        Label("Drop here to pin", systemImage: "pin")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .padding(.horizontal, 8)
            .onDrop(of: TabDrop.types, isTargeted: $isTargeted) { providers in
                TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: .pinned) }
            }
    }
}

/// The tint behind a header or folder while a dragged tab hovers over it.
private func dropHighlight(_ isTargeted: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(Color.accentColor.opacity(isTargeted ? 0.25 : 0))
}

/// A sidebar row: a single tab (selectable List row), or a split shown as one row of chips.
private struct SidebarItemRow: View {
    let item: SidebarItem
    let space: Space

    var body: some View {
        switch item {
        case .tab(let id):
            if let tab = space.tab(id) {
                TabRow(tab: tab, space: space).tag(id)
            }
        case .split(_, let tabIDs):
            // Not tagged: the chips handle selection themselves, so a click on one chip isn't
            // overridden by the List selecting "the row".
            SplitRow(tabIDs: tabIDs, space: space)
        }
    }
}

/// A split in the sidebar: its tabs side by side, like the panes on screen. Clicking a chip
/// shows the split with that pane focused.
private struct SplitRow: View {
    @Environment(AppState.self) private var state
    let tabIDs: [UUID]
    let space: Space

    var body: some View {
        let compact = tabIDs.count >= 4
        let splitIsShown = space.selectedTabID.map(tabIDs.contains) ?? false
        HStack(spacing: 3) {
            ForEach(tabIDs, id: \.self) { id in
                if let tab = space.tab(id) {
                    let focused = splitIsShown && space.selectedTabID == id
                    HStack(spacing: 5) {
                        TabIcon(tab: tab, space: space)
                            .frame(width: 14, height: 14)
                        if !compact {
                            Text(tab.displayTitle)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            AgentBadge(tab: tab)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: compact ? .center : .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(focused ? 0.14 : (splitIsShown ? 0.07 : 0.04)))
                    )
                    .agentBusyBackground(id, cornerRadius: 5)
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectTab(id) }
                    .contextMenu { TabContextMenu(tab: tab, space: space) }
                    // No drag source here: dragging the row reorders the whole split in the
                    // sidebar. Panes are rearranged by dragging their header on the page.
                    // No room for a project tag on a chip, so the tooltip names it.
                    .help(tab.displayTitle + (space.projectName(of: tab).map { " (\($0))" } ?? ""))
                }
            }
        }
        .padding(.vertical, 1)
    }
}

private struct FolderGroup: View {
    @Environment(AppState.self) private var state
    let folder: Folder
    let space: Space
    @State private var isDropTargeted = false

    var body: some View {
        let expanded = Binding(
            get: { folder.isExpanded },
            set: { state.setFolderExpanded(folder.id, $0) }
        )
        DisclosureGroup(isExpanded: expanded) {
            // Folders inside this one first (the List indents them), then this folder's tabs.
            ForEach(space.childFolders(of: folder.id)) { child in
                FolderGroup(folder: child, space: space)
            }
            ForEach(space.sidebarItems(in: .folder(folder.id))) { item in
                SidebarItemRow(item: item, space: space)
            }
            .onMove { state.moveSidebarItems(in: .folder(folder.id), fromOffsets: $0, toOffset: $1) }
            .onInsert(of: TabDrop.types) { row, providers in
                TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: .folder(folder.id), atRow: row) }
            }
        } label: {
            HStack(spacing: 6) {
                Label(folder.name, systemImage: folder.isExpanded ? "folder" : "folder.fill")
                    .lineLimit(1)
                Spacer(minLength: 0)
                // The folder's own project: terminals opened in here start in it.
                if let project = space.ownProject(ofFolder: folder.id) {
                    Text(ProjectTag.short(project.displayName))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Keeps its width; the folder's name truncates instead.
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
                // A tab dropped on the folder itself goes to the end of it (also when collapsed or empty).
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(dropHighlight(isDropTargeted))
                .onDrop(of: TabDrop.types, isTargeted: $isDropTargeted) { providers in
                    TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: .folder(folder.id)) }
                }
                .contextMenu {
                    Button("New Terminal") { state.openTerminal(inFolder: folder.id) }
                    if !space.projects.isEmpty {
                        Menu("Project") {
                            // A Toggle in a menu is drawn as an item with a checkmark.
                            Toggle("None", isOn: projectChoice(nil))
                            Divider()
                            ForEach(space.projects) { project in
                                Toggle(project.displayName, isOn: projectChoice(project.id))
                            }
                        }
                    }
                    Divider()
                    Button("Rename…") {
                        state.nameRequest = NameRequest(title: "Rename Folder", initialValue: folder.name) { name in
                            state.renameFolder(folder.id, to: name)
                        }
                    }
                    Button("New Folder Inside…") { state.promptNewFolder(inside: folder.id) }
                    Menu("Move Folder to") {
                        Button("Top Level") { state.moveFolder(folder.id, into: nil) }
                            .disabled(folder.parentID == nil)
                        // Not into itself or a folder inside it.
                        let targets = space.foldersInTreeOrder.filter { !space.isFolder($0.folder.id, inside: folder.id) }
                        if !targets.isEmpty { Divider() }
                        ForEach(targets, id: \.folder.id) { target in
                            Button(space.folderPath(target.folder.id)) { state.moveFolder(folder.id, into: target.folder.id) }
                                .disabled(folder.parentID == target.folder.id)
                        }
                    }
                    Button("Delete Folder (keep contents)") { state.deleteFolder(folder.id) }
                }
        }
    }
}

extension FolderGroup {
    /// On when `projectID` is this folder's own project (nil = "None"); switching it on chooses it.
    fileprivate func projectChoice(_ projectID: UUID?) -> Binding<Bool> {
        Binding(
            get: { space.ownProject(ofFolder: folder.id)?.id == projectID },
            set: { isOn in if isOn { state.setFolderProject(folder.id, projectID) } }
        )
    }
}

private struct NewTerminalButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.openTerminal()
        } label: {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Terminal (⌥⌘T)")
    }
}

private struct NewTabButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.showPalette(.newTab)
        } label: {
            HStack(spacing: 0) {
                // Centred under the rail's circles (the rail is 48 pt wide).
                Image(systemName: "plus")
                    .frame(width: 48)
                Text("New Tab")
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
    }
}
