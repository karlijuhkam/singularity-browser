import AppKit
import SingularityCore
import SwiftUI

/// The Projects list in Edit Space: one row per project (name, folder, remove) and "Add Project…".
/// It only edits the binding; the sheet saves the list with `AppState.setProjects`.
struct ProjectsEditor: View {
    @Binding var projects: [Project]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if projects.isEmpty {
                Text("Folders (usually repositories) that new terminals can start in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // `$projects` gives each row a binding to its own element, so typing renames in place.
            ForEach($projects) { $project in
                HStack(spacing: 8) {
                    TextField("Name", text: $project.name, prompt: Text(Project.defaultName(forPath: project.path)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head) // keep the end of the path: that is the telling part
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        projects.removeAll { $0.id == project.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this project (the folder on disk is not touched)")
                }
            }
            Button("Add Project…", action: addProject)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        // `runModal` blocks until the panel closes (it runs its own event loop).
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            projects.append(Project.forFolder(url.path))
        }
    }
}

/// The small label with a project's name on a terminal's sidebar row.
struct ProjectTag: View {
    let name: String

    var body: some View {
        Text(Self.short(name))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            // The tag keeps its own width and the tab's title truncates instead: a tag cut to
            // "acm…" would say nothing. (`short` keeps a very long name from taking the row.)
            .fixedSize()
            .layoutPriority(1)
    }

    /// A name over 18 characters is cut in the middle: "acme-web-frontend-monorepo" → "acme-web…monorepo".
    static func short(_ name: String) -> String {
        guard name.count > 18 else { return name }
        return name.prefix(8) + "…" + name.suffix(8)
    }
}
