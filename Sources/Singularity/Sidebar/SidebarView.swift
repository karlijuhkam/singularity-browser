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
                        // Browser extensions' buttons (and "Add to Singularity" on a store page).
                        ExtensionToolbar()
                        SiteSettingsButton()
                        // For a tab that shows an app (an artifact folder with a Worker); the two
                        // buttons are never there together: one is for web pages, one for artifacts.
                        AppPanelButton()
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
            if state.pluginPanelButtonVisible {
                Spacer(minLength: 0)
                PluginPanelButton()
            }
        }
    }
}

/// Show / hide the plugin panel (the Assistant): the View menu item, ⌃⌘J. Not in the title-bar
/// strip, so `.help()` is fine here.
private struct PluginPanelButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.togglePluginPanel()
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 12))
                .foregroundStyle(state.pluginPanelButtonLit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.pluginPanelButtonHelp)
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

/// Shows the selected tab's host. Clicking it opens the palette to navigate the current tab,
/// starting with the page's full address. A web tab also gets a copy button at the right end.
private struct AddressRow: View {
    @Environment(AppState.self) private var state
    /// True for two seconds after a copy: the button shows a tick.
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
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
                .padding(.leading, 10)
                .padding(.trailing, state.selectedAddress == nil ? 10 : 4)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search or enter address")

            // Two buttons side by side, not one inside the other: a button inside a button's
            // label never gets the click.
            if state.selectedAddress != nil {
                Button {
                    copied = state.copySelectedAddress()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy Link (⇧⌘C)")
                .accessibilityLabel("Copy Link")
            }
        }
        .font(.system(size: 12))
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // The tick turns back into the copy symbol after two seconds, or at once on another tab.
        // (`.task(id:)` starts again, and cancels the previous wait, each time `copied` changes.)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
        .onChange(of: state.selectedTab?.id) { copied = false }
    }

    private var addressSymbol: String {
        guard let tab = state.selectedTab else { return "magnifyingglass" }
        if tab.isArtifact { return "doc.richtext" }
        if tab.isTerminal { return "terminal" }
        if tab.isPlugin { return "puzzlepiece.extension" }
        if tab.isNote { return "note.text" }
        if tab.isHome { return "house" }
        return tab.url?.scheme == "https" ? "lock.fill" : "magnifyingglass"
    }

    private var addressText: String {
        if let path = state.selectedTab?.artifactPath { return "artifacts/\(path)" }
        if let directory = state.selectedTab?.workingDirectory { return directory }
        if let path = state.selectedTab?.notePath { return NoteFiles.subtitle(tabPath: path) }
        // A plugin's page has no address: the row names it (a click still opens the palette).
        if let tab = state.selectedTab, let pluginID = tab.pluginID { return state.pluginTitle(pluginID, fallback: tab.title) }
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
        // Selecting a row in the List selects the tab. Only a tab's id selects: the List also
        // tags a folder's row with the folder's id by itself (a ForEach over `Folder`s, whose ids
        // are UUIDs too), and "selecting" that showed an empty page. (Folder rows are not
        // selectable now, see FolderGroup; this keeps any other id out.)
        let selection = Binding<UUID?>(
            get: { space.selectedTabID },
            set: { id in if let id, state.selectedSpace?.tab(id) != nil { state.selectTab(id) } }
        )

        List(selection: selection) {
            let pinned = space.sidebarItems(in: .pinned)
            // With nothing pinned, the section is there only while a tab is dragged, to drop it on.
            // (It must be a row of the List: AppKit hands a drop to the List under the pointer, so
            // an overlay on top of it never gets one.)
            if !pinned.isEmpty || isDraggingTab {
                Section {
                    ForEach(pinned) { item in
                        SidebarItemRow(item: item, space: space)
                    }
                    .onInsert(of: TabDrop.types) { row, providers in drop(providers, in: .pinned, atRow: row) }
                    if pinned.isEmpty {
                        EmptySectionDropRow(section: .pinned)
                    }
                } header: {
                    Text("Pinned")
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
                let open = space.sidebarItems(in: .open)
                ForEach(open) { item in
                    SidebarItemRow(item: item, space: space)
                }
                .onInsert(of: TabDrop.types) { row, providers in drop(providers, in: .open, atRow: row) }
                if open.isEmpty, isDraggingTab {
                    EmptySectionDropRow(section: .open)
                }
            } header: {
                Text("Tabs")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // A right-click on the list's empty space (or a section title). Tab and folder rows have
        // their own `.contextMenu`, which wins over this one. Not `contextMenu(forSelectionType:)`:
        // on empty space it asked AppKit for the row view of row -1, which threw and crashed the
        // test `aRightClickOnEmptySpaceOffersNewTabTerminalAndNote`.
        .contextMenu {
            Button("New Tab") { state.openHome() }
            Button("New Terminal") { state.openTerminal() }
            Button("New Note") { state.newNote() }
        }
        // No `onMove` on any of these ForEach: a drag SwiftUI takes for its own reorder can't
        // leave its section (it refuses every other place). Each move, also within a section,
        // is a drop handled by `onInsert`, and `ListDragOperations` (in every row) lets those drops
        // happen at all.
        .onReceive(NotificationCenter.default.publisher(for: TabDragSession.didBegin)) { _ in isDraggingTab = true }
        .onReceive(NotificationCenter.default.publisher(for: TabDragSession.didEnd)) { _ in isDraggingTab = false }
    }

    /// A tab dropped between two rows of a section, from this section or another.
    private func drop(_ providers: [NSItemProvider], in section: SidebarSection, atRow row: Int) {
        TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: section, atRow: row) }
    }
}

/// The only row of an empty Pinned or Tabs section while a tab is dragged: the place to drop it.
/// (A section's title takes no drop, and neither does an empty section: the List refuses both.)
private struct EmptySectionDropRow: View {
    @Environment(AppState.self) private var state
    let section: SidebarSection
    @State private var isTargeted = false

    var body: some View {
        Label(section == .pinned ? "Drop here to pin" : "Drop here",
              systemImage: section == .pinned ? "pin" : "arrow.down.to.line")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .background(ListDragOperations())
            .selectionDisabled()
            .onDrop(of: TabDrop.types, isTargeted: $isTargeted) { providers in
                TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: section, atRow: .max) }
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
    @Environment(AppState.self) private var state
    let item: SidebarItem
    let space: Space

    var body: some View {
        switch item {
        case .tab(let id):
            if let tab = space.tab(id) {
                // A terminal with herdr terminals under it (a Bot's workers) lists them in its row.
                let children = tab.isTerminal ? state.herdr.children(of: id) : .none
                if children.rows.isEmpty {
                    TabRow(tab: tab, space: space).tag(id)
                } else {
                    TabWithChildrenRow(tab: tab, space: space, children: children)
                }
            }
        case .split(_, let tabIDs):
            // Not tagged: the chips handle selection themselves, so a click on one chip isn't
            // overridden by the List selecting "the row".
            VStack(alignment: .leading, spacing: 1) {
                SplitRow(tabIDs: tabIDs, space: space)
                // The child terminals of the split's terminal tabs hang under its row.
                ForEach(tabIDs, id: \.self) { id in
                    if let tab = space.tab(id), tab.isTerminal {
                        HerdrChildList(tab: tab, children: state.herdr.children(of: id),
                                       isTabSelected: space.selectedTabID == id)
                    }
                }
            }
            .background(ListDragOperations())
            // Dragging the row moves the whole split within the sidebar.
            .itemProvider { tabIDs.first.map(TabDrag.splitRowProvider(for:)) }
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
        let marks = state.inbox.inbox.tabAttention
        let splitIsShown = space.selectedTabID.map(tabIDs.contains) ?? false
        HStack(spacing: 3) {
            ForEach(tabIDs, id: \.self) { id in
                if let tab = space.tab(id) {
                    let focused = splitIsShown && space.selectedTabID == id
                    let attention = marks[id]
                    HStack(spacing: 5) {
                        TabIcon(tab: tab, space: space)
                            .frame(width: 14, height: 14)
                            // No room for the mark beside a compact chip's icon: on its corner.
                            .overlay(alignment: .topTrailing) {
                                if compact, let attention {
                                    TabAttentionMark(attention: attention)
                                        .scaleEffect(0.8)
                                        .offset(x: 6, y: -5)
                                }
                            }
                        if !compact {
                            Text(tab.displayTitle)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            if let attention { TabAttentionMark(attention: attention) }
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
                    // No drag source on a chip: dragging the row moves the whole split in the
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
            .onInsert(of: TabDrop.types) { row, providers in
                TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: .folder(folder.id), atRow: row) }
            }
        } label: {
            HStack(spacing: 6) {
                Label(folder.name, systemImage: folder.isExpanded ? "folder" : "folder.fill")
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Folded away, the header says when a tab inside it has something in the inbox.
                if !folder.isExpanded,
                   let attention = space.attention(ofFolder: folder.id, marks: state.inbox.inbox.tabAttention) {
                    TabAttentionMark(attention: attention)
                }
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
                .background(ListDragOperations())
                // A folder is not a tab: its row can't be selected (a selected folder row would
                // stay highlighted next to the tab's), and a click folds or unfolds it.
                .selectionDisabled()
                .onTapGesture { state.toggleFolder(folder.id) }
                .onDrop(of: TabDrop.types, isTargeted: $isDropTargeted) { providers in
                    TabDrop.handle(providers) { tabID in state.moveTab(tabID, to: .folder(folder.id), atRow: .max) }
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
            state.openHome()
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
