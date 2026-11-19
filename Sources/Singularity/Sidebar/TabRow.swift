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

    private var isMissing: Bool { state.missingArtifactTabs.contains(tab.id) }

    var body: some View {
        HStack(spacing: 8) {
            TabIcon(tab: tab, space: space)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                // An artifact whose file was deleted: struck through and dimmed.
                .strikethrough(isMissing)
                .foregroundStyle(isMissing ? .secondary : .primary)
            Spacer(minLength: 0)
            // A terminal's project, only when the folder header doesn't already say it.
            if let project = space.projectTag(of: tab) {
                ProjectTag(name: project)
            }
            // The inbox has something for this tab: seen without opening the inbox.
            if let attention = state.inbox.inbox.tabAttention[tab.id] {
                TabAttentionMark(attention: attention)
            }
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
        .help(helpText)
        .contextMenu { TabContextMenu(tab: tab, space: space) }
        .background(ListDragOperations())
        // Lets the row be dragged onto the page to build a split, and to another place in the sidebar.
        .itemProvider { TabDrag.provider(for: tab.id) }
    }
}

extension TabRow {
    /// The row's tooltip: the address of a page, the project of a terminal.
    fileprivate var helpText: String {
        if isMissing { return "The file of this artifact is missing" }
        if let project = space.projectName(of: tab) { return "Project: \(project)" }
        if let path = tab.notePath { return NoteFiles.subtitle(tabPath: path) }
        return tab.url?.absoluteString ?? ""
    }
}

/// A tab's icon: favicon for web pages, a symbol for terminals, artifacts and plugin pages.
struct TabIcon: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space

    var body: some View {
        if tab.isPlugin {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
        } else if tab.isNote {
            Image(systemName: "note.text")
                .foregroundStyle(.secondary)
        } else if tab.isHome {
            Image(systemName: "house")
                .foregroundStyle(.secondary)
        } else if tab.isArtifact {
            let isMissing = state.missingArtifactTabs.contains(tab.id)
            Image(systemName: isMissing ? "questionmark.square.dashed" : "doc.richtext")
                .foregroundStyle(isMissing ? .tertiary : .secondary)
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
        return payload(.tab(tabID))
    }

    /// A split's row dragged within the sidebar: it carries the split (`split:<id>`), and a drop
    /// in the sidebar moves the whole split there (`Space.moveSplit`). The session begins so the
    /// sidebar shows its drop rows (an empty Pinned or Tabs), but the panes' drop layers stay
    /// down: the row can't be dropped on the page (that would pull one tab out).
    static func splitRowProvider(groupID: UUID) -> NSItemProvider {
        TabDragSession.begin(raisesPanes: false)
        return payload(.split(groupID: groupID))
    }

    private static func payload(_ payload: TabDragPayload) -> NSItemProvider {
        let text = payload.string
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.singularityTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        return provider
    }
}

/// Makes drops in the sidebar possible at all. AppKit drops only when the drag's source and the
/// place under the pointer agree on an operation. The List's outline view, as the source of a row
/// drag, offers only *move* inside the app, while SwiftUI's drop targets in it (`onInsert`,
/// `onDrop`) propose *copy*: so every drop in the sidebar was refused. Placed in a row, this view
/// finds the outline view it sits in and lets it offer copy as well. (SwiftUI doesn't replace
/// NSTableView's `draggingSession(_:sourceOperationMaskFor:)`, which answers with this mask; a
/// drag out of the app is not changed.)
struct ListDragOperations: NSViewRepresentable {
    func makeNSView(context: Context) -> ListDragOperationsView { ListDragOperationsView() }
    func updateNSView(_ view: ListDragOperationsView, context: Context) { view.widen() }
}

final class ListDragOperationsView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        widen()
    }

    func widen() {
        var view = superview
        while let current = view {
            if let table = current as? NSTableView {
                table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
                return
            }
            view = current.superview
        }
    }

    // Takes no clicks: the row under it does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Reading the dragged tab back out of a drop in the sidebar.
@MainActor
enum TabDrop {
    static let types = [UTType.singularityTab]

    /// Hands what was dragged (a tab, or a split's row) to `action` on the main thread. (Item
    /// providers deliver their data asynchronously, on a background queue.)
    @discardableResult
    static func handle(_ providers: [NSItemProvider], action: @escaping @MainActor (TabDragPayload) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.singularityTab.identifier) })
        else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.singularityTab.identifier) { data, _ in
            guard let data, let payload = TabDragPayload(string: String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in action(payload) }
        }
        return true
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
            ForEach(space.foldersInTreeOrder, id: \.folder.id) { entry in
                Button(space.folderPath(entry.folder.id)) { state.moveTab(tab.id, to: .folder(entry.folder.id)) }
                    .disabled(tab.folderID == entry.folder.id)
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

        if let pluginID = tab.pluginID {
            // The page goes back to the panel; the tab goes.
            Button("Move to Side Panel") { state.movePluginPageToPanel(pluginID) }
        }

        if tab.isTerminal, state.terminals.existingSession(tab.id)?.isRunning == false {
            Button("Start New Shell") { state.restartTerminal(tab.id, in: space.id) }
        }

        if let path = tab.artifactPath {
            Button("Show in Finder") {
                let file = state.paths.artifactsDirectory(space.slug).appending(path: path)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            .disabled(state.missingArtifactTabs.contains(tab.id))
        }

        if tab.isNote {
            Button("Show in Finder") { state.revealNote(tabID: tab.id, spaceID: space.id) }
            Button("Delete Note…") { state.deleteNote(tabID: tab.id, spaceID: space.id) }
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
