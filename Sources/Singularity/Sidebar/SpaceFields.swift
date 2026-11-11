import AppKit
import SingularityCore
import SwiftUI

/// A Space's name, colour and terminal folder: the three fields shared by the Space editor sheet
/// and the welcome flow's "Your first Space" step. The caller owns the values (and decides when to
/// save them); these controls only edit the bindings.
struct SpaceFields: View {
    /// `.form`: three form rows (label left, control right), as the editor sheet shows them.
    /// `.roomy`: the welcome flow's layout: each label above its control, full width, larger dots.
    enum Style {
        case form, roomy
    }

    @Binding var name: String
    @Binding var colorHex: String
    @Binding var workingDirectory: String
    let style: Style

    init(name: Binding<String>, colorHex: Binding<String>, workingDirectory: Binding<String>, style: Style = .form) {
        _name = name
        _colorHex = colorHex
        _workingDirectory = workingDirectory
        self.style = style
    }

    var body: some View {
        switch style {
        case .form:
            // No container: inside a `Form` each of the three becomes its own row.
            TextField("Name", text: $name)
            LabeledContent("Colour") { colorDots(size: 20, spacing: 6) }
            LabeledContent("Terminal folder") {
                HStack {
                    folderText
                    Button("Choose…", action: chooseFolder)
                }
            }
        case .roomy:
            VStack(alignment: .leading, spacing: 22) {
                labelled("Name") {
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }
                labelled("Colour") { colorDots(size: 24, spacing: 10) }
                labelled("Terminal folder") {
                    HStack(spacing: 10) {
                        // Shown like a (read-only) field, so the path and its button read as one row.
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            folderText
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.5)))
                        Button("Choose…", action: chooseFolder)
                            .controlSize(.large)
                    }
                }
            }
        }
    }

    /// A small label above its control (roomy style).
    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The eight preset colours; the chosen one has a ring.
    private func colorDots(size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(SpaceColors.presets, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(.primary.opacity(hex == colorHex ? 0.8 : 0), lineWidth: 2))
                    .onTapGesture { colorHex = hex }
            }
        }
    }

    private var folderText: some View {
        Text(workingDirectory)
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(.secondary)
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
