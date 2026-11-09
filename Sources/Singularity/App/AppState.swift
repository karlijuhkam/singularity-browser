import AppKit
import Observation
import SingularityCore
import WebKit

/// The single source of truth for the UI. Views read from it and call its methods;
/// they never change `spaces` directly.
///
/// `@Observable` (Swift's Observation framework, macOS 14+) makes SwiftUI re-render any view
/// that read a property when that property changes. `@MainActor` keeps all access on the UI thread.
@MainActor
@Observable
final class AppState {
    private(set) var spaces: [Space] = []
    private(set) var selectedSpaceID: UUID?

    /// nil = palette hidden.
    var palette: PaletteMode?
    /// Non-nil while the "New Space" / "Edit Space" sheet is shown.
    var spaceEditor: SpaceEditorRequest?
    /// Non-nil while a small "enter a name" sheet is shown (folders).
    var nameRequest: NameRequest?
    /// Problems found while loading files from disk, shown once in the sidebar.
    var loadErrors: [String] = []

    let web: WebViewRegistry
    let terminals: TerminalRegistry
    let artifacts: ArtifactHosts
    let favicons: FaviconStore
    /// Approval policy checks and confirmation sheets for agent actions.
    let approvals = AgentApprovals()
    /// Installed plugins: approvals, background processes, Settings → Plugins.
    let plugins: PluginManager
    /// Preferences from the Settings window (`~/Singularity/settings.json`). Change via `updateSettings`.
    private(set) var settings = AppSettings()
    @ObservationIgnored private var settingsDirty = false
    /// Tabs an agent is working on right now (count, since calls can overlap). Drives the badges.
    private(set) var agentBusyTabs: [UUID: Int] = [:]
    /// Recent agent log entries per Space (oldest first), loaded from agent-log.jsonl on demand.
    private(set) var agentLogs: [UUID: [AgentLogEntry]] = [:]
    /// The MCP server agents connect to (set at the end of init, since it needs `self`).
    @ObservationIgnored private(set) var mcp: MCPHub?

    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let store: SpaceStore
    @ObservationIgnored private var historyCache: [UUID: [HistoryEntry]] = [:]
    /// Per Space: the terminal tab that was selected most recently (target of `singularity.prompt`).
    @ObservationIgnored private var activeTerminalBySpace: [UUID: UUID] = [:]
    /// Per Space: the tab selected before the current one (⌘\ splits the current tab with it).
    @ObservationIgnored private var previousTabBySpace: [UUID: UUID] = [:]
    /// Per Space: artifact pages we already know about, so only genuinely new files open a tab.
    @ObservationIgnored private var knownArtifactPages: [UUID: Set<String>] = [:]

    // Saving: changes mark things dirty; a short debounce then writes them all at once.
    @ObservationIgnored private var dirtySpaceIDs: Set<UUID> = []
    @ObservationIgnored private var stateFileDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(paths: Paths) {
        self.paths = paths
        self.store = SpaceStore(paths: paths)
        self.web = WebViewRegistry()
        self.terminals = TerminalRegistry()
        self.artifacts = ArtifactHosts()
        self.favicons = FaviconStore(paths: paths)
        // Bun and the plugin host ship inside the app bundle (see scripts/build-app.sh).
        let bundle = Bundle.main.bundleURL
        self.plugins = PluginManager(paths: paths, runtime: bundle.appending(path: "Contents/Helpers/bun"),
                                     host: bundle.appending(path: "Contents/Resources/plugin-host/host.ts"))

        settings = store.loadSettings()
        let loaded = store.load()
        spaces = loaded.spaces
        loadErrors = loaded.errors
        selectedSpaceID = loaded.state.selectedSpaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil }
            ?? spaces.first?.id

        if spaces.isEmpty {
            createSpace(name: "Personal", colorHex: SpaceColors.presets[0], workingDirectory: "~")
        }

        web.state = self
        terminals.state = self
        artifacts.state = self

        approvals.timeoutSeconds = { [weak self] in self?.settings.agentApprovalTimeoutSeconds ?? 120 }

        let mcp = MCPHub(state: self)
        mcp.start(socketPath: paths.mcpSocket.path)
        self.mcp = mcp

        plugins.start()

        // When the app quits: write pending changes, hang up all shells, kill plugin processes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSaves()
                self?.terminals.tearDownAll()
                self?.mcp?.stop()
                self?.plugins.terminateAll()
            }
        }
    }

    // MARK: - Reading

    var selectedSpace: Space? {
        selectedSpaceID.flatMap { space($0) }
    }

    var selectedTab: BrowserTab? {
        selectedSpace?.selectedTab
    }

    func space(_ id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    /// History of a Space, newest first. Loaded from disk on first use.
    func history(for spaceID: UUID) -> [HistoryEntry] {
        if let cached = historyCache[spaceID] { return cached }
        guard let space = space(spaceID) else { return [] }
        let entries = HistoryStore(file: paths.historyFile(space.slug)).load()
        historyCache[spaceID] = entries
        return entries
    }

    // MARK: - Spaces

    @discardableResult
    func createSpace(name: String, colorHex: String, workingDirectory: String, agentsEnabled: Bool = false,
                     agentPolicy: AgentPolicy = .ask) -> Space {
        let slug = Slug.unique(from: name, existing: Set(spaces.map(\.slug)) .union(slugsOnDisk()))
        let space = Space(name: name, slug: slug, colorHex: colorHex, workingDirectory: workingDirectory,
                          agentsEnabled: agentsEnabled, agentPolicy: agentPolicy)
        spaces.append(space)
        markDirty(space.id)
        stateFileDirty = true
        selectSpace(space.id)
        if agentsEnabled { mcp?.toolsChanged() }
        return space
    }

    func updateSpace(_ id: UUID, name: String, colorHex: String, workingDirectory: String, agentsEnabled: Bool,
                     agentPolicy: AgentPolicy) {
        let wasEnabled = space(id)?.agentsEnabled
        mutateSpace(id) {
            $0.name = name
            $0.colorHex = colorHex
            $0.workingDirectory = workingDirectory
            $0.agentsEnabled = agentsEnabled
            $0.agentPolicy = agentPolicy
        }
        // Tool descriptions mention the Space's name, so a rename also counts as a change.
        if wasEnabled != agentsEnabled || agentsEnabled { mcp?.toolsChanged() }
    }

    /// ⌃⇥ / ⌃⇧⇥: the next or previous tab in sidebar order, wrapping around. A split counts once
    /// (its whole row), so stepping through the sidebar feels like stepping through rows.
    func selectAdjacentTab(_ step: Int) {
        guard let space = selectedSpace else { return }
        let rows = [SidebarSection.pinned] + space.folders.map { .folder($0.id) } + [.open]
        let items = rows.flatMap { space.sidebarItems(in: $0) }
        guard !items.isEmpty else { return }
        let current = space.selectedTabID.flatMap { id in items.firstIndex { $0.tabIDs.contains(id) } }
        let next = current.map { ($0 + step + items.count) % items.count } ?? 0
        if let tabID = items[next].tabIDs.first { selectTab(tabID) }
    }

    func selectSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        stateFileDirty = true
        scheduleSave()
        loadSelectedTab()
    }

    /// Deletes a Space: closes its web views, removes its website data (cookies etc.)
    /// and moves its folder to the Trash. The last remaining Space cannot be deleted.
    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let space = space(id) else { return }
        web.removeControllers(for: space.tabs.map(\.id))
        terminals.removeSessions(for: space.tabs.map(\.id))
        artifacts.stop(id)
        plugins.spaceRemoved(id)
        knownArtifactPages[id] = nil
        activeTerminalBySpace[id] = nil
        spaces.removeAll { $0.id == id }
        dirtySpaceIDs.remove(id) // don't recreate the folder with a pending save
        historyCache[id] = nil
        if selectedSpaceID == id {
            selectedSpaceID = spaces.first?.id
            loadSelectedTab()
        }
        stateFileDirty = true
        scheduleSave()
        if space.agentsEnabled { mcp?.toolsChanged() }

        do {
            try store.trashSpaceFolder(slug: space.slug)
        } catch {
            NSLog("Singularity: could not trash folder for \(space.slug): \(error)")
        }
        // WebKit refuses to delete a data store that is still in use, so wait a moment
        // for the web views we just closed to be torn down.
        Task {
            try? await Task.sleep(for: .seconds(1))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                NSLog("Singularity: could not remove website data for \(space.slug): \(error)")
            }
        }
    }

    // MARK: - Tabs

    func selectTab(_ tabID: UUID) {
        guard let spaceID = selectedSpaceID else { return }
        if let current = space(spaceID)?.selectedTabID, current != tabID {
            previousTabBySpace[spaceID] = current
        }
        mutateSpace(spaceID) { $0.selectedTabID = tabID }
        loadSelectedTab()
    }

    /// Opens a URL in a new tab and selects it (in the current Space unless one is given).
    func openInNewTab(_ url: URL, spaceID: UUID? = nil) {
        guard let spaceID = spaceID ?? selectedSpaceID else { return }
        let tab = BrowserTab.web(url)
        mutateSpace(spaceID) {
            $0.append(tab)
            $0.selectedTabID = tab.id
        }
        loadSelectedTab()
    }

    /// Opens a URL in a background tab right after `sourceTabID` (Cmd+click on a link).
    func openInBackgroundTab(_ url: URL, spaceID: UUID, after sourceTabID: UUID) {
        mutateSpace(spaceID) { $0.insert(BrowserTab.web(url), after: sourceTabID) }
    }

    /// Loads a URL in the selected web tab, or in a new tab if no web tab is selected.
    func navigateSelectedTab(to url: URL) {
        guard let space = selectedSpace, let tab = space.selectedTab, case .web = tab.kind else {
            openInNewTab(url)
            return
        }
        web.controller(for: tab, in: space).load(url)
    }

    /// Opens a terminal tab in the current Space, starting in the Space's working directory.
    func openTerminal() {
        guard let space = selectedSpace else { return }
        let tab = BrowserTab.terminal(workingDirectory: space.workingDirectory)
        mutateSpace(space.id) {
            $0.append(tab)
            $0.selectedTabID = tab.id
        }
        loadSelectedTab()
    }

    /// Closes a tab. When a terminal is running a program (an agent, an editor, a server),
    /// asks first, so Cmd+W can't kill it by accident.
    func closeTab(_ tabID: UUID, in spaceID: UUID? = nil, confirmIfBusy: Bool = true) {
        guard let spaceID = spaceID ?? selectedSpaceID else { return }
        terminalLog.notice("closeTab \(tabID, privacy: .public): confirmIfBusy=\(confirmIfBusy) program=\(self.terminals.existingSession(tabID)?.foregroundProgram ?? "<none>", privacy: .public)")
        if confirmIfBusy, let program = terminals.existingSession(tabID)?.foregroundProgram {
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText = "“\(program)” is still running in it and will be stopped."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        web.removeControllers(for: [tabID])
        terminals.removeSessions(for: [tabID])
        mutateSpace(spaceID) { $0.closeTab(tabID) }
        if spaceID == selectedSpaceID { loadSelectedTab() }
    }

    func closeSelectedTab() {
        if let id = selectedTab?.id { closeTab(id) }
    }

    func togglePin(_ tabID: UUID) {
        guard let spaceID = selectedSpaceID, let tab = space(spaceID)?.tab(tabID) else { return }
        mutateSpace(spaceID) { $0.moveTab(tabID, to: tab.isPinned && tab.folderID == nil ? .open : .pinned) }
    }

    func moveTab(_ tabID: UUID, to section: SidebarSection) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.moveTab(tabID, to: section) }
    }

    /// Reorders sidebar rows (a split's row moves all its tabs).
    func moveSidebarItems(in section: SidebarSection, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.moveSidebarItems(in: section, fromOffsets: offsets, toOffset: destination) }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String) -> Folder? {
        guard let spaceID = selectedSpaceID else { return nil }
        let folder = Folder(name: name)
        mutateSpace(spaceID) { $0.folders.append(folder) }
        return folder
    }

    func renameFolder(_ folderID: UUID, to name: String) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { space in
            if let index = space.folders.firstIndex(where: { $0.id == folderID }) {
                space.folders[index].name = name
            }
        }
    }

    func setFolderExpanded(_ folderID: UUID, _ expanded: Bool) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { space in
            if let index = space.folders.firstIndex(where: { $0.id == folderID }) {
                space.folders[index].isExpanded = expanded
            }
        }
    }

    func deleteFolder(_ folderID: UUID) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.deleteFolder(folderID) }
    }

    /// Asks for a folder name, creates the folder, and optionally moves a tab into it.
    func promptNewFolder(moving tabID: UUID? = nil) {
        nameRequest = NameRequest(title: "New Folder", initialValue: "") { [weak self] name in
            guard let self, let folder = self.createFolder(named: name) else { return }
            if let tabID { self.moveTab(tabID, to: .folder(folder.id)) }
        }
    }

    // MARK: - Palette

    func showPalette(_ mode: PaletteMode) {
        palette = mode
    }

    // MARK: - Callbacks from web views

    /// Called by WebTabController when the page title or URL changes.
    func webTabDidChange(tabID: UUID, spaceID: UUID, title: String?, url: URL?) {
        let host = artifacts.host(spaceID)
        mutateSpace(spaceID) { space in
            space.updateTab(tabID) { tab in
                if let title { tab.title = title }
                guard let url else { return }
                if tab.isArtifact {
                    // Stays an artifact tab; follow links between artifact pages. If the page
                    // navigates elsewhere, the tab still reopens its artifact next time.
                    if let path = host?.artifactPath(for: url) { tab.kind = .artifact(path: path) }
                } else {
                    tab.kind = .web(url: url)
                }
            }
        }
    }

    /// Called by TerminalSession about once a second; only writes when something changed.
    func terminalDidChange(tabID: UUID, spaceID: UUID, title: String, workingDirectory: String?) {
        guard let tab = space(spaceID)?.tab(tabID) else { return }
        let directory = workingDirectory ?? tab.workingDirectory ?? "~"
        guard tab.title != title || tab.workingDirectory != directory else { return }
        mutateSpace(spaceID) { space in
            space.updateTab(tabID) { tab in
                tab.title = title
                tab.kind = .terminal(workingDirectory: directory)
            }
        }
    }

    /// Starts a new shell in a terminal tab whose previous shell has exited.
    func restartTerminal(_ tabID: UUID, in spaceID: UUID) {
        guard let space = space(spaceID), let tab = space.tab(tabID) else { return }
        terminals.restart(tab, in: space)
    }

    /// Asked by the app delegate before quitting. Returns false if the user cancels.
    func confirmQuit() -> Bool {
        let busy = terminals.busySessions.compactMap(\.foregroundProgram)
        terminalLog.notice("confirmQuit: busy programs = \(busy, privacy: .public)")
        guard !busy.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Singularity?"
        alert.informativeText = "These programs are still running in terminal tabs and will be stopped: "
            + busy.sorted().joined(separator: ", ") + "."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Called when a page finishes loading: records it in the Space's history.
    func recordVisit(spaceID: UUID, url: URL, title: String) {
        guard let space = space(spaceID), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        // Artifact URLs contain this launch's port, so they'd be dead links in history.
        if artifacts.host(spaceID)?.artifactPath(for: url) != nil { return }
        let entry = HistoryEntry(url: url, title: title)
        do {
            try HistoryStore(file: paths.historyFile(space.slug)).append(entry)
        } catch {
            NSLog("Singularity: could not write history: \(error)")
        }
        if var cached = historyCache[spaceID] {
            cached.removeAll { $0.url == url }
            cached.insert(entry, at: 0)
            historyCache[spaceID] = cached
        }
    }

    /// A page called `window.open` or followed a `target=_blank` link. WebKit requires us to
    /// return a new web view built from the configuration it hands us (that keeps the
    /// `window.opener` link working, which OAuth pop-ups rely on). We show it as a new tab.
    func openPopup(from sourceTabID: UUID, spaceID: UUID, configuration: WKWebViewConfiguration, url: URL?) -> WKWebView {
        let tab = BrowserTab.web(url ?? URL(string: "about:blank")!)
        mutateSpace(spaceID) {
            $0.insert(tab, after: sourceTabID)
            $0.selectedTabID = tab.id
        }
        let controller = web.adoptPopup(tabID: tab.id, spaceID: spaceID, configuration: configuration)
        return controller.webView
    }

    // MARK: - Internals

    /// Makes sure the selected tab of the selected Space is live (a web view or a running shell),
    /// and that the Space's artifact server runs. All of these start lazily, so restored tabs and
    /// Spaces cost nothing until first shown.
    func loadSelectedTab() {
        guard let space = selectedSpace else { return }
        if artifacts.host(space.id) == nil {
            Task { _ = await ensureArtifactHost(space) }
        }
        // In a split, every pane is on screen, so every pane's tab must be live.
        for tabID in space.visibleTabIDs {
            if let tab = space.tab(tabID) { loadTab(tab, in: space) }
        }
        if let selected = space.selectedTab, selected.isTerminal {
            activeTerminalBySpace[space.id] = selected.id
        }
    }

    private func loadTab(_ tab: BrowserTab, in space: Space) {
        switch tab.kind {
        case .web:
            _ = web.controller(for: tab, in: space)
        case .terminal:
            _ = terminals.session(for: tab, in: space)
        case .artifact(let path):
            guard web.existingController(tab.id) == nil else { return }
            // The page can only load once the Space's server runs.
            Task {
                guard let host = await ensureArtifactHost(space),
                      web.existingController(tab.id) == nil,
                      let request = host.request(for: path)
                else { return }
                _ = web.artifactController(for: tab, in: space, host: host, request: request)
            }
        }
    }

    // MARK: - Split view

    /// Shows `tabID` next to `target` (and focuses it). Beeps if the split is full.
    func splitTab(_ tabID: UUID, beside target: UUID, edge: SplitEdge) {
        guard let spaceID = selectedSpaceID else { return }
        var didSplit = false
        mutateSpace(spaceID) { space in
            didSplit = space.split(tabID, beside: target, edge: edge)
            if didSplit { space.selectedTabID = tabID }
        }
        guard didSplit else {
            NSSound.beep()
            return
        }
        previousTabBySpace[spaceID] = target
        loadSelectedTab()
    }

    /// Takes a tab out of its split; the tab stays open in the sidebar. If it was the focused
    /// pane, focus moves to another pane so the rest of the split stays on screen.
    func removeFromSplit(_ tabID: UUID) {
        guard let space = selectedSpace, let group = space.splitGroup(containing: tabID) else { return }
        let neighbour = group.root.tabIDs.first { $0 != tabID }
        mutateSpace(space.id) { space in
            space.removeFromSplit(tabID)
            if space.selectedTabID == tabID, let neighbour { space.selectedTabID = neighbour }
        }
        loadSelectedTab()
    }

    /// A tab from the sidebar was dropped on a pane (or on the single visible tab).
    func handleTabDrop(_ dropped: UUID, onto paneTab: UUID, zone: PaneDropZone) {
        guard dropped != paneTab, let space = selectedSpace, space.tab(dropped) != nil else { return }
        switch zone {
        case .edge(let edge):
            splitTab(dropped, beside: paneTab, edge: edge)
        case .center:
            if space.splitGroup(containing: paneTab) != nil {
                mutateSpace(space.id) { space in
                    space.replaceInSplit(paneTab, with: dropped)
                    space.selectedTabID = dropped
                }
                loadSelectedTab()
            } else {
                selectTab(dropped)
            }
        }
    }

    /// A click landed in a pane: make it the focused (selected) tab.
    func focusPane(_ tabID: UUID) {
        guard selectedSpace?.selectedTabID != tabID else { return }
        selectTab(tabID)
    }

    /// ⌥⌘ + arrow: focus the neighbouring pane and give it the keyboard.
    func moveFocus(_ direction: PaneDirection) {
        guard let space = selectedSpace, let current = space.selectedTabID,
              let next = space.splitGroup(containing: current)?.root.neighbour(of: current, direction) else {
            NSSound.beep()
            return
        }
        selectTab(next)
        let view: NSView? = web.existingController(next)?.webView ?? terminals.existingSession(next)?.view
        view?.window?.makeFirstResponder(view)
    }

    /// ⌘\: split the current tab with the previously selected one; without one, ask which tab.
    func splitWithPrevious() {
        guard let space = selectedSpace, let current = space.selectedTabID else { return }
        let sameGroup = space.splitGroup(containing: current)?.root.tabIDs ?? [current]
        if let previous = previousTabBySpace[space.id], space.tab(previous) != nil, !sameGroup.contains(previous) {
            splitTab(previous, beside: current, edge: .right)
        } else {
            showSplitPalette(.right, beside: current)
        }
    }

    func showSplitPalette(_ edge: SplitEdge, beside tabID: UUID) {
        palette = .splitWith(edge: edge, beside: tabID)
    }

    /// Opens a URL as a new tab and shows it in a split next to `target`.
    func openInSplit(_ url: URL, edge: SplitEdge, beside target: UUID) {
        guard let spaceID = selectedSpaceID else { return }
        let tab = BrowserTab.web(url)
        mutateSpace(spaceID) { $0.append(tab) }
        splitTab(tab.id, beside: target, edge: edge)
    }

    /// Opens a new terminal and shows it in a split next to `target`.
    func openTerminalInSplit(edge: SplitEdge, beside target: UUID) {
        guard let space = selectedSpace else { return }
        let tab = BrowserTab.terminal(workingDirectory: space.workingDirectory)
        mutateSpace(space.id) { $0.append(tab) }
        splitTab(tab.id, beside: target, edge: edge)
    }

    func setSplitFractions(groupID: UUID, path: [Int], fractions: [Double]) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.setSplitFractions(groupID: groupID, path: path, fractions: fractions) }
    }

    // MARK: - For agents (MCP)

    /// Opens a URL in a new tab of a Space *without* selecting it, so the user's view doesn't
    /// jump around while an agent works. The web view loads in the background.
    func agentOpenTab(url: URL, spaceID: UUID) -> (BrowserTab, WebTabController)? {
        var tab = BrowserTab.web(url)
        tab.openedByAgent = true
        mutateSpace(spaceID) { $0.append(tab) }
        guard let space = space(spaceID) else { return nil }
        return (tab, web.controller(for: tab, in: space))
    }

    func beginAgentWork(on tabID: UUID) {
        agentBusyTabs[tabID, default: 0] += 1
    }

    func endAgentWork(on tabID: UUID) {
        guard let count = agentBusyTabs[tabID] else { return }
        agentBusyTabs[tabID] = count > 1 ? count - 1 : nil
    }

    func isAgentBusy(_ tabID: UUID) -> Bool {
        agentBusyTabs[tabID] != nil
    }

    /// Appends to `<space>/agent-log.jsonl` and to the in-memory list the sidebar shows.
    func appendAgentLog(_ entry: AgentLogEntry, spaceID: UUID) {
        guard let space = space(spaceID) else { return }
        do {
            try AgentLogStore(file: paths.agentLogFile(space.slug)).append(entry)
        } catch {
            NSLog("Singularity: could not write the agent log: \(error)")
        }
        if agentLogs[spaceID] != nil {
            agentLogs[spaceID]!.append(entry)
            if agentLogs[spaceID]!.count > 200 { agentLogs[spaceID]!.removeFirst() }
        }
    }

    /// Loads a Space's recent log entries (call from onAppear, not while rendering).
    func loadAgentLog(spaceID: UUID) {
        guard agentLogs[spaceID] == nil, let space = space(spaceID) else { return }
        agentLogs[spaceID] = AgentLogStore(file: paths.agentLogFile(space.slug)).loadRecent()
    }

    func revealAgentLog() {
        guard let space = selectedSpace else { return }
        let file = paths.agentLogFile(space.slug)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(paths.spaceDirectory(space.slug))
        }
    }

    /// A live web view for a web or artifact tab, creating (and loading) it if the tab hasn't
    /// been shown since launch. Nil for terminal tabs.
    func liveWebController(tabID: UUID, spaceID: UUID) async -> WebTabController? {
        if let existing = web.existingController(tabID) { return existing }
        guard let space = space(spaceID), let tab = space.tab(tabID) else { return nil }
        switch tab.kind {
        case .web:
            return web.controller(for: tab, in: space)
        case .artifact(let path):
            guard let host = await ensureArtifactHost(space), let request = host.request(for: path) else { return nil }
            return web.existingController(tabID) ?? web.artifactController(for: tab, in: space, host: host, request: request)
        case .terminal:
            return nil
        }
    }

    private func ensureArtifactHost(_ space: Space) async -> ArtifactHost? {
        let host = await artifacts.ensureStarted(space, root: paths.artifactsDirectory(space.slug))
        if let host, knownArtifactPages[space.id] == nil {
            knownArtifactPages[space.id] = Set(host.pages)
        }
        return host
    }

    // MARK: - Artifacts

    /// Called by a Space's folder watcher. New HTML pages get a tab (without taking focus);
    /// changed files reload the artifact tabs that show them.
    func artifactsDidChange(spaceID: UUID, changes: [ArtifactWatcher.Change]) {
        guard let space = space(spaceID) else { return }
        var known = knownArtifactPages[spaceID] ?? []
        var reloadAll = false
        var pagesToReload = Set<String>()

        for change in changes {
            let path = change.relativePath
            let isPage = ArtifactFiles.isArtifactPage(path)
            switch change.kind {
            case .removed:
                known.remove(path)
            case .changed where isPage:
                pagesToReload.insert(path)
                if known.insert(path).inserted, !space.tabs.contains(where: { $0.artifactPath == path }) {
                    mutateSpace(spaceID) { $0.append(.artifact(path: path)) }
                }
            case .changed:
                reloadAll = true // a script, stylesheet or image changed; any page may use it
            }
        }
        knownArtifactPages[spaceID] = known

        for tab in space.tabs {
            guard let path = tab.artifactPath, reloadAll || pagesToReload.contains(path) else { continue }
            web.existingController(tab.id)?.reload()
        }
    }

    /// Opens an artifact page (or selects its tab if one is already open).
    func openArtifact(_ path: String) {
        guard let space = selectedSpace else { return }
        if let existing = space.tabs.first(where: { $0.artifactPath == path }) {
            selectTab(existing.id)
            return
        }
        let tab = BrowserTab.artifact(path: path)
        mutateSpace(space.id) {
            $0.append(tab)
            $0.selectedTabID = tab.id
        }
        loadSelectedTab()
    }

    func revealArtifactsFolder() {
        guard let space = selectedSpace else { return }
        let folder = paths.artifactsDirectory(space.slug)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// `singularity.prompt(text)` from an artifact page: after the user confirms, paste the text
    /// into the Space's active terminal and press Return. (Phase 5 replaces "always ask" with the
    /// Space's approval policy.)
    func sendPromptFromArtifact(_ text: String, spaceID: UUID) async -> PromptResult {
        guard let space = space(spaceID), let (tab, session) = activeTerminal(in: space) else { return .noTerminal }
        let started = Date()

        // Same policy as agents: read-only refuses, allow-all sends, ask always shows a sheet.
        let outcome = await approvals.check(
            AgentActionContext(kind: .artifactPrompt, pageOrigin: artifacts.host(spaceID)?.origin.flatMap(AgentApprovalRules.origin(of:))),
            space: space,
            request: AgentApprovals.Request(
                actor: "An artifact page", action: "send text to a terminal",
                detail: "It will be pasted into “\(tab.displayTitle)” and Return will be pressed.",
                url: nil, spaceName: space.name, tabTitle: nil, text: text))

        func log(_ ok: Bool, _ result: String) {
            appendAgentLog(AgentLogEntry(client: "artifact page", tool: "artifact.prompt", tabID: tab.id,
                                         args: ["text": AgentLogStore.clip(text)], decision: outcome.logValue, ok: ok,
                                         result: result, milliseconds: Int(Date().timeIntervalSince(started) * 1000)),
                           spaceID: spaceID)
        }

        if case .refused(let reason) = outcome {
            log(false, reason)
            return .refused(reason)
        }
        guard outcome.isAllowed else {
            log(false, outcome.refusal ?? "declined")
            return .declined
        }
        guard session.isRunning else {
            log(false, "no running terminal")
            return .noTerminal
        }
        // A shell started just now for this prompt may still be reading ~/.zshrc.
        await session.waitUntilReady()

        // Bracketed paste keeps multi-line text together as one message in programs such as
        // Claude Code; the short pause lets the program finish handling the paste before Return.
        session.view.pasteText(text)
        try? await Task.sleep(for: .milliseconds(150))
        session.view.send(txt: "\r")
        log(true, "sent to \(tab.displayTitle)")
        return .sent
    }

    /// The terminal that `singularity.prompt` types into: the most recently selected terminal tab
    /// with a running shell, else any terminal tab with a running shell. If the Space's terminal
    /// tabs haven't been opened yet since launch (shells start lazily), starts the shell of the
    /// preferred one. Nil only when the Space has no terminal tab at all.
    private func activeTerminal(in space: Space) -> (BrowserTab, TerminalSession)? {
        var candidates = space.tabsInSidebarOrder.filter(\.isTerminal)
        if let preferred = activeTerminalBySpace[space.id], let index = candidates.firstIndex(where: { $0.id == preferred }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        for tab in candidates {
            if let session = terminals.existingSession(tab.id), session.isRunning { return (tab, session) }
        }
        guard let tab = candidates.first(where: { terminals.existingSession($0.id) == nil }) else { return nil }
        activeTerminalBySpace[space.id] = tab.id
        return (tab, terminals.session(for: tab, in: space))
    }

    private func mutateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[index])
        markDirty(id)
    }

    private func markDirty(_ id: UUID) {
        dirtySpaceIDs.insert(id)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushSaves()
        }
    }

    func flushSaves() {
        saveTask?.cancel()
        for id in dirtySpaceIDs {
            guard let space = space(id) else { continue }
            do {
                try store.save(space)
            } catch {
                NSLog("Singularity: could not save space \(space.slug): \(error)")
            }
        }
        dirtySpaceIDs.removeAll()
        if stateFileDirty {
            do {
                try store.save(AppStateFile(spaceOrder: spaces.map(\.id), selectedSpaceID: selectedSpaceID))
            } catch {
                NSLog("Singularity: could not save state.json: \(error)")
            }
            stateFileDirty = false
        }
        if settingsDirty {
            do {
                try store.save(settings)
            } catch {
                NSLog("Singularity: could not save settings.json: \(error)")
            }
            settingsDirty = false
        }
    }

    // MARK: - Settings

    /// Changes preferences, saves them (debounced) and applies what affects open tabs.
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let before = settings
        change(&settings)
        guard settings != before else { return }
        settingsDirty = true
        scheduleSave()
        if settings.terminalFontName != before.terminalFontName || settings.terminalFontSize != before.terminalFontSize {
            terminals.applyFont(terminalFont)
        }
    }

    /// The terminal font from Settings (falls back to the system's monospaced font).
    var terminalFont: NSFont {
        let size = CGFloat(settings.terminalFontSize)
        if let family = settings.terminalFontName,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Settings → Data: empties a Space's browsing history (the palette's suggestions).
    func clearHistory(spaceID: UUID) {
        guard let space = space(spaceID) else { return }
        try? FileManager.default.removeItem(at: paths.historyFile(space.slug))
        historyCache[spaceID] = []
    }

    /// Settings → Data: deletes a Space's cookies, logins, local storage and cache (WebKit store).
    func clearSiteData(spaceID: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: spaceID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Settings → Data: empties a Space's agent log.
    func clearAgentLog(spaceID: UUID) {
        guard let space = space(spaceID) else { return }
        try? FileManager.default.removeItem(at: paths.agentLogFile(space.slug))
        if agentLogs[spaceID] != nil { agentLogs[spaceID] = [] }
    }

    /// Folder names already on disk (including ones that failed to load), so a new
    /// Space never reuses an existing folder.
    private func slugsOnDisk() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.spacesDirectory.path)) ?? []
        return Set(names)
    }
}

// MARK: - Small UI request types

enum PaletteMode: Equatable {
    /// Cmd+T / Cmd+K: results open in a new tab.
    case newTab
    /// Clicking the address row: URLs load in the selected tab.
    case navigateCurrent
    /// "Split with…": the chosen tab (or a new one) is shown next to `beside`.
    case splitWith(edge: SplitEdge, beside: UUID)
}

struct SpaceEditorRequest: Identifiable {
    let id = UUID()
    /// nil = creating a new Space.
    let spaceID: UUID?
}

struct NameRequest: Identifiable {
    let id = UUID()
    let title: String
    let initialValue: String
    let onCommit: (String) -> Void
}
