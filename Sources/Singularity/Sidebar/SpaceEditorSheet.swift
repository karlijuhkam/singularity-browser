import AppKit
import SingularityCore
import SwiftUI

/// Sheet for creating or editing a Space: name, colour, terminal working directory.
struct SpaceEditorSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: SpaceEditorRequest

    @State private var name = ""
    @State private var colorHex = SpaceColors.presets[0]
    @State private var workingDirectory = "~"

    private var existing: Space? { request.spaceID.flatMap { state.space($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Space" : "Edit Space")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                LabeledContent("Colour") {
                    HStack(spacing: 6) {
                        ForEach(SpaceColors.presets, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(hex == colorHex ? 0.8 : 0), lineWidth: 2))
                                .onTapGesture { colorHex = hex }
                        }
                    }
                }

                LabeledContent("Terminal folder") {
                    HStack {
                        Text(workingDirectory)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }

                if let existing {
                    LabeledContent("Folder on disk") {
                        Text("~/Singularity/spaces/\(existing.slug)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let existing {
                name = existing.name
                colorHex = existing.colorHex
                workingDirectory = existing.workingDirectory
            } else {
                // Pick the first colour no other Space uses yet.
                let used = Set(state.spaces.map(\.colorHex))
                colorHex = SpaceColors.presets.first { !used.contains($0) } ?? SpaceColors.presets[0]
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing {
            state.updateSpace(existing.id, name: trimmed, colorHex: colorHex, workingDirectory: workingDirectory)
        } else {
            state.createSpace(name: trimmed, colorHex: colorHex, workingDirectory: workingDirectory)
        }
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Store paths under the home folder as "~/…" so space.json stays portable.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        workingDirectory = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// A tiny sheet that asks for one name (used for folders).
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: NameRequest
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.headline)
            TextField("Name", text: $value)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { value = request.initialValue }
    }

    private func commit() {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        request.onCommit(trimmed)
        dismiss()
    }
}
