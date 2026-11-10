import AppKit
import SingularityCore
import SwiftUI

/// File → Import from Arc…: pick which Arc Spaces to bring over. Each becomes a new Space.
struct ArcImportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var spaces: [ArcImport.ArcSpace] = []
    @State private var chosen: Set<String> = []
    @State private var includeUnpinned = true
    /// Why there is nothing to show (file missing, not Arc's format).
    @State private var problem: String?
    @State private var file = ArcImport.defaultFile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Arc").font(.headline)

            if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Arc’s StorableSidebar.json…", action: chooseFile)
            } else {
                Text("Each Arc Space you tick becomes a new Space here, with its pinned tabs and folders. Your Spaces in Arc are not changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(spaces) { space in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(space.id) },
                                set: { on in if on { chosen.insert(space.id) } else { chosen.remove(space.id) } }
                            )) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hex: space.colorHex ?? "#8A8F98"))
                                        .frame(width: 10, height: 10)
                                    Text(space.name)
                                    Spacer()
                                    Text(summary(space))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 220)

                Toggle("Also bring the unpinned tabs (Arc’s “Today”) as open tabs", isOn: $includeUnpinned)

                Text("Logins are not imported: Arc keeps them in its own format, so you sign in again here. Notes, easels and Arc’s own pages are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Import 1 Space" : "Import \(chosen.count) Spaces") {
                    state.importArcSpaces(spaces.filter { chosen.contains($0.id) },
                                          options: ArcImport.Options(includeUnpinned: includeUnpinned))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func summary(_ space: ArcImport.ArcSpace) -> String {
        var parts = ["\(space.pinnedTabCount) pinned"]
        if includeUnpinned, space.unpinnedTabCount > 0 { parts.append("\(space.unpinnedTabCount) open") }
        if space.skipped > 0 { parts.append("\(space.skipped) left out") }
        if space.profile != "Default" { parts.append(space.profile) }
        return parts.joined(separator: " · ")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else {
            problem = "Arc’s sidebar file wasn’t found at ~/Library/Application Support/Arc/StorableSidebar.json. Is Arc installed on this Mac?"
            return
        }
        switch ArcImport.read(file) {
        case .success(let found):
            // Spaces with nothing to import are not offered.
            spaces = found.filter { $0.pinnedTabCount + $0.unpinnedTabCount > 0 }
            chosen = Set(spaces.map(\.id))
            problem = spaces.isEmpty ? "Arc’s sidebar has no tabs to import." : nil
        case .failure(let failure):
            problem = failure.message
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = ArcImport.defaultFile.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        file = url
        problem = nil
        load()
    }
}
