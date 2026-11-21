import AppKit
import SingularityCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Extensions: every installed browser extension with its status, its Space switches,
/// Options…, Check for Update (store ones), Remove; and Add Extension… for a folder or file.
/// Text from an extension is shown with `Text(verbatim:)`.
struct ExtensionSettings: View {
    @Environment(AppState.self) private var state
    @State private var removing: ExtensionRecord?

    var body: some View {
        Form {
            Section("Extensions") {
                if let warning = state.extensions.stateWarning {
                    Text(verbatim: warning).foregroundStyle(.orange)
                }
                let records = state.extensions.records.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if records.isEmpty {
                    Text("No extensions yet. Open an extension's page in Chrome Web Store and click “Add to Singularity”, or add a folder or a .zip, .crx or .xpi file.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(records) { record in
                    ExtensionRow(record: record, remove: { removing = record })
                }
            }
            Section {
                HStack {
                    Button("Add Extension…") { addExtension() }
                    Spacer()
                    Button("Open Chrome Web Store") {
                        if let url = URL(string: "https://chromewebstore.google.com/category/extensions") {
                            state.showMainWindow()
                            state.openInNewTab(url)
                        }
                    }
                }
                Text("Extensions work as in Safari. Chrome extensions that need Chrome-only features are adapted to run here where Singularity can (1Password's is). Each Space runs its own copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
        .confirmationDialog(removing.map { "Remove “\($0.name)”?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let removing { state.extensions.remove(removing.id) }
                removing = nil
            }
        } message: {
            Text("Its settings and data in every Space are deleted too.")
        }
    }

    private func addExtension() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an extension folder (with manifest.json) or a .zip, .crx or .xpi file."
        var types: [UTType] = [.zip, .folder]
        if let crx = UTType(filenameExtension: "crx") { types.append(crx) }
        if let xpi = UTType(filenameExtension: "xpi") { types.append(xpi) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.extensions.add(file: url, fromSpace: state.selectedSpaceID)
    }
}

private struct ExtensionRow: View {
    @Environment(AppState.self) private var state
    let record: ExtensionRecord
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PluginText.line(record.name, max: 80)).font(.headline)
                    Text(verbatim: "Version \(PluginText.line(record.version, max: 40)) · "
                         + (record.source == .store ? "Chrome Web Store" : "added from a file"))
                        .font(.caption).foregroundStyle(.secondary)
                    statusLine
                }
                Spacer()
                if record.source == .store {
                    Button(state.extensions.statuses[record.id] == .ready ? "Check for Update" : "Download Again") {
                        state.extensions.addFromStore(record.id, fromSpace: state.selectedSpaceID,
                                                      isUpdateCheck: state.extensions.statuses[record.id] == .ready)
                    }
                    .disabled(state.extensions.downloading.contains(record.id))
                }
                Button("Remove…", action: remove)
            }
            ForEach(state.spaces) { space in
                HStack {
                    Toggle(isOn: Binding(
                        get: { record.enabledSpaces.contains(space.id) },
                        set: { state.extensions.setEnabled(record.id, spaceID: space.id, on: $0) }
                    )) {
                        Text(verbatim: space.name)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    if state.extensions.context(record.id, in: space.id)?.optionsPageURL != nil {
                        Button("Options…") {
                            state.showMainWindow()
                            state.extensions.openOptions(record.id, spaceID: space.id)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.extensions.statuses[record.id] {
        case .changed:
            Text("Paused: its files changed since you installed it. Add it again to use it.").font(.caption).foregroundStyle(.orange)
        case .missing:
            Text("Paused: its folder is gone.").font(.caption).foregroundStyle(.orange)
        case .cannotAdapt:
            Text("Paused: couldn't be adapted by this version of Singularity.").font(.caption).foregroundStyle(.orange)
        case .ready, nil:
            if let error = state.extensions.loadErrors[record.id] {
                Text(verbatim: "Couldn't start: " + PluginText.line(error, max: 200)).font(.caption).foregroundStyle(.red)
            }
        }
        if let summary = record.adaptationSummary, record.adaptedFingerprint != nil {
            Text(verbatim: "Adapted: " + summary.short).font(.caption).foregroundStyle(.secondary)
        }
        if let note = state.extensions.adaptNotes[record.id] {
            Text(verbatim: note).font(.caption).foregroundStyle(.orange)
        }
    }
}
