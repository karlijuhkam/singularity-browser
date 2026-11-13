import Foundation
import Observation
import SingularityCore

/// One folder in `~/Singularity/plugins/`, as Settings → Plugins shows it.
struct InstalledPlugin: Identifiable {
    /// The folder name (a valid manifest's id equals it).
    let id: String
    var folder: URL
    var manifest: Result<PluginManifest, PluginError>
    var status: PluginStatus
    var approval: PluginApproval?
    /// The last 200 log lines, oldest first ("10:42:07 info: started").
    var logs: [String] = []
    /// Whether it should be running now, and if not, why.
    var decision: PluginLaunch.Decision = .notApproved
    /// The background process's state (`.stopped` when there is none).
    var runState: PluginSupervisor.State = .stopped
    /// The latest scan's fingerprint and per-file hashes (nil when the files couldn't be read).
    /// Page scripts are prepared from exactly these files (`PluginScripts`).
    var snapshot: PluginFingerprint.Snapshot?
    /// Why the page script isn't in pages (it couldn't be prepared), for Settings → Plugins.
    var pageProblem: String?

    var validManifest: PluginManifest? {
        if case .success(let m) = manifest { return m }
        return nil
    }

    /// The status line ("On", "Waiting for your approval", "Problem: …").
    var statusLine: (text: String, tone: PluginStatusText.Tone) {
        PluginStatusText.describe(status: status, decision: decision, run: runState)
    }

    var needsReview: Bool {
        PluginStatusText.needsReview(status: status, decision: decision, run: runState, hasPageProblem: pageProblem != nil)
    }
}

/// Problems `PluginManager` reports to the UI, as plain sentences.
enum PluginManagerError: LocalizedError, Equatable {
    case changedWhileReviewing
    case notInstalled(String)
    case commandsNotFound([String])
    case commandMoved(name: String, path: String)
    case couldNotSave(String)
    case addFailed(PluginInstaller.AddError)
    case removeFailed(String)
    /// `bun install` failed; the text is one plain sentence (Bun's output is in the plugin's log).
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .changedWhileReviewing: return "The plugin changed while you were reviewing it. This is the current version."
        case .notInstalled(let id): return "There is no plugin “\(id)” any more."
        case .commandsNotFound(let names): return "Can't find \(names.joined(separator: ", ")) on this Mac. Install it, then review again."
        case let .commandMoved(name, path): return "\(name) isn't at \(path) any more. Review again."
        case .couldNotSave(let why): return "Couldn't save the approval: \(why)"
        case .addFailed(let error): return error.userMessage
        case .removeFailed(let why): return "Couldn't move the plugin to the Trash: \(why)"
        case .installFailed(let why): return "Not approved. \(why)"
        }
    }
}

/// Finds the plugins in `~/Singularity/plugins/`, keeps their approvals (`plugins-state.json`),
/// runs the approved ones (one `PluginSupervisor` each), watches their files, and routes page
/// messages to them (`send`, used by page scripts in Task 8).
///
/// Threading: everything here lives on the main actor. Slow work (reading every file for the
/// fingerprint, finding command paths through the login shell, copying, trashing) runs in
/// detached tasks, and the supervisors' callbacks hop back to the main thread.
/// Operations on one plugin (refresh, approve, remove) run one after another through `enqueue`,
/// and file-change events are debounced per plugin, so a burst of edits can't cause overlapping
/// restarts.
///
/// When a plugin runs: its status is `.approved`, it is on in at least one Space or has a panel
/// (a panel belongs to no Space), and every command path pinned at approval is still an executable
/// file and not a refused program (`PluginLaunch.decide`). That is
/// checked again, with a fresh fingerprint, right before every launch, crash restarts included
/// (inside the supervisor's `makeProcess`). A file can still change between that scan and Bun
/// reading it; that gap can't be closed from outside, and the file watcher catches the change
/// and pauses (or, in development mode, restarts) the plugin right after.
///
/// A plugin's own page (`panel.page`, see `pageHost(for:)`) exists only while its background runs,
/// so only the files of an approved, unchanged plugin (or one in development mode) are ever served.
@MainActor
@Observable
final class PluginManager {
    /// Sorted by id.
    private(set) var plugins: [InstalledPlugin] = [] {
        didSet { onChange?() }
    }
    /// Called after any change to `plugins` (status, approval, Spaces, files, logs, …). The page
    /// scripts (`PluginScripts`) follow the plugins through this.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Shown at the top of Settings → Plugins when the saved approvals couldn't be read.
    private(set) var stateWarning: String?

    /// How long `send` waits for a plugin's answer. Longer than a command's 60 s limit, because a
    /// page action may run `op`, which can wait for Touch ID.
    static let requestTimeout: Duration = .seconds(75)
    static let keptLogLines = 200

    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let runtime: URL
    @ObservationIgnored private let host: URL
    @ObservationIgnored private let store: PluginStateStore
    /// Plugin id -> approval, as saved in plugins-state.json. Change it through `setApproval`.
    @ObservationIgnored private var approvals: [String: PluginApproval]
    /// The same approvals, readable from the supervisors' background threads.
    @ObservationIgnored private let launchApprovals = LockedApprovals()
    @ObservationIgnored private var supervisors: [String: PluginSupervisor] = [:]
    /// The latest scan of each plugin folder (manifest + file hashes).
    @ObservationIgnored private var scans: [String: PluginScan] = [:]
    /// What the approval sheet currently shows, per plugin (see `prepareReview` / `approve`).
    @ObservationIgnored private var reviews: [String: PluginReview] = [:]
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var debounces: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var watcher: ArtifactWatcher?
    @ObservationIgnored private var pendingRequests: [Int: PendingRequest] = [:]
    @ObservationIgnored private var nextRequestID = 1
    /// Set when the app quits: nothing is launched after that.
    @ObservationIgnored private var terminated = false
    /// Whether plugins may start their programs, and the environment those get.
    @ObservationIgnored private let programs: ProgramLaunchSettings
    /// Each panel plugin's page, while its background runs (`pageHost(for:)`). Ignored by
    /// Observation: a view that shows a page also reads the plugin's row (through `pageHost`), and
    /// the row changes whenever a page is torn down.
    @ObservationIgnored private var pageHosts: [String: PluginPageHost] = [:]

    private struct PendingRequest {
        let pluginID: String
        let continuation: CheckedContinuation<JSONValue?, Never>
        /// Answers nil after `requestTimeout`; cancelled when the request finishes first.
        let timeout: Task<Void, Never>
    }

    /// - Parameters:
    ///   - paths: where `plugins/`, `plugins-data/` and `plugins-state.json` live (tests: a temp folder).
    ///   - runtime: the Bun executable (`Contents/Helpers/bun` in the app).
    ///   - host: `plugin-host/host.ts` (in the app's Resources).
    ///   - programs: what plugins' programs get (`ProgramLaunchSettings.live()` in the app).
    init(paths: Paths, runtime: URL, host: URL, programs: ProgramLaunchSettings = .live()) {
        self.paths = paths
        self.runtime = runtime
        self.host = host
        self.programs = programs
        self.store = PluginStateStore(file: paths.pluginStateFile)
        let loaded = store.loadSettingAsideCorrupt()
        self.approvals = loaded.approvals
        if loaded.wasCorrupt {
            stateWarning = "Saved approvals couldn't be read and were set aside; plugins need approving again."
        }
        launchApprovals.set(approvals)
    }

    func plugin(_ id: String) -> InstalledPlugin? {
        plugins.first { $0.id == id }
    }

    // MARK: - Discovery and watching

    /// Looks at every plugin folder (starting the approved ones) and watches the plugins folder.
    func start() {
        try? FileManager.default.createDirectory(at: paths.pluginsDirectory, withIntermediateDirectories: true)
        // Staging folders of installs that never finished (the app quit or crashed meanwhile).
        PluginPackages.removeLeftoverStaging(in: paths.pluginInstallDirectory)
        if watcher == nil {
            let watcher = ArtifactWatcher(root: paths.pluginsDirectory, includeFoldersAndHiddenFiles: true) { [weak self] changes in
                self?.filesChanged(changes.map(\.relativePath))
            }
            watcher.start()
            self.watcher = watcher
        }
        for id in Set(folderIDs()).union(plugins.map(\.id)).sorted() {
            enqueue(id) { [weak self] in await self?.refresh(id, filesChanged: false) }
        }
    }

    /// For app termination: kills every plugin process at once.
    func terminateAll() {
        terminated = true
        watcher?.stop()
        watcher = nil
        for supervisor in supervisors.values { supervisor.terminateNow() }
        supervisors = [:]
        for id in Array(pageHosts.keys) { tearDownPage(id) }
    }

    /// Folder names in the plugins folder that could be plugins (folders, and links so they can
    /// be shown as refused). Names starting with "." are ignored.
    private func folderIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.pluginsDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && isPluginFolder(paths.pluginsDirectory.appending(path: $0)) }
    }

    private func isPluginFolder(_ url: URL) -> Bool {
        // attributesOfItem doesn't follow links: a link reports itself.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeDirectory || type == .typeSymbolicLink
    }

    /// FSEvents reported these paths (relative to the plugins folder; the first component is the
    /// plugin id). An empty list means events were dropped or couldn't be mapped: every plugin is
    /// looked at again (`PluginRefreshPlan`). Each affected plugin is refreshed 300 ms after its
    /// last event.
    private func filesChanged(_ relativePaths: [String]) {
        let ids = PluginRefreshPlan.ids(changedPaths: relativePaths, onDisk: Set(folderIDs()),
                                        known: Set(plugins.map(\.id)))
        for id in ids {
            debounces[id]?.cancel()
            debounces[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.debounces[id] = nil
                self.enqueue(id) { [weak self] in await self?.refresh(id, filesChanged: true) }
            }
        }
    }

    /// Runs `operation` after every operation already queued for this plugin has finished.
    @discardableResult
    private func enqueue<T: Sendable>(_ id: String,
                                      _ operation: @escaping @MainActor @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = queues[id]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        queues[id] = Task { @MainActor in _ = await task.result }
        return task
    }

    /// Re-reads one plugin folder and starts, keeps or stops its process to match.
    /// `filesChanged`: called because files changed; a running plugin whose files really changed
    /// is restarted (only possible while approved, i.e. in development mode).
    private func refresh(_ id: String, filesChanged: Bool) async {
        let folder = paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
        guard isPluginFolder(folder) else {
            // Gone (deleted or moved away): forget it, but keep its approval in case it comes back.
            stopSupervisor(id, reason: "its folder is gone")
            plugins.removeAll { $0.id == id }
            scans[id] = nil
            return
        }
        let scan = await Task.detached { PluginScan.scan(folder: folder) }.value
        let previous = scans[id]?.fingerprint
        await apply(scan, to: id, restart: filesChanged && scan.fingerprint != previous)
    }

    /// Records `scan`, works out the status, and starts or stops the plugin to match.
    private func apply(_ scan: PluginScan, to id: String, restart: Bool) async {
        scans[id] = scan
        let approval = approvals[id]
        let status = scan.status(approval: approval)
        let decision = PluginLaunch.decide(status: status, approval: approval, manifest: scan.validManifest)
        update(id) { plugin in
            plugin.folder = scan.folder
            plugin.manifest = scan.manifest
            plugin.status = status
            plugin.approval = approval
            plugin.decision = decision
            plugin.snapshot = scan.snapshot
        }
        guard decision == .launch else {
            stopSupervisor(id, reason: Self.stopReason(status: status, decision: decision))
            return
        }
        if restart, supervisors[id] != nil {
            appendLog(id, "info", "files changed; restarting")
            stopSupervisor(id, reason: nil)
        }
        if supervisors[id] == nil { await launch(id) }
    }

    private static func stopReason(status: PluginStatus, decision: PluginLaunch.Decision) -> String {
        switch decision {
        case .switchedOff: return "switched off in every Space"
        case .blocked(let why): return why
        default: return PluginStatusText.describe(status: status, decision: decision, run: .stopped).text.lowercased()
        }
    }

    /// Queues a refresh of one plugin (from outside an operation on it).
    private func refreshLater(_ id: String) {
        enqueue(id) { [weak self] in await self?.refresh(id, filesChanged: false) }
    }

    /// Re-applies the latest scan after an approval change (Spaces, development mode).
    private func reapply(_ id: String) {
        guard let scan = scans[id] else { return }
        // Update the row at once; starting or stopping happens in the plugin's queue.
        let approval = approvals[id]
        let status = scan.status(approval: approval)
        update(id) {
            $0.approval = approval
            $0.status = status
            $0.decision = PluginLaunch.decide(status: status, approval: approval, manifest: scan.validManifest)
            $0.snapshot = scan.snapshot
        }
        enqueue(id) { [weak self] in
            guard let self, let latest = self.scans[id] else { return }
            await self.apply(latest, to: id, restart: false)
        }
    }

    // MARK: - Running

    /// The supervisor's `makeProcess` refused to launch (see `launch`).
    private struct LaunchRefused: Error, CustomStringConvertible {
        let description: String
    }

    private func launch(_ id: String) async {
        guard !terminated else { return }
        let folder = paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
        let dataFolder = paths.pluginsDataDirectory(id)
        let runtime = runtime, host = host, approvals = launchApprovals, programs = programs
        // Asking the login shell for its PATH takes seconds: start now, so the plugin's first
        // program start doesn't wait for it (the answer is kept for the rest of the app run).
        if programs.allowed, scans[id]?.validManifest?.permissions.programs.isEmpty == false {
            Task.detached(priority: .utility) { _ = programs.loginPath() }
        }
        // The supervisor, for the callbacks below, which can only be set up once it exists.
        let ref = SupervisorRef()
        // Called for every launch, crash restarts included, on a background thread: re-checks the
        // plugin with a fresh scan and the current approval, and builds the process from that scan.
        let supervisor = PluginSupervisor { [weak self] in
            let scan = PluginScan.scan(folder: folder)
            let approval = approvals.get(id)
            let status = scan.status(approval: approval)
            let decision = PluginLaunch.decide(status: status, approval: approval, manifest: scan.validManifest)
            guard decision == .launch, let manifest = scan.validManifest, let approval else {
                // Let the row catch up with whatever changed.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshLater(id) } }
                throw LaunchRefused(description: "it changed or lost its approval just before starting")
            }
            try PluginInstaller.makeDataFolder(dataFolder)
            // The real policy and environment: PluginProcess's defaults refuse every program.
            let process = PluginProcess(manifest: manifest, folder: folder, dataFolder: dataFolder, runtime: runtime,
                                        host: host, commandPaths: approval.commandPaths,
                                        programsAllowed: programs.allowed,
                                        programEnvironment: programs.environment(allowed: manifest.permissions.programEnv))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processLaunching(id, ref) } }
            return process
        }
        ref.supervisor = supervisor
        // The callbacks come from background threads. DispatchQueue.main keeps them in order
        // (log lines must not be shuffled); `MainActor.assumeIsolated` tells the compiler we are
        // on the main thread now.
        supervisor.onLog = { [weak self] level, message in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendLog(id, level, message) } }
        }
        supervisor.onReply = { [weak self] requestID, payload in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRequest(requestID, pluginID: id, payload) } }
        }
        supervisor.onPanelPost = { [weak self, weak supervisor] payload in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let supervisor, self.supervisors[id] === supervisor else { return }
                    // Dropped when no page is open: the page asks for what it needs when it loads.
                    self.pageHosts[id]?.post(payload)
                }
            }
        }
        supervisor.onStateChange = { [weak self, weak supervisor] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let supervisor, self.supervisors[id] === supervisor else { return }
                    self.update(id) { $0.runState = state }
                    if state == .running { self.appendLog(id, "info", "started") }
                    if state != .running {
                        self.failRequests(of: id)
                        // Crashed for good or couldn't start: no background, so no page.
                        self.tearDownPage(id)
                    }
                }
            }
        }
        supervisors[id] = supervisor
        // start() runs makeProcess (which reads every file) synchronously: keep it off the main
        // thread, and wait for it so the next queued operation sees a started supervisor.
        await Task.detached { supervisor.start() }.value
    }

    /// A background process of the current supervisor is about to start (`makeProcess`). On a
    /// restart after a crash, the old process's requests can't be answered any more, and the page
    /// is loaded again so it starts over with the new process.
    private func processLaunching(_ id: String, _ ref: SupervisorRef) {
        guard let supervisor = ref.supervisor, supervisors[id] === supervisor else { return }
        ref.launches += 1
        guard ref.launches > 1 else { return }
        failRequests(of: id)
        pageHosts[id]?.reload()
    }

    /// Stops the plugin's background (for any reason: paused, changed, removed, re-approved,
    /// restarted in development mode) and tears its page down with it.
    private func stopSupervisor(_ id: String, reason: String?) {
        tearDownPage(id)
        guard let supervisor = supervisors.removeValue(forKey: id) else { return }
        supervisor.stop()
        update(id) { $0.runState = .stopped }
        failRequests(of: id)
        appendLog(id, "info", reason.map { "stopped: \($0)" } ?? "stopped")
    }

    // MARK: - Messages from pages (Task 8)

    /// Sends a page script's message to the plugin's background program and waits for its reply.
    /// nil at once when the plugin isn't running or isn't on in `space` (the Space of the tab the
    /// message came from; the caller knows it, so it is passed in rather than looked up here);
    /// nil after 75 s without a reply, or when the plugin stops meanwhile. Request ids increase
    /// per manager; replies with unknown or stale ids are ignored.
    func send(pluginID: String, tabID: UUID, space: UUID, frameHost: String, payload: JSONValue) async -> JSONValue? {
        guard let plugin = plugin(pluginID), plugin.status == .approved,
              plugin.approval?.enabledSpaces.contains(space) == true,
              let supervisor = supervisors[pluginID], supervisor.state == .running else { return nil }
        return await request(pluginID, supervisor) { requestID in
            .pageMessage(requestID: requestID, tabID: tabID, frameHost: frameHost, payload: payload)
        }
    }

    /// Sends a message from the plugin's own page (its panel or tab) to its background and waits
    /// for the reply, as `send` does for page scripts. No Space check: the page belongs to no
    /// Space, and it only exists while the plugin runs. The background sees it with tabID "panel".
    func sendFromPanel(pluginID: String, payload: JSONValue) async -> JSONValue? {
        guard let plugin = plugin(pluginID), plugin.status == .approved,
              let supervisor = supervisors[pluginID], supervisor.state == .running else { return nil }
        return await request(pluginID, supervisor) { requestID in
            .panelMessage(requestID: requestID, payload: payload)
        }
    }

    /// Sends `message(requestID)` to the plugin and waits for the `.reply` with that id; nil after
    /// `requestTimeout`, or when the plugin stops meanwhile.
    private func request(_ pluginID: String, _ supervisor: PluginSupervisor,
                         _ message: (Int) -> PluginWire) async -> JSONValue? {
        let requestID = nextRequestID
        nextRequestID += 1
        return await withCheckedContinuation { continuation in
            let timeout = Task { @MainActor [weak self] in
                // A cancelled sleep throws: then the request was already answered.
                guard (try? await Task.sleep(for: Self.requestTimeout)) != nil else { return }
                self?.finishRequest(requestID, pluginID: pluginID, nil)
            }
            pendingRequests[requestID] = PendingRequest(pluginID: pluginID, continuation: continuation, timeout: timeout)
            supervisor.send(message(requestID))
        }
    }

    /// Resumes the waiting `send` once; anything for an unknown id or another plugin is ignored.
    private func finishRequest(_ requestID: Int, pluginID: String, _ value: JSONValue?) {
        guard let request = pendingRequests[requestID], request.pluginID == pluginID else { return }
        pendingRequests[requestID] = nil
        request.timeout.cancel()
        request.continuation.resume(returning: value)
    }

    private func failRequests(of pluginID: String) {
        for (requestID, request) in pendingRequests where request.pluginID == pluginID {
            finishRequest(requestID, pluginID: pluginID, nil)
        }
    }

    // MARK: - A plugin's own page (panel or tab)

    /// Plugins with a valid manifest that has a `panel`, sorted by the panel's title.
    func panelPlugins() -> [InstalledPlugin] {
        plugins.filter { $0.validManifest?.panel != nil }.sorted {
            let (a, b) = ($0.validManifest?.panel?.title ?? "", $1.validManifest?.panel?.title ?? "")
            return a == b ? $0.id < $1.id : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// The panel's title from the plugin's manifest; nil when it has none (or isn't installed).
    func panelTitle(_ id: String) -> String? {
        plugin(id)?.validManifest?.panel?.title
    }

    /// Why there is no page for the plugin: its status line (`PluginStatusText.describe`), or
    /// "This plugin isn't installed." for an id with no folder.
    func notRunningReason(_ id: String) -> String {
        plugin(id)?.statusLine.text ?? "This plugin isn't installed."
    }

    /// The plugin's own page, while its background runs; nil otherwise (then show
    /// `notRunningReason`). Made on first use and kept: one page per plugin, wherever it is shown.
    /// It is torn down the moment the background stops for any reason, so the next call after a
    /// restart makes a new one; after a crash restart the same page is loaded again.
    ///
    /// The page server serves any file of the plugin's folder: tying the page to the running
    /// background is what keeps unapproved files from being served.
    func pageHost(for id: String) -> PluginPageHost? {
        // Reading the row (observed) lets a view that shows the page follow it.
        guard let plugin = plugin(id), plugin.status == .approved, plugin.runState == .running,
              let manifest = plugin.validManifest, manifest.panel != nil,
              let supervisor = supervisors[id], supervisor.state == .running else { return nil }
        if let host = pageHosts[id] { return host }
        let host = PluginPageHost(pluginID: id, folder: plugin.folder, manifest: manifest) { [weak self] payload in
            await self?.sendFromPanel(pluginID: id, payload: payload)
        }
        pageHosts[id] = host
        return host
    }

    private func tearDownPage(_ id: String) {
        pageHosts.removeValue(forKey: id)?.tearDown()
    }

    // MARK: - Approval

    /// Scans the plugin and finds its programs' paths (off the main thread) and remembers the
    /// result as what the approval sheet shows. `approve` only accepts exactly this.
    func prepareReview(_ id: String) async -> Result<PluginReview, PluginError> {
        let folder = paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
        let result = await Task.detached {
            let shell = LoginShell.path()
            // resolve() asks the login shell; it can take a few seconds per program.
            return PluginReview.prepare(scan: PluginScan.scan(folder: folder)) { CommandBroker.resolve($0, loginShell: shell) }
        }.value
        switch result {
        case .success(let review): reviews[id] = review
        case .failure: reviews[id] = nil
        }
        return result
    }

    /// Approves what the sheet showed (`prepareReview`), if it is still exactly that: the files are
    /// scanned again, and a different fingerprint or different permissions throw
    /// `.changedWhileReviewing` (the sheet then loads the current version). Pins the command paths
    /// the sheet showed, creates the data folder (0700), installs the plugin's npm packages
    /// (`installPackages`), records the fingerprint and per-file hashes *after* the install,
    /// saves, and starts the plugin.
    ///
    /// The install writes node_modules, so the file watcher reports the plugin as changed while it
    /// runs. Those events queue a refresh in this plugin's queue (`enqueue`), so it can only run
    /// after this approval has finished; by then the recorded fingerprint is the post-install one,
    /// the refresh's fresh scan matches it (status `.approved`), and as `scans[id]` already holds
    /// that same fingerprint it doesn't restart the plugin either.
    func approve(_ id: String, expectedFingerprint: String, enabledSpaces: Set<UUID>, developmentMode: Bool) async throws {
        try await enqueue(id) { [weak self] in
            try await self?.performApprove(id, expectedFingerprint: expectedFingerprint,
                                           enabledSpaces: enabledSpaces, developmentMode: developmentMode)
        }.value
    }

    private func performApprove(_ id: String, expectedFingerprint: String, enabledSpaces: Set<UUID>,
                                developmentMode: Bool) async throws {
        guard let review = reviews[id], review.fingerprint == expectedFingerprint else {
            throw PluginManagerError.changedWhileReviewing
        }
        let folder = paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
        guard isPluginFolder(folder) else { throw PluginManagerError.notInstalled(id) }
        guard review.missingCommands.isEmpty else { throw PluginManagerError.commandsNotFound(review.missingCommands) }
        let scan = await Task.detached { PluginScan.scan(folder: folder) }.value
        guard review.matches(scan), let manifest = scan.validManifest, case .success(let snapshot) = scan.files else {
            reviews[id] = nil
            await apply(scan, to: id, restart: false)
            throw PluginManagerError.changedWhileReviewing
        }
        for (name, path) in review.commandPaths.sorted(by: { $0.key < $1.key })
        where !PluginLaunch.isExecutableRegularFile(path) {
            throw PluginManagerError.commandMoved(name: name, path: path)
        }

        let dataFolder = paths.pluginsDataDirectory(id)
        try await Task.detached { try PluginInstaller.makeDataFolder(dataFolder) }.value

        // node_modules is part of the fingerprint, so the approval records the folder as it is
        // after installing (the check above compared the folder the sheet showed: before it).
        let (installed, installedSnapshot) = try await installPackages(id, folder: folder, review: review, before: scan,
                                                                       snapshot: snapshot)

        let approval = PluginApproval(
            fingerprint: installedSnapshot.fingerprint, permissions: manifest.permissions,
            commandPaths: review.commandPaths, enabledSpaces: enabledSpaces, developmentMode: developmentMode,
            approvedAt: Date(), fileHashes: installedSnapshot.fileHashes)
        try setApproval(id, approval)
        reviews[id] = nil
        appendLog(id, "info", "approved")
        // A process of an earlier approval (re-review while running) gives way to a fresh one.
        stopSupervisor(id, reason: nil)
        await apply(installed, to: id, restart: false)
    }

    /// Part of `performApprove` (so it runs inside the plugin's queue). Deletes any node_modules
    /// the plugin shipped and installs its declared packages with the bundled Bun, outside the
    /// sandbox (`PluginPackages.install`: exactly the package.json and bun.lock the sheet showed,
    /// in a staging folder; frozen lockfile, no install scripts, npm registry only, minimal
    /// environment, 180 s limit). Returns the scan of the folder afterwards.
    ///
    /// Nothing to do (no packages, no node_modules): returns `before` as it is. Otherwise the
    /// running process (if any) is stopped first, since its packages are about to be replaced.
    /// Throws `.installFailed` when the install fails (node_modules is then gone, nothing is
    /// recorded, and the plugin shows as changed until it is approved again), and
    /// `.changedWhileReviewing` when anything outside node_modules differs from what the sheet
    /// showed once the install is done (e.g. edited while it ran).
    private func installPackages(_ id: String, folder: URL, review: PluginReview, before: PluginScan,
                                 snapshot: PluginFingerprint.Snapshot) async throws -> (PluginScan, PluginFingerprint.Snapshot) {
        let shipsNodeModules = snapshot.fileHashes.keys.contains(where: PluginPackages.isInTopLevelNodeModules)
            || (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: "node_modules").path)) != nil
        guard !review.packages.packages.isEmpty || shipsNodeModules else { return (before, snapshot) }

        stopSupervisor(id, reason: "installing its packages")
        let count = review.packages.packages.count
        if count > 0 { appendLog(id, "info", "installing \(count) \(count == 1 ? "package" : "packages") with bun install") }
        let runtime = runtime
        let hostFolder = host.deletingLastPathComponent()
        let stagingRoot = paths.pluginInstallDirectory
        // install() deletes node_modules first, then runs Bun in a staging folder and moves the
        // result in; all of it off the main thread.
        // Only installs the package.json and bun.lock the sheet showed (same hashes).
        let expected = snapshot.fileHashes
        let result = await Task.detached {
            await PluginPackages.install(folder: folder, expectedFileHashes: expected, runtime: runtime,
                                         hostFolder: hostFolder, stagingRoot: stagingRoot)
        }.value
        // Bun's output, line by line, at most the last 100 lines.
        for line in result.output.split(whereSeparator: \.isNewline).suffix(100) {
            appendLog(id, result.succeeded ? "info" : "error", "bun install: " + line)
        }

        /// Leaves no unapproved packages behind, shows the plugin as it now is, and throws.
        func giveUp(_ error: PluginManagerError) async throws -> Never {
            _ = await Task.detached { PluginPackages.removeNodeModules(in: folder) }.value
            reviews[id] = nil
            await apply(await Task.detached { PluginScan.scan(folder: folder) }.value, to: id, restart: false)
            throw error
        }
        switch result.outcome {
        case .installed, .nothingToInstall: break
        case .filesChanged:
            appendLog(id, "warn", "not approved: its package.json or bun.lock changed during the review")
            try await giveUp(.changedWhileReviewing)
        case .failed:
            appendLog(id, "error", "not approved: \(result.message)")
            try await giveUp(.installFailed(result.message))
        }
        let after = await Task.detached { PluginScan.scan(folder: folder) }.value
        let installedSnapshot: PluginFingerprint.Snapshot
        switch after.files {
        case .success(let s): installedSnapshot = s
        case .failure(let error):
            // E.g. a package that contains a symbolic link.
            let message = "The installed packages can't be used: \(error.userMessage)."
            appendLog(id, "error", "not approved: \(message)")
            try await giveUp(.installFailed(message))
        }
        guard let manifest = after.validManifest, manifest.permissions == review.manifest.permissions,
              PluginPackages.sameOutsideNodeModules(snapshot.fileHashes, installedSnapshot.fileHashes) else {
            appendLog(id, "warn", "not approved: its files changed while its packages were installed")
            try await giveUp(.changedWhileReviewing)
        }
        if count > 0 { appendLog(id, "info", result.message.lowercased()) }
        return (after, installedSnapshot)
    }

    /// Switches a plugin on or off in one Space. Writes the approval; no new review needed.
    func setEnabled(_ id: String, space: UUID, _ on: Bool) {
        guard var approval = approvals[id] else { return }
        if on { approval.enabledSpaces.insert(space) } else { approval.enabledSpaces.remove(space) }
        saveQuietly(id, approval)
        reapply(id)
    }

    /// Development mode: while on, edited files restart the plugin instead of pausing it.
    /// Switching it on happens in the plugin's queue after a fresh scan, and only if the plugin is
    /// approved exactly as it is now (same fingerprint): otherwise it would run unreviewed changes.
    /// Switching it off pauses the plugin if its files differ from the approved ones.
    func setDevelopmentMode(_ id: String, _ on: Bool) {
        enqueue(id) { [weak self] in await self?.performSetDevelopmentMode(id, on) }
    }

    private func performSetDevelopmentMode(_ id: String, _ on: Bool) async {
        guard var approval = approvals[id], approval.developmentMode != on else { return }
        if on {
            let folder = paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
            let scan = await Task.detached { PluginScan.scan(folder: folder) }.value
            guard let current = approvals[id], scan.status(approval: current) == .approved,
                  scan.fingerprint == current.fingerprint else {
                appendLog(id, "warn", "development mode not switched on: the plugin changed since you approved it")
                await apply(scan, to: id, restart: false)
                return
            }
            scans[id] = scan
            approval = current
        }
        approval.developmentMode = on
        saveQuietly(id, approval)
        if let scan = scans[id] { await apply(scan, to: id, restart: false) }
    }

    /// A Space was deleted: it can't be in any plugin's list any more.
    func spaceRemoved(_ space: UUID) {
        for (id, var approval) in approvals where approval.enabledSpaces.contains(space) {
            approval.enabledSpaces.remove(space)
            saveQuietly(id, approval)
            reapply(id)
        }
    }

    /// Saves the state file with `approval` for `id` (nil removes it); the in-memory copy only
    /// changes when saving worked.
    private func setApproval(_ id: String, _ approval: PluginApproval?) throws {
        var next = approvals
        next[id] = approval
        do { try store.save(next) } catch { throw PluginManagerError.couldNotSave(error.localizedDescription) }
        approvals = next
        launchApprovals.set(next)
        update(id) { $0.approval = approval }
    }

    /// For switches in Settings: on a save error the change still applies for this session, and
    /// the error goes to the plugin's log.
    private func saveQuietly(_ id: String, _ approval: PluginApproval) {
        do {
            try setApproval(id, approval)
        } catch {
            approvals[id] = approval
            launchApprovals.set(approvals)
            appendLog(id, "error", error.localizedDescription)
        }
    }

    // MARK: - Adding and removing

    /// Copies a plugin folder into the plugins folder (see `PluginInstaller.add`) and returns its
    /// id. Async because copying (node_modules) can take a while; it runs off the main thread.
    func addPlugin(from folder: URL) async throws -> String {
        let pluginsDirectory = paths.pluginsDirectory
        let result = await Task.detached {
            Result { () throws(PluginInstaller.AddError) -> String in
                try PluginInstaller.add(from: folder, pluginsDirectory: pluginsDirectory)
            }
        }.value
        let id: String
        switch result {
        case .success(let value): id = value
        case .failure(let error): throw PluginManagerError.addFailed(error)
        }
        // Show it right away rather than waiting for the file watcher.
        try? await enqueue(id) { [weak self] in await self?.refresh(id, filesChanged: false) }.value
        return id
    }

    /// Stops the plugin, moves its folder and its data folder to the Trash, and forgets its
    /// approval. (The UI asks for confirmation first.)
    func remove(_ id: String) async throws {
        try await enqueue(id) { [weak self] in try await self?.performRemove(id) }.value
    }

    private func performRemove(_ id: String) async throws {
        debounces.removeValue(forKey: id)?.cancel()
        stopSupervisor(id, reason: "removed")
        let folder = paths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
        let dataFolder = paths.pluginsDataDirectory(id)
        // trashItem moves a link itself, never what it points to.
        func trash(_ url: URL) async throws {
            try await Task.detached {
                guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }.value
        }
        // Forget the approval first: if trashing fails half-way, nothing is left approved.
        try setApproval(id, nil)
        reviews[id] = nil
        do { try await trash(folder) } catch {
            // Still there, now unapproved: show it that way.
            if let scan = scans[id] { await apply(scan, to: id, restart: false) }
            throw PluginManagerError.removeFailed(error.localizedDescription)
        }
        plugins.removeAll { $0.id == id }
        scans[id] = nil
        do { try await trash(dataFolder) } catch {
            throw PluginManagerError.removeFailed("the plugin is gone, but its data folder could not be moved: \(error.localizedDescription)")
        }
    }

    // MARK: - Rows and logs

    /// Changes the row for `id`, creating it if needed (rows stay sorted by id).
    private func update(_ id: String, _ change: (inout InstalledPlugin) -> Void) {
        if let index = plugins.firstIndex(where: { $0.id == id }) {
            change(&plugins[index])
            return
        }
        guard let scan = scans[id] else { return }
        var plugin = InstalledPlugin(id: id, folder: scan.folder, manifest: scan.manifest,
                                     status: scan.status(approval: approvals[id]), approval: approvals[id],
                                     snapshot: scan.snapshot)
        change(&plugin)
        plugins.append(plugin)
        plugins.sort { $0.id < $1.id }
    }

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)

    /// A line in a plugin's log from elsewhere in the app (page scripts, the fill guard).
    /// Never pass page data or credentials.
    func log(_ id: String, _ level: String, _ message: String) {
        appendLog(id, level, message)
    }

    /// Records (or clears, with nil) why the plugin's page script isn't in pages. A new problem is
    /// also written to the log.
    func setPageProblem(_ id: String, _ problem: String?) {
        guard let plugin = plugin(id), plugin.pageProblem != problem else { return }
        update(id) { $0.pageProblem = problem }
        if let problem { appendLog(id, "error", "page script: \(problem)") }
    }

    private func appendLog(_ id: String, _ level: String, _ message: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        let text = PluginText.block(message, max: 1000)
        plugins[index].logs.append("\(Date().formatted(Self.timeFormat)) \(level): \(text)")
        let extra = plugins[index].logs.count - Self.keptLogLines
        if extra > 0 { plugins[index].logs.removeFirst(extra) }
    }
}

/// One supervisor, for its own `makeProcess` closure (which has to exist before the supervisor
/// does), and how many processes it has launched. `@unchecked Sendable`: only touched on the main
/// thread (set right after the supervisor is made; read in blocks queued on the main queue).
private final class SupervisorRef: @unchecked Sendable {
    weak var supervisor: PluginSupervisor?
    var launches = 0
}

/// What plugins' programs (`permissions.programs`) get: whether they may start at all, and the
/// environment the app builds for them (`ProgramEnvironment`). Nothing comes from the app's own
/// environment except through these fields.
struct ProgramLaunchSettings: Sendable {
    /// False in a test or development copy (`ProgramPolicy.spawnAllowed`).
    let allowed: Bool
    let home: String
    let user: String
    let tmpdir: String
    /// Singularity's version, for `CLAUDE_AGENT_SDK_CLIENT_APP`.
    let appVersion: String
    /// The login shell's PATH. May block for seconds the first time: never call on the main actor.
    let loginPath: @Sendable () -> String

    /// The real values: the user's home folder and name, the login shell's PATH (asked once per app
    /// run), the bundle's short version. `environment` is the app's own (it decides `allowed`).
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                     loginPath: @escaping @Sendable () -> String = { LoginShellPATH.value }) -> ProgramLaunchSettings {
        ProgramLaunchSettings(
            allowed: ProgramPolicy.spawnAllowed(environment: environment),
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            user: NSUserName(),
            tmpdir: NSTemporaryDirectory(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            loginPath: loginPath)
    }

    /// `PluginProcess`'s `programEnvironment` for a plugin whose manifest lists `names` in
    /// `programEnv`. Called on a background thread when a program starts.
    func environment(allowed names: [String]) -> @Sendable ([String: String]) -> [String: String] {
        { [self] requested in
            ProgramEnvironment.make(home: home, user: user, loginPath: loginPath(), tmpdir: tmpdir,
                                    appVersion: appVersion, requested: requested, allowed: names)
        }
    }
}

/// The PATH the user's login shell sets up, as a terminal tab would have it (a Dock-started app
/// gets a minimal one). Asked once per app run, when first read; a `static let` is set up once and
/// thread-safely, and other readers wait for it. Blocks up to ~5 s: never read on the main actor.
enum LoginShellPATH {
    static let value: String = CommandBroker.loginPath(loginShell: LoginShell.path()) ?? "/usr/bin:/bin:/usr/sbin:/sbin"
}

/// Plugin id -> approval behind a lock, for the supervisors' background threads.
/// `@unchecked Sendable`: `value` is only touched while holding `lock`.
private final class LockedApprovals: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: PluginApproval] = [:]
    func set(_ approvals: [String: PluginApproval]) { lock.withLock { value = approvals } }
    func get(_ id: String) -> PluginApproval? { lock.withLock { value[id] } }
}
