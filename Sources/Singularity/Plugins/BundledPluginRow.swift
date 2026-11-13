import Foundation
import SingularityCore
import SwiftUI

extension BundledPlugins {
    /// The plugins shipped inside this app (`Contents/Resources/Plugins`). Read once: the bundle
    /// doesn't change while the app runs. Empty for a bare debug binary.
    static let inApp: [BundledPlugin] = list(in: pluginsFolder(resources: appResources))

    /// The app's `Contents/Resources` (the binary's folder for a bare debug binary).
    static var appResources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
}

/// What a bundled plugin's row shows on its right.
enum PluginRowAction: Equatable {
    case adding  // a spinner while it is being copied
    case add     // not in ~/Singularity/plugins yet
    case review  // copied but not approved, or changed since ("Review…")
    case added   // approved

    /// `installedNeedsReview`: nil when the plugin is not installed, else its `needsReview`.
    static func of(adding: Bool, installedNeedsReview: Bool?) -> PluginRowAction {
        if adding { return .adding }
        guard let needsReview = installedNeedsReview else { return .add }
        return needsReview ? .review : .added
    }
}

/// One plugin shipped with the app: its name, description and Add (or Review…, or Added). Used by
/// the welcome flow's step 4 and by Settings → Plugins ("Included with Singularity"), so adding works
/// the same in both: Add copies the folder into the plugins folder (`PluginManager.addPlugin`, as
/// Add Plugin… does), then `review` shows the normal approval sheet. Nothing runs until the user
/// approves it there; nothing here approves.
struct BundledPluginRow: View {
    @Environment(AppState.self) private var state
    let plugin: BundledPlugin
    /// Plugins being copied right now (the owner of this set may keep other buttons off meanwhile).
    @Binding var adding: Set<String>
    /// Shows the approval sheet for a plugin id (after Add, and for Review…).
    let review: (String) -> Void
    var nameFont: Font = .headline
    var captionFont: Font = .caption

    /// Why adding failed.
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PluginText.line(plugin.name, max: 60))
                        .font(nameFont)
                    Text(verbatim: PluginText.line(plugin.summary, max: 200))
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                action
            }
            if let error {
                Text(verbatim: PluginText.line(error, max: 300))
                    .font(captionFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch PluginRowAction.of(adding: adding.contains(plugin.id),
                                  installedNeedsReview: state.plugins.plugin(plugin.id)?.needsReview) {
        case .adding:
            ProgressView().controlSize(.small)
        case .add:
            Button("Add") { add() }
        case .review:
            Button("Review…") { review(plugin.id) }
        case .added:
            Text("Added").foregroundStyle(.secondary)
        }
    }

    private func add() {
        error = nil
        adding.insert(plugin.id)
        Task {
            defer { adding.remove(plugin.id) }
            do {
                let id = try await state.plugins.addPlugin(from: plugin.folder)
                review(id)
            } catch {
                // `PluginManagerError.addFailed` describes itself with the installer's `userMessage`.
                self.error = error.localizedDescription
            }
        }
    }
}
