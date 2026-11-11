import AppKit
import SingularityCore
import SwiftUI

// The controls of the welcome flow's steps 2–4 (step 1 has none). The frame around them (orb,
// title and text, step dots, Back, Skip setup and the step's buttons) is `OnboardingView`.
// Wording comes from the spec (docs/superpowers/specs/2026-11-11-onboarding-design.md).

/// Text sizes inside the steps: a row's name, and the line(s) under it (never below 12 pt).
private enum StepFont {
    static let name = Font.system(size: 14)
    static let caption = Font.system(size: 12)
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
        // The same three fields as Edit Space, laid out with more room.
        SpaceFields(name: $draft.name, colorHex: $draft.colorHex, workingDirectory: $draft.workingDirectory,
                    style: .roomy)
    }
}

// MARK: - 3. Connect your agent

struct AgentsStep: View {
    @Environment(AppState.self) private var state
    /// Owned by `OnboardingView`, so going Back and forward again keeps what was found.
    let connector: AgentConnector

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    AgentConnectRows(connector: connector, style: .roomy)
                }
                .padding(10)
            }

            // Connecting an agent and opening a Space to agents are separate acts: these
            // switches show each Space's real setting (off on a new install) and change
            // only `agentsEnabled`; the policy stays as it is ("ask").
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(state.spaces) { space in
                        spaceSwitch(space)
                    }
                }
                .padding(10)
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
                    .font(StepFont.name)
                Text("They ask before clicking or typing")
                    .font(StepFont.caption)
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

    /// Plugins being copied right now; owned by `OnboardingView`, which keeps the buttons that
    /// leave this step off meanwhile (so the approval sheet that follows can't be lost).
    @Binding var adding: Set<String>

    /// Plugin id → why adding it failed.
    @State private var errors: [String: String] = [:]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !Self.bundled.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.bundled) { plugin in
                            if plugin.id != Self.bundled.first?.id { Divider() }
                            row(plugin)
                        }
                    }
                    .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Or have your agent write one:")
                    .font(StepFont.name)
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Text(verbatim: prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = true
                        }
                    }
                    .padding(10)
                }
            }
        }
        // "Copied" turns back into "Copy" after two seconds. (`.task(id:)` starts again, and
        // cancels the previous wait, each time `copied` changes.)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
        // The normal approval sheet, exactly as Settings → Plugins → Add Plugin… shows it. Which
        // plugin it is for lives in `AppState`, so ⌘W knows the sheet is open (`closeTabCommand`).
        .sheet(item: Binding(get: { state.welcomePluginReview.map(PluginSettings.PluginRef.init) },
                             set: { state.welcomePluginReview = $0?.id })) { ref in
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
                        .font(StepFont.name)
                    Text(verbatim: PluginText.line(plugin.summary, max: 200))
                        .font(StepFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                action(plugin)
            }
            if let error = errors[plugin.id] {
                Text(verbatim: PluginText.line(error, max: 300))
                    .font(StepFont.caption)
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
                Button("Review…") { state.welcomePluginReview = plugin.id }
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
                state.welcomePluginReview = id
            } catch {
                // `PluginManagerError.addFailed` describes itself with the installer's `userMessage`.
                errors[plugin.id] = error.localizedDescription
            }
        }
    }
}
