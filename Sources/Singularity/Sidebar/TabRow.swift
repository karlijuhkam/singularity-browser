import AppKit
import SingularityCore
import SwiftUI
import UniformTypeIdentifiers

/// One tab in the sidebar: favicon, title, and a close button on hover.
struct TabRow: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            TabIcon(tab: tab, space: space)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            AgentBadge(tab: tab)
            if isHovering {
                Button {
                    state.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close Tab (⌘W)")
            }
        }
        .agentBusyBackground(tab.id)
        .onHover { isHovering = $0 }
        .help(tab.url?.absoluteString ?? "")
        .contextMenu { TabContextMenu(tab: tab, space: space) }
        // Lets the row be dragged onto the page to build a split.
        .itemProvider { TabDrag.provider(for: tab.id) }
    }
}

/// A tab's icon: favicon for web pages, a symbol for terminals and artifacts.
struct TabIcon: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space

    var body: some View {
        if tab.isArtifact {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
        } else if tab.isTerminal {
            let session = state.terminals.existingSession(tab.id)
            Image(systemName: session?.foregroundProgram != nil ? "terminal.fill" : "terminal")
                .foregroundStyle(session?.isRunning == false ? .tertiary : .secondary)
        } else if let host = tab.url?.host(), let image = state.favicons.image(slug: space.slug, host: host) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
    }
}

/// Dragging a tab (from a sidebar row or a pane header) onto the page. The private type means
/// only Singularity's panes accept it (a web page won't treat the drop as text).
@MainActor
enum TabDrag {
    static func provider(for tabID: UUID) -> NSItemProvider {
        // SwiftUI asks for this when the drag starts: time to put the panes' drop layers up.
        TabDragSession.begin()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.singularityTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(tabID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// The right-click menu of a tab (sidebar rows and split chips).
struct TabContextMenu: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space

    var body: some View {
        if tab.folderID == nil {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { state.togglePin(tab.id) }
        }

        Menu("Move to Folder") {
            ForEach(space.folders) { folder in
                Button(folder.name) { state.moveTab(tab.id, to: .folder(folder.id)) }
                    .disabled(tab.folderID == folder.id)
            }
            if !space.folders.isEmpty { Divider() }
            Button("New Folder…") { state.promptNewFolder(moving: tab.id) }
        }

        if tab.folderID != nil {
            Button("Remove from Folder") { state.moveTab(tab.id, to: .open) }
        }

        Divider()

        if let current = space.selectedTabID, current != tab.id {
            Menu("Open in Split View") {
                Button("Right of Current Tab") { state.splitTab(tab.id, beside: current, edge: .right) }
                Button("Left of Current Tab") { state.splitTab(tab.id, beside: current, edge: .left) }
                Button("Below Current Tab") { state.splitTab(tab.id, beside: current, edge: .bottom) }
                Button("Above Current Tab") { state.splitTab(tab.id, beside: current, edge: .top) }
            }
        }
        if space.splitGroup(containing: tab.id) != nil {
            Button("Remove from Split") { state.removeFromSplit(tab.id) }
        }

        Divider()

        if tab.isTerminal, state.terminals.existingSession(tab.id)?.isRunning == false {
            Button("Start New Shell") { state.restartTerminal(tab.id, in: space.id) }
        }

        if let path = tab.artifactPath {
            Button("Show in Finder") {
                let file = state.paths.artifactsDirectory(space.slug).appending(path: path)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }

        if let url = tab.url {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }

        Button("Close Tab") { state.closeTab(tab.id) }
    }
}
