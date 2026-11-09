import AppKit
import SingularityCore
import SwiftUI

/// One tab in the sidebar: favicon, title, and a close button on hover.
struct TabRow: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            favicon
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
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
        .onHover { isHovering = $0 }
        .help(tab.url?.absoluteString ?? "")
        .contextMenu { menu }
    }

    @ViewBuilder
    private var favicon: some View {
        if let host = tab.url?.host(), let image = state.favicons.image(slug: space.slug, host: host) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var menu: some View {
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

        if let url = tab.url {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }

        Button("Close Tab") { state.closeTab(tab.id) }
    }
}
