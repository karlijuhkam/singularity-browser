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
                Image(systemName: state.selectedTab?.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
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

    private var addressText: String {
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
            let pinned = space.tabs(in: .pinned)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { tab in
                        TabRow(tab: tab, space: space).tag(tab.id)
                    }
                    .onMove { state.moveTabs(in: .pinned, fromOffsets: $0, toOffset: $1) }
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
                ForEach(space.tabs(in: .open)) { tab in
                    TabRow(tab: tab, space: space).tag(tab.id)
                }
                .onMove { state.moveTabs(in: .open, fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
            ForEach(space.tabs(in: .folder(folder.id))) { tab in
                TabRow(tab: tab, space: space).tag(tab.id)
            }
            .onMove { state.moveTabs(in: .folder(folder.id), fromOffsets: $0, toOffset: $1) }
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
