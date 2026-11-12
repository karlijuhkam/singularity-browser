import AppKit
import SingularityCore
import SwiftUI

/// Sheet for creating or editing a Space: name, colour, terminal working directory, projects.
struct SpaceEditorSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: SpaceEditorRequest

    @State private var name = ""
    @State private var colorHex = SpaceColors.presets[0]
    @State private var workingDirectory = "~"
    @State private var agentsEnabled = false
    @State private var agentPolicy: AgentPolicy = .ask
    @State private var agentInspection = false
    @State private var projects: [Project] = []

    private var existing: Space? { request.spaceID.flatMap { state.space($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Space" : "Edit Space")
                .font(.headline)

            Form {
                SpaceFields(name: $name, colorHex: $colorHex, workingDirectory: $workingDirectory)

                LabeledContent("Projects") {
                    ProjectsEditor(projects: $projects)
                }

                Toggle(isOn: $agentsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow agents")
                        Text(agentsHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if agentsEnabled {
                    Picker("Agents may", selection: $agentPolicy) {
                        ForEach(AgentPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(policyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if agentsEnabled {
                    Toggle(isOn: $agentInspection) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Let agents see console and network")
                            Text("Agents can then read console errors and failed requests, only on sites you also switch on in the site settings (the button next to the address). Requests and responses can contain passwords and tokens.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                agentsEnabled = existing.agentsEnabled
                agentPolicy = existing.agentPolicy
                agentInspection = existing.agentInspection
                projects = existing.projects
            } else {
                // Pick the first colour no other Space uses yet.
                let used = Set(state.spaces.map(\.colorHex))
                colorHex = SpaceColors.presets.first { !used.contains($0) } ?? SpaceColors.presets[0]
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // A project whose name was cleared gets its folder's name back.
        let projects = projects.map { Project(id: $0.id, name: $0.displayName, path: $0.path) }
        if let existing {
            state.updateSpace(existing.id, name: trimmed, colorHex: colorHex, workingDirectory: workingDirectory,
                              agentsEnabled: agentsEnabled, agentPolicy: agentPolicy)
            state.setAgentInspection(agentInspection, spaceID: existing.id)
            state.setProjects(projects, spaceID: existing.id)
        } else {
            let space = state.createSpace(name: trimmed, colorHex: colorHex, workingDirectory: workingDirectory,
                                          agentsEnabled: agentsEnabled, agentPolicy: agentPolicy)
            state.setAgentInspection(agentInspection, spaceID: space.id)
            state.setProjects(projects, spaceID: space.id)
        }
        dismiss()
    }

    private var agentsHint: String {
        let slug = existing?.slug ?? Slug.make(from: name.isEmpty ? "space" : name)
        return "Agents connected over MCP can read and operate this Space's tabs (tools named \(slug).…)."
    }

    private var policyHint: String {
        switch agentPolicy {
        case .readOnly: return "Agents can list tabs, read pages and take screenshots, but can't click, type, open or close anything."
        case .ask: return "You confirm each click, typing, page opened or tab closed. Form submissions and going to another site always ask."
        case .allowAll: return "Agents act without asking. Everything they do is still recorded in the agent log."
        }
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
