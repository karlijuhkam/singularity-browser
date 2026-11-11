import AppKit
import SingularityCore
import SwiftUI

/// A Space's name, colour and terminal folder: the three fields shared by the Space editor sheet
/// and the welcome flow's "Your first Space" step. The caller owns the values (and decides when to
/// save them); these controls only edit the bindings.
///
/// `body` lists the three rows without a container, so inside a `Form` each one becomes its own
/// form row (label on the left, control on the right), as the editor sheet always showed them.
struct SpaceFields: View {
    @Binding var name: String
    @Binding var colorHex: String
    @Binding var workingDirectory: String

    init(name: Binding<String>, colorHex: Binding<String>, workingDirectory: Binding<String>) {
        _name = name
        _colorHex = colorHex
        _workingDirectory = workingDirectory
    }

    var body: some View {
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
