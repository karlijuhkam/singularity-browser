import AppKit
import Observation
import OSLog
import SingularityCore
import WebKit

private let extensionLog = Logger(subsystem: "dev.roosa.Singularity", category: "extensions")

/// Browser extensions (WebExtensions through WebKit's `WKWebExtension`), per Space.
///
/// Things to keep (see the spec, `docs/superpowers/specs/2026-11-17-extensions-design.md`):
/// - **One controller per Space.** `controller(for:)` makes a `WKWebExtensionController` with the
///   Space's own website data store and a persistent identifier (the Space's id), so an extension in
///   one Space never sees another Space's tabs, cookies or storage. Every web view of a Space gets
///   it when the view is made (`WebViewRegistry`): WebKit ignores a controller set later. Switching
///   an extension on or off loads or unloads its context in that controller.
/// - **Nothing runs unapproved.** An extension runs only from `extensions/<id>/` after the owner
///   pressed Install in `ExtensionApprovalSheet`, and only while that folder still has the
///   fingerprint recorded then; a change pauses it until it is approved again.
/// - **Pages can only ask.** The store's button (`StoreButtonScript`), the address row's button and
///   a downloaded .crx/.xpi all end in `pending`, i.e. the sheet. Never approved in code.
@MainActor
@Observable
final class ExtensionCenter: NSObject {
    @ObservationIgnored weak var state: AppState?
    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let store: ExtensionStateStore

    /// The approved extensions, by id.
    private(set) var records: [String: ExtensionRecord] = [:]
    /// Whether each record's files are still the approved ones.
    private(set) var statuses: [String: ExtensionRules.Status] = [:]
    /// Why WebKit couldn't load an extension (shown in Settings → Extensions).
    private(set) var loadErrors: [String: String] = [:]
    /// Shown at the top of Settings → Extensions when the saved state couldn't be read.
    private(set) var stateWarning: String?
    /// The extension waiting for the owner's Install or Cancel (the approval sheet shows it).
    var pending: PendingExtension?
    /// The last install problem, for an alert.
    var installMessage: InstallMessage?
    /// Store ids being downloaded right now.
    private(set) var downloading: Set<String> = []
    /// Bumped whenever a toolbar button may look different (icon, badge, an extension loaded).
    private(set) var actionsVersion = 0
    /// True once the approved extensions are loaded (pages wait a moment for this at launch).
    private(set) var isReady = false
    /// Why an extension's adaptation failed (Settings → Extensions shows it; spec 2026-11-21).
    private(set) var adaptNotes: [String: String] = [:]

    /// Builds adapted copies (`CompatAdapter.adapt`); tests replace it to make adapting fail.
    @ObservationIgnored var adapter: @Sendable (URL, URL, String) throws -> CompatSummary? = { original, into, id in
        try CompatAdapter.adapt(original: original, into: into, extensionID: id)
    }
    /// The extensions WebKit loads from their adapted copy (`extensions-adapted/<id>/`).
    @ObservationIgnored private var loadsAdapted: Set<String> = []

    @ObservationIgnored private var extensions: [String: WKWebExtension] = [:]
    @ObservationIgnored private var controllers: [UUID: WKWebExtensionController] = [:]
    @ObservationIgnored private var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
    /// Match patterns denied per (Space, extension) because the owner switched it off for a site.
    @ObservationIgnored private var siteDenies: [UUID: [String: Set<String>]] = [:]
    @ObservationIgnored private var tabAdapters: [UUID: ExtensionTab] = [:]
    @ObservationIgnored private var spaceWindows: [UUID: ExtensionWindow] = [:]
    @ObservationIgnored private var littleWindows: [UUID: ExtensionWindow] = [:]
    @ObservationIgnored private var activeTab: [UUID: UUID] = [:]
    /// The toolbar button an extension's popup opens from (set when the owner clicks it).
    @ObservationIgnored private var anchors: [String: WeakView] = [:]

    struct InstallMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    init(paths: Paths) {
        self.paths = paths
        self.store = ExtensionStateStore(file: paths.extensionStateFile)
        super.init()
    }

    // MARK: - Start

    /// Reads the records, checks each folder against its fingerprint and loads the approved ones.
    func start() {
        let loaded = store.loadSettingAsideCorrupt()
        records = loaded.records.filter { ExtensionRules.isValidID($0.key) && $0.key == $0.value.id }
        if loaded.wasCorrupt {
            stateWarning = "Saved extension approvals couldn't be read and were set aside; extensions need adding again."
        }
        guard !records.isEmpty else { return markReady() }
        let folders = records.keys.map { ($0, folder(of: $0), adaptedFolder(of: $0)) }
        Task {
            // Hashing a large extension (uBlock Origin Lite's rule sets) takes a moment: off the main thread.
            let found = await Task.detached { () -> [String: (Bool, String?, String?)] in
                var out: [String: (Bool, String?, String?)] = [:]
                for (id, folder, adapted) in folders {
                    let exists = FileManager.default.fileExists(atPath: folder.path)
                    let adaptedNow = FileManager.default.fileExists(atPath: adapted.path) ? try? PluginFingerprint.compute(folder: adapted) : nil
                    out[id] = (exists, exists ? try? PluginFingerprint.compute(folder: folder) : nil, adaptedNow)
                }
                return out
            }.value
            for (id, record) in records {
                let (exists, fingerprint, _) = found[id] ?? (false, nil, nil)
                statuses[id] = ExtensionRules.status(record: record, folderExists: exists, currentFingerprint: fingerprint)
            }
            for id in records.keys.sorted() where statuses[id] == .ready { await prepareAdaptation(id, adaptedNow: found[id]?.2 ?? nil) }
            for id in records.keys where statuses[id] == .ready { await loadExtension(id) }
            for spaceID in controllers.keys { syncContexts(spaceID) }
            markReady()
            scheduleUpdateChecks()
        }
    }

    private func markReady() {
        isReady = true
    }

    /// Waits until the approved extensions are loaded, at most `timeout`: a restored tab loads its
    /// page only then, so content scripts are there from the first load.
    func waitUntilReady(timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while !isReady, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func loadExtension(_ id: String) async {
        do {
            let loaded = try await WKWebExtension(resourceBaseURL: loadFolder(of: id).standardizedFileURL)
            extensions[id] = loaded
            loadErrors[id] = nil
        } catch {
            extensions[id] = nil
            loadErrors[id] = error.localizedDescription
            extensionLog.error("could not load extension \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func folder(of id: String) -> URL {
        paths.extensionsDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    func adaptedFolder(of id: String) -> URL {
        paths.extensionsAdaptedDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    /// The folder WebKit loads: the adapted copy for an extension that needs one, else the original.
    func loadFolder(of id: String) -> URL {
        loadsAdapted.contains(id) ? adaptedFolder(of: id) : folder(of: id)
    }

    // MARK: - Adapting (spec docs/superpowers/specs/2026-11-21-extension-compat-design.md)

    /// At launch, for an extension whose original is the approved one: use its adapted copy if it
    /// was made by this adapter and still matches its fingerprint; otherwise build it again from the
    /// original (without a sheet: the original, its permissions and the approval don't change). If
    /// that fails, an old copy that still matches keeps running; with none the extension is paused.
    private func prepareAdaptation(_ id: String, adaptedNow: String?) async {
        guard var record = records[id] else { return }
        switch ExtensionRules.adaptationStep(record, adaptedFingerprintNow: adaptedNow) {
        case .original:
            loadsAdapted.remove(id)
            return
        case .adapted:
            loadsAdapted.insert(id)
            return
        case .rebuild:
            break
        }
        let original = folder(of: id), target = adaptedFolder(of: id), stageRoot = paths.extensionInstallDirectory
        let adapter = self.adapter
        let result = await Task.detached { () -> Result<(CompatSummary, String)?, Error> in
            Result { try Self.rebuildAdaptation(original: original, target: target, stageRoot: stageRoot, id: id, adapter: adapter) }
        }.value
        switch result {
        case .success(nil):
            record.adaptation = CompatAdapter.version
            record.adaptedFingerprint = nil
            record.adaptationSummary = nil
            loadsAdapted.remove(id)
            adaptNotes[id] = nil
        case .success(let built?):
            record.adaptation = CompatAdapter.version
            record.adaptationSummary = built.0
            record.adaptedFingerprint = built.1
            loadsAdapted.insert(id)
            adaptNotes[id] = nil
        case .failure(let error):
            extensionLog.error("could not adapt \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if ExtensionRules.afterFailedRebuild(record, adaptedFingerprintNow: adaptedNow) == .adapted {
                loadsAdapted.insert(id)
                adaptNotes[id] = "Couldn't be adapted by this version of Singularity; the previous adaptation is running."
            } else {
                loadsAdapted.remove(id)
                statuses[id] = .cannotAdapt
                adaptNotes[id] = "Couldn't be adapted: " + error.localizedDescription
            }
            return
        }
        records[id] = record
        save()
    }

    /// Builds the adapted copy of `original` in a staging folder and swaps it in as `target`
    /// (removing any old copy when none is needed now). Returns the summary and the new copy's
    /// fingerprint, or nil when the extension needs nothing.
    nonisolated static func rebuildAdaptation(original: URL, target: URL, stageRoot: URL, id: String,
                                              adapter: (URL, URL, String) throws -> CompatSummary?) throws -> (CompatSummary, String)? {
        let fm = FileManager.default
        let stage = stageRoot.appending(path: "adapt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let built = stage.appending(path: "x", directoryHint: .isDirectory)
        guard let summary = try adapter(original, built, id) else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return nil
        }
        let fingerprint = try PluginFingerprint.compute(folder: built)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: stage.appending(path: "old")) }
        try fm.moveItem(at: built, to: target)
        return (summary, fingerprint)
    }

    /// What adapting a staged extension gave, for the sheet.
    enum PendingAdaptation {
        /// Nothing needed: it runs from its original folder.
        case none
        /// The adapted copy, built in the staging folder.
        case adapted(folder: URL, summary: CompatSummary)
        /// It needs adapting and that failed: it can't be installed.
        case failed(String)
    }

    /// Adapts a staged extension into `<stage>/adapted` and loads the copy to check it asks for
    /// exactly what the original asks for. Returns the extension WebKit will run and the outcome.
    private func adaptStaged(_ staged: ExtensionInstaller.Staged, id: String, original: WKWebExtension) async -> (WKWebExtension, PendingAdaptation) {
        let into = staged.stage.appending(path: "adapted", directoryHint: .isDirectory)
        let root = staged.root, adapter = self.adapter
        let result = await Task.detached { Result { try adapter(root, into, id) } }.value
        switch result {
        case .success(nil):
            return (original, .none)
        case .failure(let error):
            return (original, .failed(error.localizedDescription))
        case .success(let summary?):
            do {
                let adapted = try await WKWebExtension(resourceBaseURL: into.standardizedFileURL)
                guard Set(adapted.requestedPermissions) == Set(original.requestedPermissions),
                      Set(adapted.allRequestedMatchPatterns.map(\.string)) == Set(original.allRequestedMatchPatterns.map(\.string)) else {
                    return (original, .failed(CompatAdapter.Failure.permissionsChanged.localizedDescription))
                }
                return (adapted, .adapted(folder: into, summary: summary))
            } catch {
                return (original, .failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Controllers and contexts

    /// The Space's controller, made on first use (with the Space's first web view).
    func controller(for spaceID: UUID) -> WKWebExtensionController {
        if let existing = controllers[spaceID] { return existing }
        let configuration = WKWebExtensionController.Configuration(identifier: spaceID)
        configuration.defaultWebsiteDataStore = WKWebsiteDataStore(forIdentifier: spaceID)
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        controllers[spaceID] = controller
        syncContexts(spaceID)
        return controller
    }

    /// Whether `id` should be loaded in `spaceID` now.
    private func shouldRun(_ id: String, in spaceID: UUID) -> Bool {
        guard let record = records[id], let status = statuses[id], extensions[id] != nil else { return false }
        return ExtensionRules.runs(record, status: status, in: spaceID)
    }

    /// Loads and unloads the Space's contexts so they match the records and switches.
    func syncContexts(_ spaceID: UUID) {
        guard let controller = controllers[spaceID], let space = state?.space(spaceID) else { return }
        var current = contexts[spaceID] ?? [:]
        for (id, context) in current where !shouldRun(id, in: spaceID) || context.webExtension !== extensions[id] {
            try? controller.unload(context)
            current[id] = nil
            siteDenies[spaceID]?[id] = nil
        }
        for id in records.keys.sorted() where current[id] == nil && shouldRun(id, in: spaceID) {
            guard let loaded = extensions[id], var record = records[id] else { continue }
            let context = WKWebExtensionContext(for: loaded)
            if let identifier = record.contextIDs[spaceID] {
                context.uniqueIdentifier = identifier
            } else {
                record.contextIDs[spaceID] = context.uniqueIdentifier
                records[id] = record
                save()
            }
            context.isInspectable = true
            context.inspectionName = "\(record.name) (\(space.name))"
            for name in record.permissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name)) }
            for text in record.patterns {
                if let pattern = try? WKWebExtension.MatchPattern(string: text) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            }
            if let grants = record.grants[spaceID] { apply(grants, to: context) }
            do {
                try controller.load(context)
                current[id] = context
            } catch {
                loadErrors[id] = error.localizedDescription
                extensionLog.error("could not start \(id, privacy: .public) in a Space: \(error.localizedDescription, privacy: .public)")
            }
        }
        contexts[spaceID] = current
        applySiteSwitches(spaceID)
        actionsVersion += 1
    }

    private func apply(_ grants: ExtensionRecord.Grants, to context: WKWebExtensionContext) {
        for name in grants.permissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name)) }
        for name in grants.deniedPermissions { context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: name)) }
        for text in grants.patterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: text) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        }
        for text in grants.deniedPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: text) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        }
    }

    /// The per-site switches of a Space (site settings panel): a site switched off is denied to that
    /// extension. Called after the Space's site settings change.
    func applySiteSwitches(_ spaceID: UUID) {
        guard let space = state?.space(spaceID) else { return }
        for (id, context) in contexts[spaceID] ?? [:] {
            let wanted = Set(space.siteSettings.compactMap { site, settings in
                settings.disabledExtensions.contains(id) ? ExtensionRules.pattern(forSite: site) : nil
            })
            let before = siteDenies[spaceID]?[id] ?? []
            for text in before.subtracting(wanted) {
                guard let pattern = try? WKWebExtension.MatchPattern(string: text) else { continue }
                // Back to what approval granted (the pattern may be one the manifest asked for).
                let granted = records[id]?.patterns.contains(text) == true || records[id]?.grants[spaceID]?.patterns.contains(text) == true
                context.setPermissionStatus(granted ? .grantedExplicitly : .unknown, for: pattern)
            }
            for text in wanted.subtracting(before) {
                if let pattern = try? WKWebExtension.MatchPattern(string: text) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
            }
            siteDenies[spaceID, default: [:]][id] = wanted
        }
    }

    /// The extensions loaded in a Space, sorted by name.
    func loadedIDs(in spaceID: UUID) -> [String] {
        _ = actionsVersion
        return (contexts[spaceID] ?? [:]).keys.sorted { (records[$0]?.name ?? $0).localizedCaseInsensitiveCompare(records[$1]?.name ?? $1) == .orderedAscending }
    }

    func context(_ id: String, in spaceID: UUID) -> WKWebExtensionContext? { contexts[spaceID]?[id] }

    /// For a `webkit-extension://` address: the configuration of the extension it belongs to in
    /// that Space (nil for any other address, or an extension not running there).
    func pageConfiguration(for url: URL, spaceID: UUID) -> WKWebViewConfiguration? {
        guard url.scheme?.lowercased() == "webkit-extension" else { return nil }
        return controller(for: spaceID).extensionContext(for: url)?.webViewConfiguration
    }

    /// Whether the Space has an extension controller (made with its first web view).
    func hasController(_ spaceID: UUID) -> Bool { controllers[spaceID] != nil }

    // MARK: - Tabs and windows

    static func isWebTab(_ tab: BrowserTab) -> Bool {
        if case .web = tab.kind { return true }
        return false
    }

    /// A Space's web tabs in sidebar order: what extensions see as the window's tabs.
    static func webTabIDs(of space: Space) -> [UUID] {
        space.tabsInSidebarOrder.filter(isWebTab).map(\.id)
    }

    func tabAdapter(_ tabID: UUID, spaceID: UUID) -> ExtensionTab {
        if let existing = tabAdapters[tabID], existing.spaceID == spaceID { return existing }
        let adapter = ExtensionTab(tabID: tabID, spaceID: spaceID, center: self)
        tabAdapters[tabID] = adapter
        return adapter
    }

    func windowAdapter(for tab: ExtensionTab) -> ExtensionWindow {
        if tab.isLittle {
            if let existing = littleWindows[tab.tabID] { return existing }
            let window = ExtensionWindow(kind: .little(tab.tabID), center: self)
            littleWindows[tab.tabID] = window
            return window
        }
        return spaceWindow(tab.spaceID)
    }

    func spaceWindow(_ spaceID: UUID) -> ExtensionWindow {
        if let existing = spaceWindows[spaceID] { return existing }
        let window = ExtensionWindow(kind: .space(spaceID), center: self)
        spaceWindows[spaceID] = window
        return window
    }

    /// A web view was made for a tab (or a little window's page).
    func tabOpened(_ tabID: UUID, spaceID: UUID) {
        guard let controller = controllers[spaceID] else { return }
        controller.didOpenTab(tabAdapter(tabID, spaceID: spaceID))
    }

    /// A tab's web view went away.
    func tabClosed(_ tabID: UUID, spaceID: UUID) {
        guard let adapter = tabAdapters.removeValue(forKey: tabID) else { return }
        littleWindows[tabID] = nil
        if activeTab[spaceID] == tabID { activeTab[spaceID] = nil }
        controllers[spaceID]?.didCloseTab(adapter)
    }

    /// The tab's title or address changed.
    func tabChanged(_ tabID: UUID, spaceID: UUID) {
        guard let controller = controllers[spaceID], let adapter = tabAdapters[tabID] else { return }
        controller.didChangeTabProperties([.title, .URL, .loading], for: adapter)
        actionsVersion += 1
    }

    /// The Space's selected tab may have changed.
    func selectionChanged(in spaceID: UUID) {
        guard let controller = controllers[spaceID], let space = state?.space(spaceID),
              let selected = space.selectedTabID, space.tab(selected).map(Self.isWebTab) == true,
              activeTab[spaceID] != selected else { return }
        let previous = activeTab[spaceID].flatMap { tabAdapters[$0] }
        activeTab[spaceID] = selected
        controller.didActivateTab(tabAdapter(selected, spaceID: spaceID), previousActiveTab: previous)
        actionsVersion += 1
    }

    // MARK: - Toolbar

    struct ToolbarItem: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let badge: String
        let isEnabled: Bool
    }

    /// The buttons for the tab on screen in a Space: one per loaded extension that has an action.
    func toolbarItems(spaceID: UUID, tabID: UUID) -> [ToolbarItem] {
        _ = actionsVersion
        let adapter = tabAdapter(tabID, spaceID: spaceID)
        return loadedIDs(in: spaceID).compactMap { id in
            guard let context = contexts[spaceID]?[id], let action = context.action(for: adapter) else { return nil }
            let name = action.label.isEmpty ? (records[id]?.name ?? id) : action.label
            return ToolbarItem(id: id, name: name, icon: action.icon(for: CGSize(width: 16, height: 16)),
                               badge: action.badgeText, isEnabled: action.isEnabled)
        }
    }

    /// The owner clicked an extension's button.
    func performAction(_ id: String, spaceID: UUID, tabID: UUID, anchor: NSView) {
        guard let context = contexts[spaceID]?[id] else { return }
        anchors[id] = WeakView(view: anchor)
        let adapter = tabAdapter(tabID, spaceID: spaceID)
        context.userGesturePerformed(in: adapter)
        context.performAction(for: adapter)
    }

    /// From the address row's "more extensions" menu: the popup hangs from the menu's place.
    func performActionFromMenu(_ id: String, spaceID: UUID, tabID: UUID) {
        guard let context = contexts[spaceID]?[id] else { return }
        if anchors[id]?.view?.window == nil, let any = anchors.values.compactMap({ $0.view }).first(where: { $0.window != nil }) {
            anchors[id] = WeakView(view: any)
        }
        let adapter = tabAdapter(tabID, spaceID: spaceID)
        context.userGesturePerformed(in: adapter)
        context.performAction(for: adapter)
    }

    // MARK: - Switches

    func setEnabled(_ id: String, spaceID: UUID, on: Bool) {
        guard var record = records[id], record.enabledSpaces.contains(spaceID) != on else { return }
        if on { record.enabledSpaces.insert(spaceID) } else { record.enabledSpaces.remove(spaceID) }
        records[id] = record
        save()
        syncContexts(spaceID)
    }

    /// Opens the extension's options page as a tab in the Space.
    func openOptions(_ id: String, spaceID: UUID) {
        guard let url = contexts[spaceID]?[id]?.optionsPageURL else { return }
        state?.openInNewTab(url, spaceID: spaceID)
    }

    // MARK: - Removing, Spaces, data

    /// Removes an extension everywhere: its contexts, its storage in every Space, its folder.
    func remove(_ id: String) {
        guard records[id] != nil else { return }
        let removed = records.removeValue(forKey: id)
        statuses[id] = nil
        loadErrors[id] = nil
        for (spaceID, controller) in controllers {
            guard let context = contexts[spaceID]?[id] else { continue }
            removeData(of: context, in: controller) { try? controller.unload(context) }
            contexts[spaceID]?[id] = nil
            siteDenies[spaceID]?[id] = nil
        }
        extensions[id] = nil
        try? FileManager.default.removeItem(at: folder(of: id))
        try? FileManager.default.removeItem(at: adaptedFolder(of: id))
        loadsAdapted.remove(id)
        adaptNotes[id] = nil
        save()
        actionsVersion += 1
        extensionLog.notice("removed extension \(id, privacy: .public) (\(removed?.name ?? "", privacy: .public))")
    }

    private func removeData(of context: WKWebExtensionContext, in controller: WKWebExtensionController, then: @escaping @MainActor () -> Void) {
        let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        controller.fetchDataRecord(ofTypes: types, for: context) { record in
            MainActor.assumeIsolated {
                guard let record else { return then() }
                controller.removeData(ofTypes: types, from: [record]) { MainActor.assumeIsolated { then() } }
            }
        }
    }

    /// Settings → Data & privacy → Clear Cookies & Site Data: the extensions' storage in that Space too.
    func clearData(in spaceID: UUID) {
        guard let controller = controllers[spaceID] else { return }
        let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        controller.fetchDataRecords(ofTypes: types) { records in
            controller.removeData(ofTypes: types, from: records) {}
        }
    }

    /// Before a Space is deleted: its contexts are unloaded and their data removed, and the
    /// controller is let go (WebKit won't remove a website data store that is still in use).
    func spaceWillBeDeleted(_ spaceID: UUID) async {
        var changed = false
        for (id, var record) in records where record.enabledSpaces.contains(spaceID) || record.contextIDs[spaceID] != nil || record.grants[spaceID] != nil {
            record.enabledSpaces.remove(spaceID)
            record.contextIDs[spaceID] = nil
            record.grants[spaceID] = nil
            records[id] = record
            changed = true
        }
        if changed { save() }
        if let controller = controllers[spaceID] {
            let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
            let all = await withCheckedContinuation { continuation in
                controller.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
            }
            await withCheckedContinuation { continuation in
                controller.removeData(ofTypes: types, from: all) { continuation.resume() }
            }
            for context in (contexts[spaceID] ?? [:]).values { try? controller.unload(context) }
        }
        contexts[spaceID] = nil
        siteDenies[spaceID] = nil
        spaceWindows[spaceID] = nil
        activeTab[spaceID] = nil
        tabAdapters = tabAdapters.filter { $0.value.spaceID != spaceID }
        controllers[spaceID]?.delegate = nil
        controllers[spaceID] = nil
    }

    // MARK: - Adding

    /// An extension waiting for the owner's answer.
    struct PendingExtension: Identifiable {
        let id = UUID()
        /// The id it will be installed under.
        let extensionID: String
        let staged: ExtensionInstaller.Staged
        let webExtension: WKWebExtension
        let source: ExtensionRecord.Source
        /// The installed version this replaces, if any.
        let replaces: ExtensionRecord?
        /// The Space it was added from (its switch starts on).
        let fromSpace: UUID?
        /// Whether and how Singularity adapts it to run here.
        var adaptation: PendingAdaptation = .none

        var canInstall: Bool {
            if case .failed = adaptation { return false }
            return true
        }
    }

    /// Add Extension… (a folder or file) and a downloaded .crx/.xpi.
    func add(file: URL, fromSpace: UUID?) {
        let installDirectory = paths.extensionInstallDirectory
        Task {
            do {
                let staged = try await Task.detached { try ExtensionInstaller.stage(file, installDirectory: installDirectory) }.value
                await present(staged, source: staged.chromeID != nil && records[staged.chromeID!]?.source == .store ? .store : .file,
                              fromSpace: fromSpace)
            } catch {
                showProblem("“\(file.lastPathComponent)” can't be added", error)
            }
        }
    }

    /// Chrome Web Store: its button, the address row's, and "Check for Update".
    func addFromStore(_ id: String, fromSpace: UUID?, isUpdateCheck: Bool = false) {
        guard ChromeWebStore.isValidID(id), !downloading.contains(id) else { return }
        downloading.insert(id)
        let installDirectory = paths.extensionInstallDirectory
        Task {
            defer { downloading.remove(id) }
            do {
                let data = try await ExtensionInstaller.downloadFromStore(id: id)
                let staged = try await Task.detached {
                    try ExtensionInstaller.stage(crx: data, id: id, installDirectory: installDirectory)
                }.value
                if isUpdateCheck, let record = records[id], statuses[id] == .ready,
                   let version = Self.manifestVersion(staged.root), version == record.version {
                    try? FileManager.default.removeItem(at: staged.stage)
                    installMessage = InstallMessage(title: "\(record.name) is up to date", text: "Version \(version) is the newest in Chrome Web Store.")
                    return
                }
                await present(staged, source: .store, fromSpace: fromSpace)
            } catch {
                showProblem("The extension can't be added", error)
            }
        }
    }

    // MARK: - Automatic updates (owner decision, 2026-11-17)

    /// Store extensions are checked a minute after launch and then once a day. A newer version that
    /// asks for nothing more than the approved one is installed by itself (its signature checked
    /// like any store download; Spaces and data stay); one that asks for more opens the approval
    /// sheet. Off for tests (`automaticUpdates`); file-added extensions are never checked.
    @ObservationIgnored var automaticUpdates = true
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    static let updateInterval: Duration = .seconds(24 * 60 * 60)

    private func scheduleUpdateChecks() {
        guard automaticUpdates, updateLoop == nil else { return }
        updateLoop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self, self.automaticUpdates else { return }
                await self.checkStoreUpdates()
                try? await Task.sleep(for: Self.updateInterval)
            }
        }
    }

    func checkStoreUpdates() async {
        let installDirectory = paths.extensionInstallDirectory
        for record in records.values.sorted(by: { $0.id < $1.id }) where record.source == .store && statuses[record.id] == .ready {
            let id = record.id
            guard !downloading.contains(id), pending?.extensionID != id else { continue }
            downloading.insert(id)
            defer { downloading.remove(id) }
            do {
                let data = try await ExtensionInstaller.downloadFromStore(id: id)
                let staged = try await Task.detached { try ExtensionInstaller.stage(crx: data, id: id, installDirectory: installDirectory) }.value
                guard let version = Self.manifestVersion(staged.root), ExtensionRules.isNewer(version, than: record.version),
                      let current = records[id] else {
                    try? FileManager.default.removeItem(at: staged.stage)
                    continue
                }
                try await installUpdate(staged, current: current)
            } catch {
                extensionLog.error("update check of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A newer store version, staged: adapted first (spec 2026-11-21). One that can't be adapted is
    /// dropped and the old version keeps running; one that asks for nothing more is installed by
    /// itself, else the owner gets the sheet.
    func installUpdate(_ staged: ExtensionInstaller.Staged, current: ExtensionRecord) async throws {
        let id = current.id
        let version = Self.manifestVersion(staged.root) ?? "?"
        let original: WKWebExtension
        do {
            original = try await WKWebExtension(resourceBaseURL: staged.root.standardizedFileURL)
        } catch {
            try? FileManager.default.removeItem(at: staged.stage)
            throw error
        }
        let (webExtension, adaptation) = await adaptStaged(staged, id: id, original: original)
        if case .failed(let reason) = adaptation {
            try? FileManager.default.removeItem(at: staged.stage)
            adaptNotes[id] = "Version \(version) couldn't be adapted; version \(current.version) is running."
            extensionLog.error("update of \(id, privacy: .public) to \(version, privacy: .public) couldn't be adapted: \(reason, privacy: .public)")
            return
        }
        var update = PendingExtension(extensionID: id, staged: staged, webExtension: webExtension, source: .store,
                                      replaces: current, fromSpace: nil)
        update.adaptation = adaptation
        if ExtensionRules.widens(current, permissions: Set(webExtension.requestedPermissions.map(\.rawValue)),
                                 patterns: Set(webExtension.allRequestedMatchPatterns.map(\.string))) {
            // It asks for more: the owner decides (one sheet at a time; else next time).
            if pending == nil { pending = update } else { try? FileManager.default.removeItem(at: staged.stage) }
        } else {
            await approve(update, spaces: current.enabledSpaces)
            extensionLog.notice("updated \(id, privacy: .public) to \(version, privacy: .public) by itself")
        }
    }

    private static func manifestVersion(_ root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appending(path: "manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    private func present(_ staged: ExtensionInstaller.Staged, source: ExtensionRecord.Source, fromSpace: UUID?) async {
        do {
            let original = try await WKWebExtension(resourceBaseURL: staged.root.standardizedFileURL)
            let id = staged.chromeID ?? ExtensionRules.newLocalID(taken: Set(records.keys))
            let (webExtension, adaptation) = await adaptStaged(staged, id: id, original: original)
            if let old = pending { cancel(old) }
            var next = PendingExtension(extensionID: id, staged: staged, webExtension: webExtension, source: source,
                                        replaces: records[id], fromSpace: fromSpace)
            next.adaptation = adaptation
            pending = next
            state?.showMainWindow()
        } catch {
            try? FileManager.default.removeItem(at: staged.stage)
            showProblem("This extension can't be used", error)
        }
    }

    private func showProblem(_ title: String, _ error: Error) {
        installMessage = InstallMessage(title: title, text: error.localizedDescription)
        extensionLog.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    func cancel(_ pending: PendingExtension) {
        try? FileManager.default.removeItem(at: pending.staged.stage)
        if self.pending?.id == pending.id { self.pending = nil }
    }

    /// The owner pressed Install: the staged folder becomes `extensions/<id>/`, the record is
    /// written with what the manifest asks for, and the extension starts in the chosen Spaces.
    func approve(_ pending: PendingExtension, spaces: Set<UUID>) async {
        if self.pending?.id == pending.id { self.pending = nil }
        let id = pending.extensionID
        guard ExtensionRules.isValidID(id), pending.canInstall else {
            try? FileManager.default.removeItem(at: pending.staged.stage)
            return
        }
        let target = folder(of: id)
        let adaptedTarget = adaptedFolder(of: id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.extensionsDirectory, withIntermediateDirectories: true)
            // Unload the old version first: its folder is about to be replaced.
            for (spaceID, controller) in controllers {
                if let context = contexts[spaceID]?[id] { try? controller.unload(context); contexts[spaceID]?[id] = nil }
            }
            extensions[id] = nil
            let old = pending.staged.stage.appending(path: "old", directoryHint: .isDirectory)
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
            try fm.moveItem(at: pending.staged.root, to: target)
            let fingerprint = try await Task.detached { try PluginFingerprint.compute(folder: target) }.value
            // The adapted copy moves into place with it (or an old one goes).
            var adaptedFingerprint: String?
            var summary: CompatSummary?
            if fm.fileExists(atPath: adaptedTarget.path) {
                try fm.moveItem(at: adaptedTarget, to: pending.staged.stage.appending(path: "old-adapted", directoryHint: .isDirectory))
            }
            if case .adapted(let built, let builtSummary) = pending.adaptation {
                try fm.createDirectory(at: paths.extensionsAdaptedDirectory, withIntermediateDirectories: true)
                try fm.moveItem(at: built, to: adaptedTarget)
                adaptedFingerprint = try await Task.detached { try PluginFingerprint.compute(folder: adaptedTarget) }.value
                summary = builtSummary
                loadsAdapted.insert(id)
            } else {
                loadsAdapted.remove(id)
            }
            let loaded = pending.webExtension
            var record = pending.replaces ?? ExtensionRecord(
                id: id, name: "", version: "", source: pending.source, fingerprint: "", permissions: [], patterns: [], enabledSpaces: [])
            record.name = loaded.displayName ?? loaded.displayShortName ?? id
            record.version = loaded.displayVersion ?? loaded.version ?? ""
            record.source = pending.source
            record.fingerprint = fingerprint
            record.permissions = Set(loaded.requestedPermissions.map(\.rawValue))
            record.patterns = Set(loaded.allRequestedMatchPatterns.map(\.string))
            record.enabledSpaces = spaces
            record.adaptation = CompatAdapter.version
            record.adaptedFingerprint = adaptedFingerprint
            record.adaptationSummary = summary
            adaptNotes[id] = nil
            records[id] = record
            statuses[id] = .ready
            save()
            await loadExtension(id)
        } catch {
            showProblem("The extension couldn't be installed", error)
        }
        try? fm.removeItem(at: pending.staged.stage)
        for spaceID in controllers.keys { syncContexts(spaceID) }
        if pending.source == .store { scheduleUpdateChecks() }
        extensionLog.notice("installed extension \(id, privacy: .public)")
    }

    private func save() {
        do {
            try store.save(records)
        } catch {
            extensionLog.error("could not save extension state: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "dev.roosa.Singularity.extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func spaceID(of controller: WKWebExtensionController) -> UUID? {
        controllers.first { $0.value === controller }?.key
    }

    private func extensionID(of context: WKWebExtensionContext, in spaceID: UUID) -> String? {
        contexts[spaceID]?.first { $0.value === context }?.key
    }

    /// Asks the owner on the browser window; no default button (Return must not answer it).
    private func ask(_ title: String, _ text: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let allow = alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Don't Allow")
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\u{1b}"
        guard let window = state?.mainWindow, window.isVisible else { return false }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    private func recordGrants(_ id: String, spaceID: UUID, _ change: (inout ExtensionRecord.Grants) -> Void) {
        guard var record = records[id] else { return }
        var grants = record.grants[spaceID] ?? ExtensionRecord.Grants()
        change(&grants)
        record.grants[spaceID] = grants
        records[id] = record
        save()
    }
}

private struct WeakView {
    weak var view: NSView?
}

// MARK: - WebKit's questions

extension ExtensionCenter: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let spaceID = spaceID(of: controller), let state else { return [] }
        var windows: [any WKWebExtensionWindow] = [spaceWindow(spaceID)]
        for little in state.little.windows where little.controller.spaceID == spaceID {
            windows.append(windowAdapter(for: tabAdapter(little.controller.tabID, spaceID: spaceID)))
        }
        return windows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let spaceID = spaceID(of: controller), state?.selectedSpaceID == spaceID else { return nil }
        return spaceWindow(spaceID)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        completionHandler(nil, Self.failure("Extensions can't open windows in Singularity."))
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let spaceID = spaceID(of: controller), let state, let space = state.space(spaceID) else {
            return completionHandler(nil, Self.failure("No Space."))
        }
        let tab = BrowserTab.web(configuration.url ?? URL(string: "about:blank")!)
        state.mutateSpace(spaceID) {
            $0.append(tab)
            if configuration.shouldBeActive { $0.selectedTabID = tab.id }
        }
        if configuration.shouldBeActive, state.selectedSpaceID == spaceID {
            state.loadSelectedTab()
        } else if let added = state.space(spaceID)?.tab(tab.id) {
            _ = state.web.controller(for: added, in: space)
        }
        completionHandler(tabAdapter(tab.id, spaceID: spaceID), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let spaceID = spaceID(of: controller), let url = extensionContext.optionsPageURL else {
            return completionHandler(Self.failure("No options page."))
        }
        state?.openInNewTab(url, spaceID: spaceID)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        guard let spaceID = spaceID(of: controller), let id = extensionID(of: extensionContext, in: spaceID) else {
            return completionHandler([], nil)
        }
        let name = records[id]?.name ?? id
        let lines = permissions.map { ExtensionWording.permission($0.rawValue) }.sorted().joined(separator: "\n")
        Task {
            let allowed = await ask("“\(name)” asks for more", "In this Space it wants to:\n\(lines)")
            recordGrants(id, spaceID: spaceID) { grants in
                let names = Set(permissions.map(\.rawValue))
                if allowed { grants.permissions.formUnion(names); grants.deniedPermissions.subtract(names) } else { grants.deniedPermissions.formUnion(names) }
            }
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        guard let spaceID = spaceID(of: controller), let id = extensionID(of: extensionContext, in: spaceID) else {
            return completionHandler([], nil)
        }
        let name = records[id]?.name ?? id
        let sites = Set(urls.compactMap { SiteInfo.site(of: $0) })
        let lines = sites.sorted().map(SiteInfo.displayName(ofSite:)).joined(separator: "\n")
        Task {
            let allowed = await ask("“\(name)” wants to read and change these sites", lines)
            let patterns = Set(sites.compactMap(ExtensionRules.pattern(forSite:)))
            recordGrants(id, spaceID: spaceID) { grants in
                if allowed { grants.patterns.formUnion(patterns); grants.deniedPatterns.subtract(patterns) } else { grants.deniedPatterns.formUnion(patterns) }
            }
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        guard let spaceID = spaceID(of: controller), let id = extensionID(of: extensionContext, in: spaceID) else {
            return completionHandler([], nil)
        }
        let name = records[id]?.name ?? id
        let lines = matchPatterns.map { ExtensionWording.sites($0.string) }.sorted().joined(separator: "\n")
        Task {
            let allowed = await ask("“\(name)” wants to read and change sites", lines)
            let texts = Set(matchPatterns.map(\.string))
            recordGrants(id, spaceID: spaceID) { grants in
                if allowed { grants.patterns.formUnion(texts); grants.deniedPatterns.subtract(texts) } else { grants.deniedPatterns.formUnion(texts) }
            }
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsVersion += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let spaceID = spaceID(of: controller), let id = extensionID(of: context, in: spaceID),
              let popover = action.popupPopover else {
            return completionHandler(Self.failure("The popup can't be shown."))
        }
        if let anchor = anchors[id]?.view, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = state?.mainWindow?.contentView, state?.mainWindow?.isVisible == true {
            // Opened by the extension itself (no click on its button): below the address row.
            let point = NSRect(x: CGFloat(state?.sidebarWidth ?? 260) - 40, y: content.bounds.maxY - 70, width: 1, height: 1)
            popover.show(relativeTo: point, of: content, preferredEdge: .maxY)
        } else {
            return completionHandler(Self.failure("The popup can't be shown."))
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        replyHandler(nil, Self.failure("Singularity has no native messaging."))
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(Self.failure("Singularity has no native messaging."))
    }
}
