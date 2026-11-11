import AppKit
import SingularityCore
import SwiftUI

// The four steps of the welcome flow. Each one draws its title, text and controls; the frame
// around them (orb, step dots, Back, Skip setup and the step's buttons) is `OnboardingView`.
// Wording comes from the spec (docs/superpowers/specs/2026-11-11-onboarding-design.md).

/// A step's title and its one or two sentences.
struct StepHeader: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A `String` variable (not a literal) is shown as-is, never read as Markdown.
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1. Welcome

struct WelcomeStep: View {
    var body: some View {
        StepHeader(title: "Welcome to Singularity",
                   text: "A browser built around Spaces. Web pages, terminals and the pages your agents make sit side by side in one sidebar.")
    }
}

// MARK: - 2. Your first Space

/// Step 2's fields while they are being edited. Only Continue writes them to the Space.
struct SpaceDraft: Equatable {
    var name = ""
    var colorHex = SpaceColors.presets[0]
    var workingDirectory = "~"

    init() {}

    init(_ space: Space) {
        name = space.name
        colorHex = space.colorHex
        workingDirectory = space.workingDirectory
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct SpaceStep: View {
    @Binding var draft: SpaceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(title: "Your first Space",
                       text: "A Space keeps its own tabs, logins and working folder.")
            // The same three rows as Edit Space; `.columns` lines their labels up on the left.
            Form {
                SpaceFields(name: $draft.name, colorHex: $draft.colorHex, workingDirectory: $draft.workingDirectory)
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - 3. Connect your agent

struct AgentsStep: View {
    @Environment(AppState.self) private var state
    /// Owned by `OnboardingView`, so going Back and forward again keeps what was found.
    let connector: AgentConnector

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(title: "Connect your agent",
                       text: "Agents you already use can drive this browser. They ask before acting.")

            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        AgentConnectRows(connector: connector)
                    }
                    .padding(8)
                }

                // Connecting an agent and opening a Space to agents are separate acts: these
                // switches show each Space's real setting (off on a new install) and change
                // only `agentsEnabled`; the policy stays as it is ("ask").
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.spaces) { space in
                            spaceSwitch(space)
                        }
                    }
                    .padding(8)
                }
            }
        }
        // The check (reads the agents' config files, looks for the programs) runs each time the
        // step appears, not at launch.
        .task { await connector.refresh() }
    }

    private func spaceSwitch(_ space: Space) -> some View {
        let title = "Let agents use “\(space.name)”"
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: space.colorHex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text("They ask before clicking or typing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: Binding(
                get: { state.space(space.id)?.agentsEnabled ?? false },
                set: { state.setAgentsEnabled($0, spaceID: space.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}

// MARK: - 4. Plugins

struct PluginsStep: View {
    @Environment(AppState.self) private var state

    /// The plugins shipped inside the app (`Contents/Resources/Plugins`). Read once: the bundle
    /// doesn't change while the app runs. Empty for a bare debug binary.
    private static let bundled: [BundledPlugin] = BundledPlugins.list(in: BundledPlugins.pluginsFolder(resources: resources))
    private static var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    @State private var reviewing: PluginSettings.PluginRef?
    @State private var adding: Set<String> = []
    /// Plugin id → why adding it failed.
    @State private var errors: [String: String] = [:]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(title: "Plugins", text: "Small add-ons you can read and approve.")

            VStack(alignment: .leading, spacing: 18) {
                if !Self.bundled.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Self.bundled) { plugin in
                                row(plugin)
                            }
                        }
                        .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or have your agent write one:")
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: prompt)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(prompt, forType: .string)
                                copied = true
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
        // The normal approval sheet, exactly as Settings → Plugins → Add Plugin… shows it.
        .sheet(item: $reviewing) { ref in
            PluginApprovalSheet(pluginID: ref.id, currentSpaceID: state.selectedSpaceID)
                .environment(state)
        }
    }

    private var prompt: String {
        BundledPlugins.authoringPrompt(guide: BundledPlugins.guideFolder(resources: Self.resources),
                                       pluginsDirectory: state.paths.pluginsDirectory)
    }

    private func row(_ plugin: BundledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PluginText.line(plugin.name, max: 60))
                    Text(verbatim: PluginText.line(plugin.summary, max: 200))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                action(plugin)
            }
            if let error = errors[plugin.id] {
                Text(verbatim: PluginText.line(error, max: 300))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Add (not in ~/Singularity/plugins yet), Review… (copied but not approved, or changed), or
    /// "Added" (approved).
    @ViewBuilder
    private func action(_ plugin: BundledPlugin) -> some View {
        if adding.contains(plugin.id) {
            ProgressView().controlSize(.small)
        } else if let installed = state.plugins.plugin(plugin.id) {
            if installed.needsReview {
                Button("Review…") { reviewing = PluginSettings.PluginRef(id: plugin.id) }
            } else {
                Text("Added").foregroundStyle(.secondary)
            }
        } else {
            Button("Add") { add(plugin) }
        }
    }

    /// Copies the bundled folder into the plugins folder (as Add Plugin… does), then brings up the
    /// approval sheet. Nothing runs until the user approves it there.
    private func add(_ plugin: BundledPlugin) {
        errors[plugin.id] = nil
        adding.insert(plugin.id)
        Task {
            defer { adding.remove(plugin.id) }
            do {
                let id = try await state.plugins.addPlugin(from: plugin.folder)
                reviewing = PluginSettings.PluginRef(id: id)
            } catch {
                // `PluginManagerError.addFailed` describes itself with the installer's `userMessage`.
                errors[plugin.id] = error.localizedDescription
            }
        }
    }
}
