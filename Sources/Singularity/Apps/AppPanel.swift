import AppKit
import SingularityCore
import SwiftUI

/// The button at the right end of the address row for a tab that shows an **app** (an artifact
/// folder with a Worker, see `ArtifactApps`). It sits where a web tab has its site settings
/// button, and opens the app's panel. Hidden for every other tab.
struct AppPanelButton: View {
    @Environment(AppState.self) private var state
    @State private var isOpen = false

    var body: some View {
        if let space = state.selectedSpace, let app = AppPanelButton.app(of: space.selectedTab, in: space, state: state) {
            let status = state.apps.status(space: space.id, app: app)
            Button {
                isOpen.toggle()
            } label: {
                // Orange while the Worker has an error the owner hasn't seen to.
                Image(systemName: "shippingbox")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(status.lastError != nil && !status.running ? Color.orange : Color.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("App: Worker, database, connections and keys")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                AppPanel(spaceID: space.id, app: app)
            }
        }
    }

    /// The app the tab's page belongs to: only for an artifact tab whose file is inside an app.
    @MainActor
    static func app(of tab: BrowserTab?, in space: Space, state: AppState) -> String? {
        guard let path = tab?.artifactPath else { return nil }
        return state.apps.app(forArtifactPath: path, space: space.id)
    }
}

/// What the owner sees and decides about one app: its Worker, its database, the hosts it may
/// reach and its keys. Key values are typed here and never shown again.
///
/// No button here is a default button: Return in a field must never allow a host or save a key
/// by accident.
struct AppPanel: View {
    @Environment(AppState.self) private var state
    let spaceID: UUID
    let app: String

    @State private var newHost = ""
    @State private var hostError: String?
    @State private var keyName = ""
    @State private var keyHost = ""
    @State private var keyValue = ""
    @State private var keyReadable = false
    @State private var keyError: String?
    @State private var showsLog = false

    var body: some View {
        let record = state.apps.record(space: spaceID, app: app)
        let status = state.apps.status(space: spaceID, app: app)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                workerSection(status)
                Divider()
                databaseSection
                Divider()
                connectionsSection(record)
                Divider()
                keysSection(record, status)
            }
            .padding(14)
        }
        .frame(width: 340)
        .frame(maxHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: app).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("An app: its pages are files, its Worker runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Worker

    @ViewBuilder
    private func workerSection(_ status: AppWorkerStatus) -> some View {
        HStack {
            Label(AppPanel.workerText(status), systemImage: status.running ? "circle.fill" : "circle")
                .foregroundStyle(status.running ? Color.green : (status.lastError != nil ? Color.orange : Color.secondary))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Restart") { state.apps.restart(space: spaceID, app: app) }
                .controlSize(.small)
        }
        if let error = status.lastError, !status.running {
            // The Worker's own words (a compiler message, a stack): shown as plain text.
            Text(verbatim: String(error.prefix(1200)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        DisclosureGroup("Log", isExpanded: $showsLog) {
            let lines = showsLog ? state.apps.logLines(space: spaceID, app: app, count: 20) : []
            Text(verbatim: lines.isEmpty ? "Nothing logged yet." : lines.joined(separator: "\n"))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    static func workerText(_ status: AppWorkerStatus) -> String {
        if status.running { return "Worker is running" }
        return status.lastError == nil ? "Worker is stopped" : "Worker could not run"
    }

    // MARK: Database

    @ViewBuilder
    private var databaseSection: some View {
        let folder = state.apps.dataFolder(space: spaceID, app: app)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Data").font(.subheadline.weight(.semibold))
                Text(verbatim: AppPanel.dataText(folder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show in Finder") {
                guard let folder else { return }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
            .controlSize(.small)
        }
    }

    /// "DB.sqlite (48 KB)" for each database file in the app's data folder, or that there is none.
    static func dataText(_ folder: URL?) -> String {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "No database yet. It is made from the app's migrations when its Worker first starts."
        }
        let databases = files.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !databases.isEmpty else { return "No database (the app's wrangler.jsonc names none)." }
        return databases.map { file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(file.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        }.joined(separator: ", ")
    }

    // MARK: Connections

    @ViewBuilder
    private func connectionsSection(_ record: AppRecord) -> some View {
        Text("Connections").font(.subheadline.weight(.semibold))
        Text("The only hosts this app's Worker can send requests to.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if record.hosts.isEmpty {
            Text("None. The app works on this Mac only.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(record.hosts.sorted(), id: \.self) { host in
            HStack {
                Text(verbatim: host).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Remove") { state.apps.removeHost(host, space: spaceID, app: app) }
                    .controlSize(.small)
            }
        }
        // Hosts the owner said no to (or did not answer about) since the Worker last started.
        ForEach(state.apps.deniedHosts(space: spaceID, app: app), id: \.self) { host in
            HStack {
                Text(verbatim: host).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("denied").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Allow") { state.apps.allowHost(host, space: spaceID, app: app) }
                    .controlSize(.small)
            }
        }
        HStack {
            TextField("api.example.com", text: $newHost)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .autocorrectionDisabled()
            Button("Add") { addHost() }
                .controlSize(.small)
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let hostError {
            Text(hostError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
        guard AppHostRules.isValidHost(host) else {
            hostError = AppCenter.KeyError.badHost.errorDescription
            return
        }
        state.apps.allowHost(host, space: spaceID, app: app)
        newHost = ""
        hostError = nil
    }

    // MARK: Keys

    @ViewBuilder
    private func keysSection(_ record: AppRecord, _ status: AppWorkerStatus) -> some View {
        Text("Keys").font(.subheadline.weight(.semibold))
        Text("Kept in your keychain. The Worker reads a key as env.NAME; Singularity puts the real value only into requests for the key's host.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(record.keys, id: \.name) { key in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: key.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: key.readable ? "for \(key.host) · the app's code can read it" : "for \(key.host)")
                        .font(.caption)
                        .foregroundStyle(key.readable ? Color.orange : Color.secondary)
                }
                Spacer()
                Button("Change") {
                    keyName = key.name
                    keyHost = key.host
                    keyReadable = key.readable
                    keyValue = ""
                }
                .controlSize(.small)
                Button("Delete") { state.apps.deleteKey(name: key.name, space: spaceID, app: app) }
                    .controlSize(.small)
            }
        }
        // Names the Worker's code read from env that have no key yet.
        ForEach(status.unsetKeys.filter { name in !record.keys.contains { $0.name == name } }, id: \.self) { name in
            HStack {
                Text(verbatim: name).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("not set").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Set…") { keyName = name }
                    .controlSize(.small)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            TextField("NAME", text: $keyName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            TextField("Host it belongs to (api.example.com)", text: $keyHost)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            // A secure field: the value is dots on screen and is never shown again after saving.
            SecureField(AppPanel.valuePrompt(record, name: keyName), text: $keyValue)
                .textFieldStyle(.roundedBorder)
            Toggle("The app's code can read this key", isOn: $keyReadable)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.small)
            Text(keyReadable
                 ? "The Worker gets the real value and could send it to any host you allowed, or store it. Only for APIs that sign requests with the key."
                 : "The Worker only ever sees a placeholder.")
                .font(.caption)
                .foregroundStyle(keyReadable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Save Key") { saveKey() }
                    .controlSize(.small)
                    .disabled(keyName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .controlSize(.small)
    }

    /// The value field's hint: a key that exists keeps its value when the field is left empty.
    static func valuePrompt(_ record: AppRecord, name: String) -> String {
        record.keys.contains { $0.name == name.trimmingCharacters(in: .whitespaces) } ? "Value (leave empty to keep it)" : "Value"
    }

    private func saveKey() {
        do {
            try state.apps.setKey(name: keyName.trimmingCharacters(in: .whitespaces),
                                  host: keyHost.trimmingCharacters(in: .whitespaces).lowercased(),
                                  readable: keyReadable, value: keyValue.isEmpty ? nil : keyValue,
                                  space: spaceID, app: app)
            keyName = ""
            keyHost = ""
            keyValue = ""
            keyReadable = false
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}
