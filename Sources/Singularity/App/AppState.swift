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
    enum SettingsTab: Hashable { case general, terminal, agents, plugins, data }

    /// Opens Settings → Plugins (the palette's "Plugins: N need your review").
    func showPluginSettings() {
        settingsTab = .plugins
        openSettingsWindow?()
    }

    private(set) var spaces: [Space] = []
    private(set) var selectedSpaceID: UUID?

    /// nil = palette hidden.
    var palette: PaletteMode?
    /// Non-nil while the "New Space" / "Edit Space" sheet is shown.
    var spaceEditor: SpaceEditorRequest?
    /// Non-nil while a small "enter a name" sheet is shown (folders).
    var nameRequest: NameRequest?
    /// File → Import from Arc… is showing.
    var isImportingFromArc = false
    /// Problems found while loading files from disk, shown once in the sidebar.
    var loadErrors: [String] = []
    /// Non-nil while the welcome flow covers the window.
    private(set) var onboarding: OnboardingFlow?
    /// The welcome flow covers the window (sidebar and tab hidden). Menu commands that act on the
    /// hidden tab or page are off meanwhile, and ⌘W closes the flow (`closeTabCommand`).
    var welcomeCoversWindow: Bool { onboarding != nil }
    /// The plugin whose approval sheet step 4 of the welcome flow shows (its id), nil when none.
    /// Kept here rather than in the step's view so that ⌘W can see the sheet (`welcomeSheetIsOpen`).
    /// Set it with `reviewWelcomePlugin` (only on step 4); the sheet's binding clears it.
    var welcomePluginReview: String?
    /// A sheet is open over the welcome flow: the Arc import, or a plugin's approval from step 4.
    var welcomeSheetIsOpen: Bool { welcomeCoversWindow && (isImportingFromArc || welcomePluginReview != nil) }
    /// The Space made at a brand-new install's first launch, until the flow ends or it gets a tab.
    /// Only this Space may still take a new slug (`applyWelcomeSpace`).
    private(set) var firstRunPlaceholderID: UUID?
    /// Step 2's Continue was applied to the placeholder: the user named it, so it is theirs now and
    /// an Arc import keeps it. (The id stays set, so Back and Continue again can still re-slug it.)
    @ObservationIgnored private var placeholderCustomised = false
    /// The Settings window's selected tab (so a palette command can open it on Plugins).
    var settingsTab: SettingsTab = .general
    /// Opens the Settings window. SwiftUI only hands this out as a view environment value
    /// (`\.openSettings`, macOS 14+), so `MainView` stores it here on appear.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    let web: WebViewRegistry
    let terminals: TerminalRegistry
    let artifacts: ArtifactHosts
    let favicons: FaviconStore
    /// Approval policy checks and confirmation sheets for agent actions.
    let approvals = AgentApprovals()
    /// Downloads of this run, for the sidebar's Downloads list.
    let downloads = DownloadCenter()
    /// Installed plugins: approvals, background processes, Settings → Plugins.
    let plugins: PluginManager
    /// Plugins' page scripts in each Space's web views.
    @ObservationIgnored let pluginScripts: PluginScripts
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
    /// Artifact tabs whose file is gone (deleted, renamed, moved). The sidebar marks them; the tab
    /// itself shows the server's "file is missing" page and comes back when the file does.
    private(set) var missingArtifactTabs: Set<UUID> = []
    /// Per Space: artifact pages we already know about, so only genuinely new files open a tab.
    @ObservationIgnored private var knownArtifactPages: [UUID: Set<String>] = [:]

    // Saving: changes mark things dirty; a short debounce then writes them all at once.
    @ObservationIgnored private var dirtySpaceIDs: Set<UUID> = []
    @ObservationIgnored private var stateFileDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// `discardFolder`: what `deleteSpace` does with the Space's folder. The app keeps the default
    /// (the Trash); tests remove it inside their temporary folder instead (`TestAppState`).
    init(paths: Paths, discardFolder: @escaping SpaceStore.DiscardFolder = SpaceStore.moveToTrash) {
        self.paths = paths
        self.store = SpaceStore(paths: paths, discardFolder: discardFolder)
        self.web = WebViewRegistry()
        self.terminals = TerminalRegistry()
        self.artifacts = ArtifactHosts()
        self.favicons = FaviconStore(paths: paths)
        // Bun and the plugin host ship inside the app bundle (see scripts/build-app.sh).
        let bundle = Bundle.main.bundleURL
        self.plugins = PluginManager(paths: paths, runtime: bundle.appending(path: "Contents/Helpers/bun"),
                                     host: bundle.appending(path: "Contents/Resources/plugin-host/host.ts"))
        self.pluginScripts = PluginScripts(manager: plugins, runtime: bundle.appending(path: "Contents/Helpers/bun"),
                                           hostFolder: bundle.appending(path: "Contents/Resources/plugin-host",
                                                                        directoryHint: .isDirectory))

        artifacts.scripts = ArtifactScriptService(
            runtime: bundle.appending(path: "Contents/Helpers/bun"),
            hostFolder: bundle.appending(path: "Contents/Resources/plugin-host", directoryHint: .isDirectory))

        settings = store.loadSettings()
        let loaded = store.load()
        spaces = loaded.spaces
        loadErrors = loaded.errors
        selectedSpaceID = loaded.state.selectedSpaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil }
            ?? spaces.first?.id

        if spaces.isEmpty {
            let first = createSpace(name: "Personal", colorHex: SpaceColors.presets[0], workingDirectory: "~")
            // No flag is stored: after this launch a Space exists on disk, so the next one isn't brand-new.
            if FirstRun.isBrandNew(loadedSpaceCount: loaded.spaces.count, loadErrorCount: loaded.errors.count) {
                firstRunPlaceholderID = first.id
                onboarding = OnboardingFlow()
            }
        }

        web.state = self
        web.pluginScripts = pluginScripts
        pluginScripts.tabID = { [weak web] webView in web?.tabID(for: webView) }
        plugins.onChange = { [weak pluginScripts] in pluginScripts?.scheduleRefresh() }
        // Site settings: the console/network collector for switched-on sites, and plugins switched off per site.
        let captureBridge = CaptureBridge(state: self)
        pluginScripts.onAttach = { controller in captureBridge.install(in: controller) }
        pluginScripts.spaceScripts = { [weak self] spaceID in
            let sites = self?.space(spaceID).map(InspectionRules.capturedSites) ?? []
            return (sites.joined(separator: " "), PageCaptureScript.scripts(sites: sites))
        }
        pluginScripts.offSites = { [weak self] spaceID, pluginID in
            self?.space(spaceID)?.sitesWherePluginIsOff(pluginID) ?? []
        }
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
                self?.artifacts.stopAll()
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

    /// Adds the chosen Arc Spaces as new Spaces (agents off, nothing loaded until a tab is shown)
    /// and selects the first of them.
    func importArcSpaces(_ arcSpaces: [ArcImport.ArcSpace], options: ArcImport.Options) {
        var taken = Set(spaces.map(\.slug)).union(slugsOnDisk())
        var first: UUID?
        for arc in arcSpaces {
            let slug = Slug.unique(from: arc.name, existing: taken)
            taken.insert(slug)
            let used = Set(spaces.map(\.colorHex))
            let fallback = SpaceColors.presets.first { !used.contains($0) } ?? SpaceColors.presets[0]
            let space = ArcImport.makeSpace(from: arc, slug: slug, fallbackColorHex: fallback, options: options)
            spaces.append(space)
            markDirty(space.id)
            first = first ?? space.id
        }
        stateFileDirty = true
        if let first { selectSpace(first) } else { scheduleSave() }

        // In the welcome flow the imported Spaces replace the untouched one made at launch, and
        // the flow goes on without its Space step. A placeholder the user already named in step 2
        // (then went Back, or used the File menu) is theirs: it stays.
        guard onboarding != nil, !arcSpaces.isEmpty else { return }
        if let placeholder = firstRunPlaceholderID.flatMap(space), placeholder.tabs.isEmpty, !placeholderCustomised {
            deleteSpace(placeholder.id)
        }
        firstRunPlaceholderID = nil
        onboarding?.arcImportFinished()
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
        if wasEnabled != agentsEnabled { siteSettingsDidChange(id) } // agents off also ends console/network capture
    }

    /// Sets only `agentsEnabled` (the policy is left as it is), with the same effects as `updateSpace`.
    func setAgentsEnabled(_ on: Bool, spaceID: UUID) {
        guard let space = space(spaceID), space.agentsEnabled != on else { return }
        mutateSpace(spaceID) { $0.agentsEnabled = on }
        mcp?.toolsChanged()
        siteSettingsDidChange(spaceID)
    }

    /// The user picked a Space (Space rail, Spaces menu, ⌘1…⌘9, palette). Unlike `selectSpace`,
    /// which `createSpace` and the Arc import also call while the welcome flow must stay open,
    /// this leaves the flow first.
    func userSelectSpace(_ id: UUID) {
        closeWelcome()
        selectSpace(id)
    }

    /// Shows the New Space (nil) or Edit Space sheet, leaving the welcome flow first.
    func showSpaceEditor(spaceID: UUID?) {
        closeWelcome()
        spaceEditor = SpaceEditorRequest(spaceID: spaceID)
    }

    // MARK: - Welcome flow

    /// Opens the welcome flow at step 1 (menu and palette: "Welcome to Singularity…").
    func showWelcome() {
        onboarding = OnboardingFlow()
        palette = nil
        welcomePluginReview = nil
    }

    /// Step 4's Review…, or a finished Add: shows the plugin's approval sheet, but only while the
    /// flow is on step 4. An Add that finishes after the user left the flow (Skip setup, Esc) or
    /// the step must not leave a sheet waiting for the next time the flow opens.
    func reviewWelcomePlugin(_ id: String) {
        guard onboarding?.step == .plugins else { return }
        welcomePluginReview = id
    }

    /// Skip setup, Esc, or finishing the last step. Also called by every command that takes the
    /// user somewhere else (New Tab, New Terminal, picking a Space, …).
    func closeWelcome() {
        onboarding = nil
        firstRunPlaceholderID = nil
        welcomePluginReview = nil
    }

    /// File → Close Tab (⌘W). On the welcome flow it closes the flow, never the tab hidden behind
    /// it, and does nothing while a sheet is open over the flow: the menu's shortcut still reaches
    /// us then, and closing the flow would leave the Arc import over the sidebar, or take a
    /// plugin's approval sheet away together with step 4.
    func closeTabCommand() {
        if welcomeCoversWindow {
            if !welcomeSheetIsOpen { closeWelcome() }
        } else {
            closeSelectedTab()
        }
    }

    func advanceWelcome() {
        guard var flow = onboarding else { return }
        if flow.advance() == nil {
            closeWelcome()
        } else {
            onboarding = flow
        }
    }

    func welcomeBack() {
        onboarding?.back()
    }

    /// The Space step 2 edits: the placeholder on a brand-new install, else the selected Space.
    var welcomeSpace: Space? {
        firstRunPlaceholderID.flatMap(space) ?? selectedSpace
    }

    /// Step 2's Continue. Saves the three fields; the placeholder Space of a brand-new install
    /// (while it has no tabs) also takes a slug made from the new name, folder and all.
    func applyWelcomeSpace(name: String, colorHex: String, workingDirectory: String) {
        guard let target = welcomeSpace else { return }
        if target.id == firstRunPlaceholderID { placeholderCustomised = true }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateSpace(target.id) {
            if !trimmed.isEmpty { $0.name = trimmed }
            $0.colorHex = colorHex
            $0.workingDirectory = workingDirectory
        }
        if FirstRun.mayReslug(isFirstRunPlaceholder: target.id == firstRunPlaceholderID, tabCount: target.tabs.count) {
            reslugPlaceholder(target.id)
        }
        // Once, after both changes: tool descriptions mention the Space's name (as in
        // `updateSpace`), and tool names are <slug>.<tool>.
        if target.agentsEnabled { mcp?.toolsChanged() }
    }

    /// The one exception to "a slug is fixed at creation" (spec, step 2). Everything on disk for a
    /// Space lives under `spaces/<slug>/` (space.json, history, agent log, favicons, artifacts), so
    /// the folder moves with it. In-memory caches are keyed by the Space's id, except the favicon
    /// cache (slug|host), which the placeholder can't have entries in: it has no tabs. WebKit's
    /// data store is keyed by the id too, so logins are unaffected. The caller tells agents.
    private func reslugPlaceholder(_ id: UUID) {
        guard let space = space(id) else { return }
        let taken = Set(spaces.filter { $0.id != id }.map(\.slug)).union(slugsOnDisk()).subtracting([space.slug])
        let newSlug = Slug.unique(from: space.name, existing: taken)
        guard newSlug != space.slug else { return }

        // Write what is pending (the new name and colour included) into the old folder, so the
        // move carries everything and no later save recreates the old folder.
        flushSaves()
        // The artifact server serves (and its watcher watches) the old folder: stop it before the
        // move; `loadSelectedTab` below starts it again on the new path.
        artifacts.stop(id)
        knownArtifactPages[id] = nil
        do {
            try store.moveSpaceFolder(fromSlug: space.slug, toSlug: newSlug)
        } catch {
            NSLog("Singularity: could not rename the folder of \(space.slug) to \(newSlug): \(error)")
            if selectedSpaceID == id { loadSelectedTab() }
            return // keeps the old slug; the other fields were saved above
        }
        mutateSpace(id) { $0.slug = newSlug }
        flushSaves()
        if selectedSpaceID == id { loadSelectedTab() }
    }

    // MARK: - Site settings

    /// The Space's "Let agents see console and network" switch.
    func setAgentInspection(_ on: Bool, spaceID: UUID) {
        guard let space = space(spaceID), space.agentInspection != on else { return }
        mutateSpace(spaceID) { $0.agentInspection = on }
        mcp?.toolsChanged() // read_console and read_network appear or go
        siteSettingsDidChange(spaceID)
    }

    /// Changes the owner's choices for one site ("https://example.com") in a Space.
    func updateSiteSettings(spaceID: UUID, site: String, _ change: (inout SiteSettings) -> Void) {
        guard let space = space(spaceID) else { return }
        var settings = space.settings(forSite: site)
        change(&settings)
        guard settings != space.settings(forSite: site) else { return }
        mutateSpace(spaceID) { $0.setSettings(settings, forSite: site) }
        siteSettingsDidChange(spaceID)
    }

    /// Settings → Data & privacy: forgets every per-site choice of a Space.
    func resetSiteSettings(spaceID: UUID) {
        mutateSpace(spaceID) { $0.siteSettings = [:] }
        siteSettingsDidChange(spaceID)
    }

    /// Scripts follow the settings from each page's next load; what was captured for a site that
    /// is no longer switched on is dropped right away.
    private func siteSettingsDidChange(_ spaceID: UUID) {
        pluginScripts.scheduleRefresh()
        guard let space = space(spaceID) else { return }
        for controller in web.controllers(in: spaceID)
        where !InspectionRules.isAllowed(space, site: SiteInfo.site(of: controller.webView.url)) {
            controller.clearCapture()
        }
    }

    /// ⌃⇥ / ⌃⇧⇥: the next or previous tab in sidebar order, wrapping around. A split counts once
    /// (its whole row), so stepping through the sidebar feels like stepping through rows.
    func selectAdjacentTab(_ step: Int) {
        guard let space = selectedSpace else { return }
        let items = space.sidebarSections.flatMap { space.sidebarItems(in: $0) }
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
        //
        // WebKit only sets itself up when the first web view (or configuration) is made. Until
        // then `remove(forIdentifier:)` crashes inside WebKit (it sends its answer to a main run
        // loop it hasn't created yet): deleting a Space right after launch, before any page was
        // shown, took the app down. Making a configuration is enough to set WebKit up.
        _ = WKWebViewConfiguration()
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

    /// Switches to the tab's Space (if needed) and selects the tab.
    func showTab(_ tabID: UUID, in spaceID: UUID) {
        guard space(spaceID)?.tab(tabID) != nil else { return }
        closeWelcome() // the user asked to see the tab (approval sheet's "Show Tab")
        if selectedSpaceID != spaceID { selectSpace(spaceID) }
        selectTab(tabID)
    }

    /// Opens a URL in a new tab and selects it (in the current Space unless one is given).
    /// Leaves the welcome flow alone: an artifact page's `singularity.open` calls this without the
    /// user doing anything, so the user-driven callers (the palette) close the flow themselves.
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
        closeWelcome()
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
        missingArtifactTabs.remove(tabID)
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

    /// A tab dropped between two rows of a section (possibly coming from another section).
    func moveTab(_ tabID: UUID, to section: SidebarSection, atRow row: Int) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.moveTab(tabID, to: section, atRow: row) }
    }

    /// Reorders sidebar rows (a split's row moves all its tabs).
    func moveSidebarItems(in section: SidebarSection, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.moveSidebarItems(in: section, fromOffsets: offsets, toOffset: destination) }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String, inside parentID: UUID? = nil) -> Folder? {
        guard let spaceID = selectedSpaceID else { return nil }
        let folder = Folder(name: name, parentID: parentID)
        mutateSpace(spaceID) { space in
            space.folders.append(folder)
            // Open the folder it went into, so the new one is on screen.
            if let index = space.folders.firstIndex(where: { $0.id == parentID }) {
                space.folders[index].isExpanded = true
            }
        }
        return folder
    }

    /// Puts a folder inside another one, or at the top level (nil).
    func moveFolder(_ folderID: UUID, into parentID: UUID?) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.moveFolder(folderID, into: parentID) }
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
    /// `parentID` makes it a folder inside that folder.
    func promptNewFolder(moving tabID: UUID? = nil, inside parentID: UUID? = nil) {
        nameRequest = NameRequest(title: "New Folder", initialValue: "") { [weak self] name in
            guard let self, let folder = self.createFolder(named: name, inside: parentID) else { return }
            if let tabID { self.moveTab(tabID, to: .folder(folder.id)) }
        }
    }

    // MARK: - Palette

    func showPalette(_ mode: PaletteMode) {
        closeWelcome()
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
        if url != nil, space(spaceID)?.tab(tabID)?.isArtifact == true { refreshMissingArtifacts(spaceID: spaceID) }
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
        // Callers may hold an older copy of the Space; the welcome flow can change its slug (and
        // folder) in between, so take the folder from the current one.
        guard let space = self.space(space.id) else { return nil }
        let host = await artifacts.ensureStarted(space, root: paths.artifactsDirectory(space.slug))
        if let host, knownArtifactPages[space.id] == nil {
            knownArtifactPages[space.id] = Set(host.pages)
            refreshMissingArtifacts(spaceID: space.id)
        }
        return host
    }

    /// Re-checks which of the Space's artifact tabs still have their file.
    private func refreshMissingArtifacts(spaceID: UUID) {
        guard let space = space(spaceID), let root = artifacts.host(spaceID)?.root else { return }
        var missing = missingArtifactTabs.subtracting(space.tabs.map(\.id))
        for tab in space.tabs {
            if let path = tab.artifactPath, !ArtifactFiles.exists(relativePath: path, root: root) {
                missing.insert(tab.id)
            }
        }
        if missing != missingArtifactTabs { missingArtifactTabs = missing }
    }

    // MARK: - Artifacts

    /// Called by a Space's folder watcher. New HTML pages get a tab (without taking focus);
    /// changed files reload the artifact tabs that show them.
    func artifactsDidChange(spaceID: UUID, changes: [ArtifactWatcher.Change]) {
        guard let space = space(spaceID) else { return }
        var known = knownArtifactPages[spaceID] ?? []
        let root = artifacts.host(spaceID)?.root
        var reloadAll = false
        var pagesToReload = Set<String>()

        for change in changes {
            let path = change.relativePath
            // HTML pages, and a script that is "the app" (app.tsx, …) of a folder without one.
            let isPage = root.map { ArtifactFiles.isArtifactPage(path, root: $0) } ?? ArtifactFiles.isArtifactPage(path)
            switch change.kind {
            case .removed:
                known.remove(path)
                pagesToReload.insert(path) // the tab shows "file is missing" until it comes back
            case .changed where isPage:
                pagesToReload.insert(path)
                // A script that is a page is also a module other pages may import.
                if ArtifactScripts.isEntryScript(path) { reloadAll = true }
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
        refreshMissingArtifacts(spaceID: spaceID)
    }

    /// Opens an artifact page (or selects its tab if one is already open).
    func openArtifact(_ path: String) {
        guard let space = selectedSpace else { return }
        closeWelcome()
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
        refreshMissingArtifacts(spaceID: space.id)
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
        // Once the launch Space has a tab it is no longer an untouched placeholder.
        if id == firstRunPlaceholderID, !spaces[index].tabs.isEmpty { firstRunPlaceholderID = nil }
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
