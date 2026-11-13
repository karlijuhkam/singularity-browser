import AppKit
import SingularityCore
import SwiftUI

/// Settings → Plugins: one row per plugin folder in ~/Singularity/plugins, with its status, the
/// Spaces it is on in, development mode, Review…, Remove… and its log; then the plugins shipped
/// with the app that aren't added yet ("Included with Singularity", each with Add).
///
/// Everything a plugin supplies (name, author, description, log lines, error texts) is shown with
/// `Text(verbatim:)`: plain text, never read as Markdown or links. (A string *literal* passed to
/// `Text("…")` is treated as Markdown by SwiftUI; `verbatim:` switches that off.)
struct PluginSettings: View {
    @Environment(AppState.self) private var state

    /// `.sheet(item:)` needs an Identifiable value; this wraps a plugin id.
    struct PluginRef: Identifiable {
        let id: String
    }

    @State private var reviewing: PluginRef?
    @State private var removing: PluginRef?
    /// Shipped plugins being copied right now (their rows show a spinner).
    @State private var adding: Set<String> = []
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Form {
            Section("Plugins") {
                if let warning = state.plugins.stateWarning {
                    Text(verbatim: warning)
                        .foregroundStyle(.orange)
                }
                if state.plugins.plugins.isEmpty {
                    Text("No plugins yet. Add a plugin folder, or put one in ~/Singularity/plugins.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.plugins.plugins) { plugin in
                    PluginRow(plugin: plugin,
                              review: { reviewing = PluginRef(id: plugin.id) },
                              remove: { removing = PluginRef(id: plugin.id) })
                }
            }

            // Shipped inside the app, not in the plugins folder yet: the same Add as the welcome
            // flow's step 4 (copy, then the approval sheet). Empty for a bare debug binary.
            let included = BundledPlugins.notInstalled(state.bundledPlugins,
                                                       installedIDs: Set(state.plugins.plugins.map(\.id)))
            if !included.isEmpty {
                Section("Included with Singularity") {
                    ForEach(included) { plugin in
                        BundledPluginRow(plugin: plugin, adding: $adding, review: { reviewing = PluginRef(id: $0) })
                    }
                }
            }

            Section {
                HStack {
                    Button("Add Plugin…") { addPlugin() }
                    Button("Show Plugins Folder") {
                        try? FileManager.default.createDirectory(at: state.paths.pluginsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(state.paths.pluginsDirectory)
                    }
                    Spacer()
                }
                if let message {
                    Text(verbatim: PluginText.line(message.text, max: 300))
                        .font(.caption)
                        .foregroundStyle(message.isError ? .red : .green)
                }
                Text("Plugins run sandboxed in the background; their page scripts can read the pages they're allowed on. Approve only plugins you've reviewed. They stop when their files change until you approve again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $reviewing) { ref in
            PluginApprovalSheet(pluginID: ref.id, currentSpaceID: state.selectedSpaceID)
                .environment(state)
        }
        .confirmationDialog(
            removeTitle,
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { ref in
            Button("Move to Trash", role: .destructive) { remove(ref.id) }
        } message: { _ in
            Text("This stops the plugin and moves its folder and its data folder to the Trash.")
        }
    }

    private var removeTitle: String {
        guard let removing else { return "" }
        let name = state.plugins.plugin(removing.id)?.validManifest?.name ?? removing.id
        return "Remove “\(PluginText.line(name, max: 60))”?"
    }

    private func addPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a plugin folder (the one that holds plugin.json)."
        // runModal() shows the panel and waits for the user's choice.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let id = try await state.plugins.addPlugin(from: url)
                message = ("Added. Review it to switch it on.", false)
                reviewing = PluginRef(id: id)
            } catch {
                message = (error.localizedDescription, true)
            }
        }
    }

    private func remove(_ id: String) {
        Task {
            do {
                try await state.plugins.remove(id)
                message = ("Moved to the Trash.", false)
            } catch {
                message = (error.localizedDescription, true)
            }
        }
    }
}

// MARK: - One plugin

private struct PluginRow: View {
    @Environment(AppState.self) private var state
    let plugin: InstalledPlugin
    let review: () -> Void
    let remove: () -> Void

    var body: some View {
        let manifest = plugin.validManifest
        let status = plugin.statusLine
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: PluginText.line(manifest?.name ?? plugin.id, max: 60))
                    .font(.headline)
                    .lineLimit(1)
                if let manifest {
                    Text(verbatim: PluginText.line(manifest.version, max: 20))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(verbatim: PluginText.line(status.text, max: 160))
                    .foregroundStyle(color(status.tone))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            if let manifest {
                Text(verbatim: "by " + PluginText.line(manifest.author, max: 80))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !manifest.description.isEmpty {
                    Text(verbatim: PluginText.line(manifest.description, max: 300))
                        .font(.callout)
                        .lineLimit(3)
                }
            }
            if case .invalid(let error) = plugin.status {
                DisclosureGroup("Details") {
                    Text(verbatim: PluginText.block(error.detail, max: 4000))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let problem = plugin.pageProblem {
                Text(verbatim: "Page script: " + PluginText.line(problem, max: 500))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if let approval = plugin.approval {
                // Not for a panel plugin without a page script (see PluginApprovalSheet).
                if manifest.map(PluginApprovalSheet.showsSpaceSwitches) ?? true {
                    spaces(approval)
                }
                developmentMode(approval)
            }

            HStack {
                Button("Review…", action: review)
                    .disabled(manifest == nil)
                Button("Remove…", role: .destructive, action: remove)
                Spacer()
            }

            DisclosureGroup("Log (\(plugin.logs.count) lines)") {
                ScrollView {
                    Text(verbatim: plugin.logs.isEmpty ? "Nothing yet." : plugin.logs.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
        }
        .padding(.vertical, 4)
    }

    /// One checkbox per Space; ticking writes the approval at once (no new review).
    private func spaces(_ approval: PluginApproval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On in these Spaces")
                .font(.subheadline)
            ForEach(state.spaces) { space in
                Toggle(isOn: Binding(
                    get: { state.plugins.plugin(plugin.id)?.approval?.enabledSpaces.contains(space.id) ?? false },
                    set: { state.plugins.setEnabled(plugin.id, space: space.id, $0) }
                )) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: space.colorHex)).frame(width: 8, height: 8)
                        Text(verbatim: space.name)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func developmentMode(_ approval: PluginApproval) -> some View {
        let canSwitch = PluginStatusText.canSetDevelopmentMode(to: !approval.developmentMode, status: plugin.status)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle("Development mode", isOn: Binding(
                get: { state.plugins.plugin(plugin.id)?.approval?.developmentMode ?? false },
                set: { state.plugins.setDevelopmentMode(plugin.id, $0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!canSwitch)
            Text(canSwitch
                 ? "Restarts the plugin when its files change, without asking. Asking for more permissions still needs your approval."
                 : "Review the changes first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func color(_ tone: PluginStatusText.Tone) -> Color {
        switch tone {
        case .on: return .green
        case .off: return .secondary
        case .attention: return .orange
        case .problem: return .red
        }
    }
}
