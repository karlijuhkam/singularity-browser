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
                    AddressRow()
                    if let space = state.selectedSpace {
                        TabList(space: space)
                    }
                    HStack(spacing: 0) {
                        NewTabButton()
                        NewTerminalButton()
                    }
                }
                .padding(.trailing, 6)
                .padding(.bottom, 8)
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

    var body: some View {
        // Selecting a row in the List selects the tab.
        let selection = Binding<UUID?>(
            get: { space.selectedTabID },
            set: { id in if let id { state.selectTab(id) } }
        )

        List(selection: selection) {
            let pinned = space.sidebarItems(in: .pinned)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { item in
                        SidebarItemRow(item: item, space: space)
                    }
                    .onMove { state.moveSidebarItems(in: .pinned, fromOffsets: $0, toOffset: $1) }
                }
            }

            if !space.folders.isEmpty {
                Section("Folders") {
                    ForEach(space.folders) { folder in
                        FolderGroup(folder: folder, space: space)
                    }
                }
            }

            Section("Tabs") {
                ForEach(space.sidebarItems(in: .open)) { item in
                    SidebarItemRow(item: item, space: space)
                }
                .onMove { state.moveSidebarItems(in: .open, fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
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
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: compact ? .center : .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(focused ? 0.14 : (splitIsShown ? 0.07 : 0.04)))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectTab(id) }
                    .contextMenu { TabContextMenu(tab: tab, space: space) }
                    // No drag source here: dragging the row reorders the whole split in the
                    // sidebar. Panes are rearranged by dragging their header on the page.
                    .help(tab.displayTitle)
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

    var body: some View {
        let expanded = Binding(
            get: { folder.isExpanded },
            set: { state.setFolderExpanded(folder.id, $0) }
        )
        DisclosureGroup(isExpanded: expanded) {
            ForEach(space.sidebarItems(in: .folder(folder.id))) { item in
                SidebarItemRow(item: item, space: space)
            }
            .onMove { state.moveSidebarItems(in: .folder(folder.id), fromOffsets: $0, toOffset: $1) }
        } label: {
            Label(folder.name, systemImage: folder.isExpanded ? "folder" : "folder.fill")
                .contextMenu {
                    Button("Rename…") {
                        state.nameRequest = NameRequest(title: "Rename Folder", initialValue: folder.name) { name in
                            state.renameFolder(folder.id, to: name)
                        }
                    }
                    Button("Delete Folder (keep tabs)") { state.deleteFolder(folder.id) }
                }
        }
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
            Label("New Tab", systemImage: "plus")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
    }
}
