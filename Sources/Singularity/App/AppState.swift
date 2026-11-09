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
    let favicons: FaviconStore

    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let store: SpaceStore
    @ObservationIgnored private var historyCache: [UUID: [HistoryEntry]] = [:]

    // Saving: changes mark things dirty; a short debounce then writes them all at once.
    @ObservationIgnored private var dirtySpaceIDs: Set<UUID> = []
    @ObservationIgnored private var stateFileDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(paths: Paths) {
        self.paths = paths
        self.store = SpaceStore(paths: paths)
        self.web = WebViewRegistry()
        self.favicons = FaviconStore(paths: paths)

        let loaded = store.load()
        spaces = loaded.spaces
        loadErrors = loaded.errors
        selectedSpaceID = loaded.state.selectedSpaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil }
            ?? spaces.first?.id

        if spaces.isEmpty {
            createSpace(name: "Personal", colorHex: SpaceColors.presets[0], workingDirectory: "~")
        }

        web.state = self

        // Flush pending writes when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaves() }
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
    func createSpace(name: String, colorHex: String, workingDirectory: String) -> Space {
        let slug = Slug.unique(from: name, existing: Set(spaces.map(\.slug)) .union(slugsOnDisk()))
        let space = Space(name: name, slug: slug, colorHex: colorHex, workingDirectory: workingDirectory)
        spaces.append(space)
        markDirty(space.id)
        stateFileDirty = true
        selectSpace(space.id)
        return space
    }

    func updateSpace(_ id: UUID, name: String, colorHex: String, workingDirectory: String) {
        mutateSpace(id) {
            $0.name = name
            $0.colorHex = colorHex
            $0.workingDirectory = workingDirectory
        }
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
        spaces.removeAll { $0.id == id }
        dirtySpaceIDs.remove(id) // don't recreate the folder with a pending save
        historyCache[id] = nil
        if selectedSpaceID == id {
            selectedSpaceID = spaces.first?.id
            loadSelectedTab()
        }
        stateFileDirty = true
        scheduleSave()

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
        mutateSpace(spaceID) { $0.selectedTabID = tabID }
        loadSelectedTab()
    }

    /// Opens a URL in a new tab in the current Space and selects it.
    func openInNewTab(_ url: URL) {
        guard let spaceID = selectedSpaceID else { return }
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

    /// Loads a URL in the selected tab, or in a new tab if nothing is selected.
    func navigateSelectedTab(to url: URL) {
        guard let space = selectedSpace, let tab = space.selectedTab else {
            openInNewTab(url)
            return
        }
        web.controller(for: tab, in: space).load(url)
    }

    func closeTab(_ tabID: UUID, in spaceID: UUID? = nil) {
        guard let spaceID = spaceID ?? selectedSpaceID else { return }
        web.removeControllers(for: [tabID])
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

    func moveTabs(in section: SidebarSection, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let spaceID = selectedSpaceID else { return }
        mutateSpace(spaceID) { $0.moveTabs(in: section, fromOffsets: offsets, toOffset: destination) }
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
        mutateSpace(spaceID) { space in
            space.updateTab(tabID) { tab in
                if let title { tab.title = title }
                if let url { tab.kind = .web(url: url) }
            }
        }
    }

    /// Called when a page finishes loading: records it in the Space's history.
    func recordVisit(spaceID: UUID, url: URL, title: String) {
        guard let space = space(spaceID), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
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

    /// Makes sure the selected tab of the selected Space has a live web view.
    /// Web views are created lazily, so restored tabs cost nothing until first shown.
    func loadSelectedTab() {
        guard let space = selectedSpace, let tab = space.selectedTab else { return }
        _ = web.controller(for: tab, in: space)
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
