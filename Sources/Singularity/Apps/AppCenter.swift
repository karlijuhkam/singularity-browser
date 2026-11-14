import Foundation
import Observation
import SingularityCore

/// What the panel shows about one app's Worker.
struct AppWorkerStatus: Equatable, Sendable {
    var running = false
    /// Why it could not start or was stopped; nil when all is well.
    var lastError: String?
    /// Names the Worker read from `env` that have no key.
    var unsetKeys: [String] = []
}

/// An app the Space knows something about: its folder exists, or it has allowed hosts, keys or
/// data left (Settings → Data & privacy lists these, also after the folder is gone).
struct KnownApp: Equatable, Identifiable {
    var path: String
    var folderExists: Bool
    var hasRecord: Bool
    var hasData: Bool
    var id: String { path }
}

/// The app-wide state of apps (artifact folders with a Worker, see `ArtifactApps`): what the
/// owner allowed each one, its keys, what its Worker is doing, and the one decision point every
/// outside request of a Worker passes: `outbound`.
///
/// Owned by `AppState` (`state.apps`). Main actor: it reads and changes Spaces.
@MainActor
@Observable
final class AppCenter {
    @ObservationIgnored weak var state: AppState?
    /// Where key values live: the keychain, or a file in a copy with its own data folder.
    @ObservationIgnored let keyStore: AppKeyStore
    /// The bundled Bun and the folder with `app-host.ts`; nil in a bare debug binary.
    @ObservationIgnored private let runtime: URL?
    @ObservationIgnored private let hostFolder: URL?
    /// What "Delete data" does with an app's data folder (the Trash; tests remove it in place).
    @ObservationIgnored private let discardFolder: SpaceStore.DiscardFolder
    /// A Worker with no request for this long is stopped. Tests shorten it.
    @ObservationIgnored var idleSeconds: TimeInterval = 600
    @ObservationIgnored var limits = AppWorkerProcess.Limits()

    private struct AppID: Hashable {
        let space: UUID
        let app: String
    }
    private struct HostID: Hashable {
        let app: AppID
        let host: String
    }

    private var statuses: [AppID: AppWorkerStatus] = [:]
    /// One gate per run of a Worker: which hosts it may reach, which were denied in this run.
    private var gates: [AppID: AppHostGate] = [:]
    /// Requests waiting for the answer to a question another request already asked.
    @ObservationIgnored private var hostWaiters: [HostID: [CheckedContinuation<Bool, Never>]] = [:]

    init(keyStore: AppKeyStore, runtime: URL?, hostFolder: URL?, discardFolder: @escaping SpaceStore.DiscardFolder) {
        self.keyStore = keyStore
        self.runtime = runtime
        self.hostFolder = hostFolder
        self.discardFolder = discardFolder
    }

    // MARK: - Reading (the panel, Settings)

    func record(space: UUID, app: String) -> AppRecord {
        state?.space(space)?.apps[app] ?? AppRecord()
    }

    func status(space: UUID, app: String) -> AppWorkerStatus {
        statuses[AppID(space: space, app: app)] ?? AppWorkerStatus()
    }

    /// Hosts the owner said no to (or did not answer about) in the Worker's current run.
    func deniedHosts(space: UUID, app: String) -> [String] {
        gates[AppID(space: space, app: app)]?.deniedThisRun ?? []
    }

    /// The app an artifact tab's file belongs to, if any.
    func app(forArtifactPath path: String, space: UUID) -> String? {
        guard let root = artifactsRoot(space) else { return nil }
        return ArtifactApps.app(forArtifactPath: path, root: root)
    }

    func dataFolder(space: UUID, app: String) -> URL? {
        guard let state, let slug = state.space(space)?.slug else { return nil }
        return state.paths.appDataDirectory(slug, app: app)
    }

    /// The last lines of the app's `worker.log`.
    func logLines(space: UUID, app: String, count: Int = 30) -> [String] {
        guard let folder = dataFolder(space: space, app: app) else { return [] }
        return AppLog(file: folder.appending(path: "worker.log")).lastLines(count)
    }

    /// Every app the Space has a folder, a record or data for, sorted by path.
    func knownApps(space: UUID) -> [KnownApp] {
        guard let state, let current = state.space(space) else { return [] }
        let folders = Set(artifactsRoot(space).map(ArtifactApps.list(in:)) ?? [])
        let records = Set(current.apps.filter { !$0.value.isEmpty }.keys)
        let data = Set(Self.dataFolders(in: state.paths.appDataDirectory(current.slug)))
        return folders.union(records).union(data).sorted().map {
            KnownApp(path: $0, folderExists: folders.contains($0), hasRecord: records.contains($0), hasData: data.contains($0))
        }
    }

    /// The app paths that have a data folder: every folder under `app-data/` that directly
    /// holds a file (a database, the log). App paths can be nested ("tools/firma").
    private static func dataFolders(in root: URL) -> [String] {
        let rootPath = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found = Set<String>()
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let folder = file.deletingLastPathComponent().standardizedFileURL.path
            guard folder.hasPrefix(rootPath + "/") else { continue }
            var relative = String(folder.dropFirst(rootPath.count + 1))
            // Bun's own scratch folder is inside the data folder, not an app of its own.
            if relative.hasSuffix("/tmp") { relative = String(relative.dropLast(4)) } else if relative == "tmp" { continue }
            if ArtifactApps.isValidAppPath(relative) { found.insert(relative) }
        }
        return found.sorted()
    }

    private func artifactsRoot(_ space: UUID) -> URL? {
        guard let state, let slug = state.space(space)?.slug else { return nil }
        return state.paths.artifactsDirectory(slug)
    }

    // MARK: - The owner's changes (the panel, Settings)

    func allowHost(_ host: String, space: UUID, app: String) {
        guard AppHostRules.isValidHost(host), ArtifactApps.isValidAppPath(app) else { return }
        changeRecord(space: space, app: app) { record in
            if !record.hosts.contains(host) { record.hosts.append(host) }
        }
        syncGate(space: space, app: app)
    }

    func removeHost(_ host: String, space: UUID, app: String) {
        changeRecord(space: space, app: app) { $0.hosts.removeAll { $0 == host } }
        syncGate(space: space, app: app)
    }

    enum KeyError: Error, LocalizedError {
        case badName, badHost, noValue
        var errorDescription: String? {
            switch self {
            case .badName: return "A key's name is letters, digits and “_”, and does not start with a digit."
            case .badHost: return "The host is a name such as api.example.com: no “https://”, no path."
            case .noValue: return "Type the key's value."
            }
        }
    }

    /// Adds or changes a key. `value` nil keeps the stored value (changing only host or switch).
    /// The key's host is allowed for the app at the same time: a key for a host the app may not
    /// reach would do nothing.
    func setKey(name: String, host: String, readable: Bool, value: String?, space: UUID, app: String) throws {
        guard AppKeySubstitution.isValidName(name) else { throw KeyError.badName }
        guard AppHostRules.isValidHost(host) else { throw KeyError.badHost }
        guard ArtifactApps.isValidAppPath(app) else { return }
        if let value, !value.isEmpty {
            try keyStore.set(value, space: space, app: app, name: name)
        } else if keyStore.value(space: space, app: app, name: name) == nil {
            throw KeyError.noValue
        }
        changeRecord(space: space, app: app) { record in
            record.keys.removeAll { $0.name == name }
            record.keys.append(AppKey(name: name, host: host, readable: readable))
            record.keys.sort { $0.name < $1.name }
            if !record.hosts.contains(host) { record.hosts.append(host) }
        }
        syncGate(space: space, app: app)
        restart(space: space, app: app)   // the Worker's env is made when it starts
    }

    func deleteKey(name: String, space: UUID, app: String) {
        keyStore.delete(space: space, app: app, name: name)
        changeRecord(space: space, app: app) { $0.keys.removeAll { $0.name == name } }
        restart(space: space, app: app)
    }

    /// Forgets what the owner allowed the app: its hosts and its keys (values included).
    func forget(space: UUID, app: String) {
        keyStore.deleteAll(space: space, app: app)
        changeRecord(space: space, app: app) { $0 = AppRecord() }
        syncGate(space: space, app: app)
        restart(space: space, app: app)
    }

    /// Removes the app's data folder (its databases and log). The Worker is stopped first; if
    /// the app's folder still exists, the next request makes an empty database from its migrations.
    func deleteData(space: UUID, app: String) {
        guard let folder = dataFolder(space: space, app: app), ArtifactApps.isValidAppPath(app) else { return }
        restart(space: space, app: app)
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try discardFolder(folder) }
        } catch {
            NSLog("Singularity: could not remove the data of app \(app): \(error)")
        }
    }

    func restart(space: UUID, app: String) {
        guard let workers = state?.artifacts.host(space)?.apps else { return }
        Task { await workers.restart(app: app) }
    }

    /// The Space is being deleted: its keys go from the key store (its folder goes to the Trash
    /// with everything else, but keychain items would stay behind for good).
    func spaceWillBeDeleted(_ space: UUID) {
        keyStore.deleteAll(space: space, app: nil)
        statuses = statuses.filter { $0.key.space != space }
        gates = gates.filter { $0.key.space != space }
    }

    private func changeRecord(space: UUID, app: String, _ change: (inout AppRecord) -> Void) {
        state?.changeApps(space) { current in
            var record = current.apps[app] ?? AppRecord()
            change(&record)
            // Apps with nothing allowed are not listed.
            current.apps[app] = record.isEmpty ? nil : record
        }
    }

    /// The running Worker's gate follows the record at once (no restart needed for hosts).
    private func syncGate(space: UUID, app: String) {
        let id = AppID(space: space, app: app)
        gates[id]?.setAllowed(Set(record(space: space, app: app).hosts))
    }

    // MARK: - What a Space's Workers need

    /// The closures a Space's `AppWorkers` call back with. They are called from the Workers'
    /// own tasks, so each one hops to the main actor first.
    func environment(for space: Space) -> AppWorkers.Environment? {
        guard let state else { return nil }
        let spaceID = space.id
        let dataRoot = state.paths.appDataDirectory(space.slug)
        return AppWorkers.Environment(
            runtime: runtime, hostFolder: hostFolder,
            dataFolder: { app in dataRoot.appending(path: app, directoryHint: .isDirectory) },
            keys: { [weak self] app in await self?.keyMaterials(space: spaceID, app: app) ?? [] },
            fetch: { [weak self] app, request, keys in
                guard let self else { return .failure(AppFetchRefusal("Singularity is quitting.")) }
                return await self.outbound(space: spaceID, app: app, request: request, keys: keys)
            },
            event: { [weak self] app, event in
                Task { @MainActor in self?.workerEvent(event, space: spaceID, app: app) }
            },
            idleSeconds: idleSeconds, limits: limits)
    }

    /// The app's keys for one run of its Worker, each with a new placeholder. A key whose value
    /// is gone from the store (deleted in Keychain Access) is left out: the Worker then reads
    /// nothing under that name, and the panel says "not set".
    private func keyMaterials(space: UUID, app: String) -> [AppKeyMaterial] {
        record(space: space, app: app).keys.compactMap { key in
            guard let value = keyStore.value(space: space, app: app, name: key.name), !value.isEmpty else { return nil }
            return AppKeyMaterial(name: key.name, host: key.host, value: value,
                                  placeholder: AppKeySubstitution.makePlaceholder(), readable: key.readable)
        }
    }

    private func workerEvent(_ event: AppWorkerEvent, space: UUID, app: String) {
        let id = AppID(space: space, app: app)
        switch event {
        case .started:
            statuses[id] = AppWorkerStatus(running: true)
            // A new run: hosts denied in the last one may be asked about again.
            gates[id] = AppHostGate(allowed: Set(record(space: space, app: app).hosts))
        case .stopped(let error):
            var status = statuses[id] ?? AppWorkerStatus()
            status.running = false
            if let error { status.lastError = error }
            statuses[id] = status
        case .unsetKey(let name):
            var status = statuses[id] ?? AppWorkerStatus()
            if !status.unsetKeys.contains(name) { status.unsetKeys.append(name) }
            statuses[id] = status
        }
    }

    // MARK: - Outside requests

    /// Every outside request of every Worker comes through here: is the address one an app may
    /// fetch at all, did the owner allow the host for this app (asking in the inbox if it is
    /// new), and then the request itself, with keys put in (`AppOutbound`).
    ///
    /// The Space's agent policy has no say: that is about agents acting in the browser. A new
    /// host always asks, whatever the policy.
    func outbound(space: UUID, app: String, request: AppHTTPRequest, keys: [AppKeyMaterial]) async -> Result<AppHTTPResponse, AppFetchRefusal> {
        let host: String
        switch AppHostRules.target(of: request.url) {
        case .success(let target): host = target
        case .failure(let refusal): return .failure(refusal)
        }
        guard await mayReach(host, space: space, app: app) else {
            return .failure(AppFetchRefusal("\(host) is not allowed for this app. The owner can allow it in the app's panel (the button at the right of the address row)."))
        }
        return await AppOutbound.perform(request, keys: keys) { [weak self] redirectHost in
            // A redirect never asks: only hosts already allowed.
            await self?.record(space: space, app: app).hosts.contains(redirectHost) ?? false
        }
    }

    private func mayReach(_ host: String, space: UUID, app: String) async -> Bool {
        let id = AppID(space: space, app: app)
        if gates[id] == nil { gates[id] = AppHostGate(allowed: Set(record(space: space, app: app).hosts)) }
        switch gates[id]!.decide(host) {
        case .allow:
            return true
        case .refuse:
            return false
        case .joinWaiting:
            return await withCheckedContinuation { hostWaiters[HostID(app: id, host: host), default: []].append($0) }
        case .ask:
            let allowed = await askOwner(host: host, space: space, app: app)
            if allowed { allowHost(host, space: space, app: app) }
            gates[id]?.answered(host, allowed: allowed)
            for waiter in hostWaiters.removeValue(forKey: HostID(app: id, host: host)) ?? [] { waiter.resume(returning: allowed) }
            return allowed
        }
    }

    /// Puts "<app> wants to connect to <host>" in the inbox and waits for Allow, Deny or the
    /// timeout. The inbox's own safeguards apply as for any approval (never a default button,
    /// the click lockout, at most 5 waiting per Space).
    private func askOwner(host: String, space: UUID, app: String) async -> Bool {
        guard let state, let current = state.space(space) else { return false }
        let request = AgentApprovals.Request(
            actor: "The app “\(app)”", action: "connect to", detail: host, url: nil,
            spaceName: current.name, tabTitle: nil, text: nil,
            note: "Its Worker may then send requests to this host, until you remove it in the app's panel.")
        let pending = AgentApprovals.PendingApproval(
            request: request, spaceID: space, siteOrigin: nil,
            timeout: .seconds(max(5, state.settings.agentApprovalTimeoutSeconds)),
            // Allowed meanwhile in the panel: the question answers itself.
            passesNow: { [weak self] in self?.record(space: space, app: app).hosts.contains(host) ?? false })
        let outcome = await state.inbox.requestApproval(pending)
        // The Space or the app's folder may be gone by the time the owner answers: then no.
        guard state.space(space) != nil, let root = artifactsRoot(space), ArtifactApps.list(in: root).contains(app) else {
            return false
        }
        switch outcome {
        case .approved, .auto: return true
        case .approvedSite, .denied, .timedOut, .cancelled, .refused: return false
        }
    }
}
