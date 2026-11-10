import AppKit
import SingularityCore
import SwiftUI

/// The Settings window (⌘,). SwiftUI's `Settings` scene provides the window and the menu item;
/// every change goes through `AppState.updateSettings` (saved to ~/Singularity/settings.json).
struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppState.SettingsTab.general)
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(AppState.SettingsTab.terminal)
            AgentSettings()
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(AppState.SettingsTab.agents)
            PluginSettings()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .tag(AppState.SettingsTab.plugins)
            DataSettings()
                .tabItem { Label("Data & Privacy", systemImage: "hand.raised") }
                .tag(AppState.SettingsTab.data)
        }
        .frame(width: 600)
    }
}

/// A binding into one settings field, writing through `updateSettings`.
@MainActor
private func settingBinding<Value>(_ state: AppState, _ keyPath: WritableKeyPath<AppSettings, Value> & Sendable) -> Binding<Value> {
    Binding(
        get: { state.settings[keyPath: keyPath] },
        set: { value in state.updateSettings { $0[keyPath: keyPath] = value } }
    )
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Picker("Search engine", selection: settingBinding(state, \.searchEngine)) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            if state.settings.searchEngine == .custom {
                TextField("Search URL", text: settingBinding(state, \.customSearchTemplate),
                          prompt: Text("https://example.com/search?q=%s"))
                if !AppSettings.isValidSearchTemplate(state.settings.customSearchTemplate) {
                    Text("Enter an http(s) URL with %s where the search text goes. Until then, DuckDuckGo is used.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("Example") {
                Text(URLInput.classify("swift actors", searchTemplate: state.settings.searchTemplate)?.url.absoluteString ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Terminal

private struct TerminalSettings: View {
    @Environment(AppState.self) private var state

    /// Installed font families whose fonts are monospaced (checked once).
    private static let monospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let first = manager.availableMembers(ofFontFamily: family)?.first,
                  let name = first.first as? String,
                  let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch
        }
    }()

    var body: some View {
        let font = Binding<String>(
            get: { state.settings.terminalFontName ?? "" },
            set: { name in state.updateSettings { $0.terminalFontName = name.isEmpty ? nil : name } }
        )
        Form {
            Picker("Font", selection: font) {
                Text("System monospaced (SF Mono)").tag("")
                Divider()
                ForEach(Self.monospacedFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            Stepper(value: settingBinding(state, \.terminalFontSize), in: 10...24, step: 1) {
                LabeledContent("Size", value: "\(Int(state.settings.terminalFontSize)) pt")
            }
            LabeledContent("Preview") {
                Text("~/Developer › claude")
                    .font(Font(state.terminalFont))
            }
            Toggle("Close the tab when the shell exits normally", isOn: settingBinding(state, \.closeTerminalOnExit))
            Text("Off: the tab stays open and Return starts a new shell. Terminals always use your login shell.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Agents

private struct AgentSettings: View {
    @Environment(AppState.self) private var state
    @State private var copied = false

    /// The launcher inside *this* copy of the app.
    private var launcherPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/singularity-mcp").path
    }

    private var registerCommand: String {
        // Opened straight from Downloads, macOS runs the app from a random temporary folder
        // ("translocation"); that path is gone after the next launch, so don't hand it out.
        if launcherPath.contains("/AppTranslocation/") {
            return "# Move Singularity to the Applications folder and reopen it; the command will then appear here."
        }
        return "claude mcp add -s user singularity -- '\(launcherPath)'"
    }

    var body: some View {
        Form {
            Section("Spaces") {
                ForEach(state.spaces) { space in
                    HStack {
                        Circle().fill(Color(hex: space.colorHex)).frame(width: 10, height: 10)
                        Text(space.name)
                        Spacer()
                        Picker("", selection: policyBinding(space)) {
                            ForEach(AgentPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!space.agentsEnabled)
                        Toggle("", isOn: enabledBinding(space))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help("Allow agents in this Space")
                    }
                }
                Text("Agents only see Spaces that are switched on. Read only: look, never act. Ask before acting: you confirm each action. Allow everything: no questions, still logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Approvals") {
                Picker("Unanswered requests are denied after", selection: settingBinding(state, \.agentApprovalTimeoutSeconds)) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Button("Show Agent Log of Current Space") { state.revealAgentLog() }
            }

            Section("Connect Claude Code") {
                Text("Run this once in a terminal to give Claude Code the Singularity tools in every project:")
                    .font(.callout)
                HStack(alignment: .top) {
                    Text(registerCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(registerCommand, forType: .string)
                        copied = true
                    }
                }
                if !launcherPath.hasPrefix("/Applications/") {
                    Text("This copy of Singularity isn't in /Applications. If you move it, register again with the new path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func enabledBinding(_ space: Space) -> Binding<Bool> {
        Binding(
            get: { state.space(space.id)?.agentsEnabled ?? false },
            set: { enabled in update(space.id) { $0.agentsEnabled = enabled } }
        )
    }

    private func policyBinding(_ space: Space) -> Binding<AgentPolicy> {
        Binding(
            get: { state.space(space.id)?.agentPolicy ?? .ask },
            set: { policy in update(space.id) { $0.agentPolicy = policy } }
        )
    }

    /// Writes through the same path as Edit Space, so connected agents get tools/list_changed.
    private func update(_ id: UUID, _ change: (inout Space) -> Void) {
        guard var space = state.space(id) else { return }
        change(&space)
        state.updateSpace(id, name: space.name, colorHex: space.colorHex, workingDirectory: space.workingDirectory,
                          agentsEnabled: space.agentsEnabled, agentPolicy: space.agentPolicy)
    }
}

// MARK: - Data & privacy

private struct DataSettings: View {
    @Environment(AppState.self) private var state

    private enum ClearKind: String {
        case history = "Clear History"
        case siteData = "Clear Cookies & Site Data"
        case agentLog = "Clear Agent Log"

        func explanation(_ space: String) -> String {
            switch self {
            case .history: return "Forgets the pages visited in “\(space)” (the palette's suggestions). Open tabs stay."
            case .siteData: return "Deletes all cookies, logins, local storage and cached files of “\(space)”. You'll be signed out of every site in this Space."
            case .agentLog: return "Deletes the record of everything agents did in “\(space)”."
            }
        }
    }

    private struct PendingClear: Identifiable {
        let id = UUID()
        let space: Space
        let kind: ClearKind
    }

    @State private var pending: PendingClear?
    @State private var done: String?

    var body: some View {
        Form {
            Section("Where your data lives") {
                pathRow("Spaces, tabs, history, artifacts, agent logs", url: state.paths.root)
                pathRow("Cookies and logins (WebKit's store, one folder per Space)", url: Self.webKitStore)
                Text("Copying ~/Singularity doesn't move your logins; they stay in WebKit's store, tied to Singularity's bundle ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clear data per Space") {
                ForEach(state.spaces) { space in
                    HStack {
                        Circle().fill(Color(hex: space.colorHex)).frame(width: 10, height: 10)
                        Text(space.name)
                        Spacer()
                        Menu("Clear…") {
                            Button(ClearKind.history.rawValue) { pending = PendingClear(space: space, kind: .history) }
                            Button(ClearKind.siteData.rawValue) { pending = PendingClear(space: space, kind: .siteData) }
                            Button(ClearKind.agentLog.rawValue) { pending = PendingClear(space: space, kind: .agentLog) }
                        }
                        .fixedSize()
                    }
                }
                if let done {
                    Text(done)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            pending.map { "\($0.kind.rawValue) in “\($0.space.name)”?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { request in
            Button(request.kind.rawValue, role: .destructive) { perform(request) }
        } message: { request in
            Text(request.kind.explanation(request.space.name) + " This can't be undone.")
        }
    }

    private func perform(_ request: PendingClear) {
        let message = "\(request.kind.rawValue): done for “\(request.space.name)”."
        switch request.kind {
        case .history:
            state.clearHistory(spaceID: request.space.id)
            done = message
        case .agentLog:
            state.clearAgentLog(spaceID: request.space.id)
            done = message
        case .siteData:
            Task {
                await state.clearSiteData(spaceID: request.space.id)
                done = message
            }
        }
    }

    private func pathRow(_ title: String, url: URL) -> some View {
        LabeledContent {
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private static let webKitStore = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/WebKit/\(Bundle.main.bundleIdentifier ?? "dev.roosa.Singularity")/WebsiteDataStore")
}
