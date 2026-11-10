import SingularityCore
import SwiftUI

/// The sidebar's Downloads list: shown only while there is something in it.
struct DownloadsPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let downloads = state.downloads
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if downloads.items.contains(where: { $0.phase != .running }) {
                    Button("Clear") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item)
                    }
                }
            }
            // As tall as its rows, up to about four of them; more scroll.
            .frame(maxHeight: 170)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

private struct DownloadRow: View {
    @Environment(AppState.self) private var state
    let item: DownloadItem
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            icon
                .font(.system(size: 12))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.phase == .running {
                    // With an unknown size ProgressView(value: nil) shows the moving "busy" bar.
                    ProgressView(value: DownloadText.fraction(received: item.received, total: item.total))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
                Text(DownloadText.status(phase: item.phase, received: item.received, total: item.total))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if item.phase == .running {
                rowButton("xmark.circle.fill", help: "Cancel") { state.downloads.cancel(item.id) }
            } else if isHovering {
                if item.phase == .finished {
                    rowButton("magnifyingglass.circle.fill", help: "Show in Finder") { state.downloads.showInFinder(item) }
                }
                rowButton("xmark", help: "Remove from List") { state.downloads.remove(item.id) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Double-click opens the file, as in Finder.
        .onTapGesture(count: 2) { state.downloads.open(item) }
        .contextMenu {
            if item.phase == .finished {
                Button("Open") { state.downloads.open(item) }
                Button("Show in Finder") { state.downloads.showInFinder(item) }
            }
            if item.phase == .running {
                Button("Cancel") { state.downloads.cancel(item.id) }
            } else {
                Button("Remove from List") { state.downloads.remove(item.id) }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.phase {
        case .running: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .finished: Image(systemName: "doc.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.tertiary)
        }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
