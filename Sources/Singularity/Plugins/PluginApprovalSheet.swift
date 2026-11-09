import SingularityCore
import SwiftUI

/// The approval sheet (Settings → Plugins → Review…). It shows a snapshot taken when it opens
/// (`PluginManager.prepareReview`): name, author, version, README, the permissions in plain
/// words with the program paths that will be pinned, and, for an update, the files that changed
/// since the last approval. Approve only succeeds if the plugin is still exactly what is shown;
/// otherwise the sheet says so and shows the current version.
///
/// Plugin-supplied text is shown with `Text(verbatim:)` (plain text, no Markdown, no links).
struct PluginApprovalSheet: View {
    @Environment(AppState.self) private var state
    /// Closes the sheet (SwiftUI hands each presented view this action).
    @Environment(\.dismiss) private var dismiss

    let pluginID: String
    /// Ticked by default on a first approval.
    let currentSpaceID: UUID?

    private enum Phase {
        case loading
        case failed(PluginError)
        case ready(PluginReview)
    }

    @State private var phase: Phase = .loading
    @State private var enabledSpaces: Set<UUID> = []
    @State private var developmentMode = false
    /// The Space and development-mode choices are set once, from the existing approval.
    @State private var choicesSet = false
    @State private var approving = false
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack {
                if approving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Approve") { approve() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApprove)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        // .task runs when the sheet appears, and is cancelled if it closes first.
        .task { await load() }
    }

    private var canApprove: Bool {
        guard case .ready(let review) = phase else { return false }
        return review.canApprove && !approving
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the plugin's files…")
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: PluginText.line(pluginID, max: 60)).font(.title2.bold())
                Text(verbatim: "Problem: " + error.userMessage).foregroundStyle(.red)
                DisclosureGroup("Details") {
                    Text(verbatim: PluginText.block(error.detail, max: 4000))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .ready(let review):
            details(review)
        }
    }

    private func details(_ review: PluginReview) -> some View {
        let manifest = review.manifest
        let approval = state.plugins.plugin(pluginID)?.approval
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: PluginText.line(manifest.name, max: 60))
                    .font(.title2.bold())
                Text(verbatim: "Version \(PluginText.line(manifest.version, max: 20)) · by \(PluginText.line(manifest.author, max: 80))")
                    .foregroundStyle(.secondary)
                if !manifest.description.isEmpty {
                    Text(verbatim: PluginText.line(manifest.description, max: 300))
                }
            }

            if let notice {
                Text(verbatim: notice)
                    .foregroundStyle(.orange)
            }

            if let changes = review.changes(since: approval) {
                section("Changed since you approved it") { changedFiles(changes) }
            } else if approval != nil {
                Text("Approved before Singularity kept a list of files, so it can't show which ones changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("It can") {
                ForEach(review.permissionLines, id: \.self) { line in
                    Text(verbatim: "• " + PluginText.line(line, max: 400))
                }
                ForEach(review.missingCommands, id: \.self) { name in
                    Text(verbatim: "Can't find “\(PluginText.line(name, max: 40))” on this Mac. Install it, then review again.")
                        .foregroundStyle(.red)
                }
            }

            if let readme = review.readme, !readme.isEmpty {
                section("README") {
                    ScrollView {
                        Text(verbatim: readme)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }

            section("On in these Spaces") {
                ForEach(state.spaces) { space in
                    Toggle(isOn: Binding(
                        get: { enabledSpaces.contains(space.id) },
                        set: { on in if on { enabledSpaces.insert(space.id) } else { enabledSpaces.remove(space.id) } }
                    )) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: space.colorHex)).frame(width: 8, height: 8)
                            Text(verbatim: space.name)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Development mode", isOn: $developmentMode)
                    .toggleStyle(.checkbox)
                Text("Restarts the plugin when its files change, without asking again. Leave it off unless you are writing this plugin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }

    /// At most 100 paths per group, so a huge node_modules change can't make the sheet unusable.
    @ViewBuilder
    private func changedFiles(_ changes: PluginFileChanges) -> some View {
        if changes.isEmpty {
            Text("No files changed (only its permissions).")
                .foregroundStyle(.secondary)
        }
        ForEach([("Added", changes.added), ("Removed", changes.removed), ("Changed", changes.changed)], id: \.0) { title, paths in
            if !paths.isEmpty {
                Text(title).font(.subheadline)
                ForEach(paths.prefix(100), id: \.self) { path in
                    Text(verbatim: PluginText.line(path, max: 200))
                        .font(.caption.monospaced())
                }
                if paths.count > 100 {
                    Text(verbatim: "and \(paths.count - 100) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        let result = await state.plugins.prepareReview(pluginID)
        if !choicesSet {
            let approval = state.plugins.plugin(pluginID)?.approval
            enabledSpaces = approval?.enabledSpaces ?? Set([currentSpaceID].compactMap { $0 })
            developmentMode = approval?.developmentMode ?? false
            choicesSet = true
        }
        switch result {
        case .success(let review): phase = .ready(review)
        case .failure(let error): phase = .failed(error)
        }
    }

    private func approve() {
        guard case .ready(let review) = phase else { return }
        approving = true
        let spaces = enabledSpaces.intersection(state.spaces.map(\.id))
        Task {
            defer { approving = false }
            do {
                try await state.plugins.approve(pluginID, expectedFingerprint: review.fingerprint,
                                                enabledSpaces: spaces, developmentMode: developmentMode)
                dismiss()
            } catch PluginManagerError.changedWhileReviewing {
                notice = PluginManagerError.changedWhileReviewing.errorDescription
                await load()
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
