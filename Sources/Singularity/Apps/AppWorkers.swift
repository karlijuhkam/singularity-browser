import Foundation
import SingularityCore

/// What happened to an app's Worker, reported to the app's state (`AppCenter`) for the panel.
enum AppWorkerEvent: Sendable {
    /// A new run began: hosts denied in the last run may be asked about again.
    case started
    /// The run ended; `error` is why it could not start or what killed it, nil for a normal stop.
    case stopped(error: String?)
    /// The Worker read `env.NAME` and the app has no key of that name.
    case unsetKey(String)
}

/// The Workers of one Space's apps: one sandboxed Bun process per app (`AppWorkerProcess`),
/// started at the first request that needs it and stopped when idle or when its files change.
///
/// An actor: requests arrive from the artifact server's tasks, file changes from the main actor,
/// and they must not start the same Worker twice.
actor AppWorkers {
    /// What the rest of the app supplies. Everything about hosts, keys and the inbox lives
    /// behind `keys` and `fetch` (see `AppCenter`), so this type knows only processes.
    struct Environment: Sendable {
        /// The bundled Bun and the folder with `app-host.ts`. Nil in a bare debug binary.
        var runtime: URL?
        var hostFolder: URL?
        /// The app's data folder (`spaces/<slug>/app-data/<app>`).
        var dataFolder: @Sendable (_ app: String) -> URL
        /// The app's keys, with fresh placeholders, for one run.
        var keys: @Sendable (_ app: String) async -> [AppKeyMaterial]
        /// Makes an outside request for a Worker (host check, the owner's approval, keys).
        /// `isLive`: whether the Worker that asked is still the app's running one, checked again
        /// after the owner answered a question (the answer may come long after the Worker went).
        var fetch: @Sendable (_ app: String, AppHTTPRequest, [AppKeyMaterial], _ isLive: @escaping @Sendable () -> Bool) async -> Result<AppHTTPResponse, AppFetchRefusal>
        var event: @Sendable (_ app: String, AppWorkerEvent) -> Void
        /// A Worker with no request for this long is stopped (it starts again when needed).
        var idleSeconds: TimeInterval = 600
        var limits = AppWorkerProcess.Limits()
    }

    /// One run of one app's Worker.
    private struct Run {
        let process: AppWorkerProcess
        let log: AppLog
        var lastUsed = Date()
        var inFlight = 0
    }

    private let root: URL
    private let environment: Environment
    private var runs: [String: Run] = [:]
    /// Starts in progress, so requests that arrive together share one.
    private var starting: [String: Task<Result<AppWorkerProcess, AppWorkerError>, Never>] = [:]
    /// Why an app's Worker could not start, kept until its files change: a page that polls a
    /// broken Worker must not start Bun (and write the same error) once per request.
    private var failures: [String: String] = [:]
    /// Counts an app's stops, so a start that was overtaken by a file change is not kept.
    private var generation: [String: Int] = [:]
    /// Processes this actor told to stop (a file changed, a restart), as opposed to ones that
    /// died by themselves. See the retry in `handle`.
    private var stoppedByUs: Set<ObjectIdentifier> = []
    private var idleTask: Task<Void, Never>?
    private var closed = false
    /// Every live process, reachable without waiting for the actor (app termination).
    private nonisolated let live = LiveProcesses()

    init(root: URL, environment: Environment) {
        self.root = root
        self.environment = environment
    }

    // MARK: - Requests

    /// Answers a request with the app's Worker, starting it first if needed. Never throws: what
    /// goes wrong becomes a plain-text error response the developer can read in the page or the
    /// network inspector.
    func handle(app: String, request: AppHTTPRequest) async -> AppHTTPResponse {
        let process: AppWorkerProcess
        switch await running(app) {
        case .success(let running): process = running
        case .failure(let error): return Self.response(for: error, app: app)
        }
        // Counted only on the run we were given (another may have taken its place already).
        if runs[app]?.process === process { runs[app]?.inFlight += 1 }
        defer {
            // The run may have been replaced meanwhile (a file changed): only count on our own.
            if runs[app]?.process === process {
                runs[app]?.inFlight -= 1
                runs[app]?.lastUsed = Date()
            }
        }
        do {
            return try await process.handle(request)
        } catch let error as AppWorkerError {
            // The Worker was stopped under this request because its files changed: the new code
            // answers it. Once only, and only for a Worker *we* stopped: one that died by itself
            // is an error (asking again could repeat a POST that crashed it).
            if error == .exited, stoppedByUs.contains(ObjectIdentifier(process)), !closed {
                if case .success(let fresh) = await running(app), let answer = try? await fresh.handle(request) {
                    return answer
                }
            }
            return Self.response(for: error, app: app)
        } catch {
            return .text(500, "The Worker failed: \(error.localizedDescription)")
        }
    }

    /// The app's running Worker, started now if there is none.
    private func running(_ app: String) async -> Result<AppWorkerProcess, AppWorkerError> {
        if let run = runs[app], run.process.isRunning { return .success(run.process) }
        if let pending = starting[app] { return await pending.value }
        guard !closed else { return .failure(.exited) }
        if let failure = failures[app] { return .failure(.failedToStart(failure)) }
        guard let runtime = environment.runtime, let hostFolder = environment.hostFolder,
              FileManager.default.isExecutableFile(atPath: runtime.path) else {
            return .failure(.failedToStart(Self.needsBundle))
        }

        let task = Task { () -> Result<AppWorkerProcess, AppWorkerError> in
            await self.start(app, runtime: runtime, hostFolder: hostFolder)
        }
        starting[app] = task
        let result = await task.value
        if starting[app] == task { starting[app] = nil }
        return result
    }

    private func start(_ app: String, runtime: URL, hostFolder: URL) async -> Result<AppWorkerProcess, AppWorkerError> {
        let environment = environment
        let startedAt = generation[app, default: 0]
        let materials = await environment.keys(app)
        let dataFolder = environment.dataFolder(app)
        let log = AppLog(file: dataFolder.appending(path: "worker.log"),
                         scrub: { AppKeySubstitution.scrubLog($0, keys: materials) })
        let process = AppWorkerProcess(appFolder: root.appending(path: app, directoryHint: .isDirectory),
                                       dataFolder: dataFolder, runtime: runtime, hostFolder: hostFolder,
                                       keys: AppKeySubstitution.environment(materials), limits: environment.limits)
        process.onLog = { level, text in log.append(level: level, text: text) }
        process.onFetch = { [weak process] request in
            await environment.fetch(app, request, materials) { [weak process] in process?.isLive ?? false }
        }
        process.onEnvRead = { name in environment.event(app, .unsetKey(name)) }
        process.onExit = { [weak self, weak process] in
            guard let self, let process else { return }
            Task { await self.ended(app, process) }
        }

        environment.event(app, .started)
        live.add(process)   // from now on a quit kills it, also while it is still starting
        do {
            try await process.start()
        } catch {
            let message: String
            switch error {
            case AppWorkerError.failedToStart(let text): message = text
            case AppWorkerError.timedOut: message = "The Worker was not ready in \(Int(environment.limits.start)) seconds."
            default: message = error.localizedDescription
            }
            log.append(level: "error", text: "The Worker could not start: \(message)")
            environment.event(app, .stopped(error: message))
            process.terminateNow()
            live.remove(process)   // it may never have launched, so no exit will report it
            // Files changed while it was starting: the failure may be about the old ones.
            if generation[app, default: 0] == startedAt { failures[app] = message }
            return .failure(.failedToStart(message))
        }
        guard !closed else {
            process.terminateNow()
            return .failure(.exited)
        }
        // A file changed while it was starting: it may have read the old code. Start again.
        guard generation[app, default: 0] == startedAt else {
            process.terminateNow()
            return await start(app, runtime: runtime, hostFolder: hostFolder)
        }
        runs[app] = Run(process: process, log: log)
        scheduleIdleCheck()
        return .success(process)
    }

    /// A process is gone (stopped by us, killed for hanging, or crashed).
    private func ended(_ app: String, _ process: AppWorkerProcess) {
        live.remove(process)
        // Kept until here so every request that was inside it can see "we stopped it".
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.forgetStopped(ObjectIdentifier(process))
        }
        guard runs[app]?.process === process else { return }   // already replaced or removed
        runs[app] = nil
        environment.event(app, .stopped(error: nil))
    }

    // MARK: - Changes

    /// Files in the artifacts folder changed (paths relative to it). An app whose files changed
    /// runs old code: its Worker is stopped, and the next request starts the new one. An app
    /// whose manifest or migrations changed is started right away, so its database exists (with
    /// its tables) before any request: an agent can write rows as soon as it wrote the files.
    func filesChanged(_ relativePaths: [String]) async {
        var changed = Set<String>()
        var startNow = Set<String>()
        for path in relativePaths {
            // The app the file is in. A removed manifest makes its folder "no app": then the
            // run we still have for that folder is the one to stop.
            let app = ArtifactApps.app(forArtifactPath: path, root: root)
                ?? runs.keys.filter { path.hasPrefix($0 + "/") }.max(by: { $0.count < $1.count })
            guard let app else { continue }
            changed.insert(app)
            let inside = String(path.dropFirst(app.count + 1))
            if ArtifactApps.manifestNames.contains(inside) || inside.hasPrefix("migrations/") { startNow.insert(app) }
        }
        for app in changed { stop(app) }
        for app in startNow where ArtifactApps.list(in: root).contains(app) { _ = await running(app) }
    }

    /// Starts the apps that have no data folder yet (copied in while the app was not running).
    func prepareNewApps() async {
        for app in ArtifactApps.list(in: root)
        where !FileManager.default.fileExists(atPath: environment.dataFolder(app).path) {
            _ = await running(app)
        }
    }

    private func forgetStopped(_ id: ObjectIdentifier) {
        stoppedByUs.remove(id)
    }

    /// Ends the app's Worker; the next request starts a new one (with the keys as they are then).
    func restart(app: String) {
        stop(app)
    }

    /// Kills the app's Worker and returns when it is gone: before its data folder is removed.
    func kill(app: String) async {
        generation[app, default: 0] += 1
        failures[app] = nil
        guard let run = runs.removeValue(forKey: app) else { return }
        stoppedByUs.insert(ObjectIdentifier(run.process))
        run.process.terminateNow()
        environment.event(app, .stopped(error: nil))
        for _ in 0..<100 where run.process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func stop(_ app: String) {
        generation[app, default: 0] += 1
        failures[app] = nil
        guard let run = runs.removeValue(forKey: app) else { return }
        // The host finishes what it is doing (`ctx.waitUntil` work, requests it is already
        // answering) and exits. A request that fails with `.exited` because of this is answered
        // once more by the new process (see `handle`).
        stoppedByUs.insert(ObjectIdentifier(run.process))
        run.process.stop()
        environment.event(app, .stopped(error: nil))
    }

    /// The Space's server is stopping, or the app quits: every Worker is killed at once.
    func stopAll() {
        closed = true
        idleTask?.cancel()
        idleTask = nil
        runs = [:]
        live.terminateAll()
    }

    /// For app termination, where nothing may wait for the actor: SIGKILL to every Worker, now.
    nonisolated func terminateAllNow() {
        live.terminateAll()
    }

    // MARK: - Idle

    private func scheduleIdleCheck() {
        guard idleTask == nil else { return }
        let interval = max(1, min(60, environment.idleSeconds / 4))
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, await self.stopIdle() else { return }
            }
        }
    }

    /// Stops Workers nobody has asked for a while. Returns false when none are left (the timer
    /// then ends; the next start makes a new one).
    private func stopIdle() -> Bool {
        let now = Date()
        for (app, run) in runs where run.inFlight == 0 && now.timeIntervalSince(run.lastUsed) >= environment.idleSeconds {
            stop(app)
        }
        if runs.isEmpty {
            idleTask = nil
            return false
        }
        return true
    }

    /// The processes that are running, behind a lock instead of the actor.
    private final class LiveProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: AppWorkerProcess] = [:]

        func add(_ process: AppWorkerProcess) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
        func remove(_ process: AppWorkerProcess) { lock.withLock { processes[ObjectIdentifier(process)] = nil } }
        func terminateAll() {
            let all = lock.withLock { () -> [AppWorkerProcess] in
                defer { processes = [:] }
                return Array(processes.values)
            }
            for process in all { process.terminateNow() }
        }
    }

    // MARK: - Errors as responses

    static let needsBundle = "Apps need the app bundle: this copy of Singularity has no Bun to run a Worker with."

    private static func response(for error: AppWorkerError, app: String) -> AppHTTPResponse {
        switch error {
        case .failedToStart(let message) where message == needsBundle:
            return .text(503, message)
        case .failedToStart(let message):
            return .text(500, "The Worker of “\(app)” could not start.\n\n\(message)")
        case .timedOut:
            return .text(504, "The Worker of “\(app)” did not answer in time and was stopped.")
        case .exited:
            return .text(502, "The Worker of “\(app)” stopped before it answered. See worker.log in the app's data folder.")
        case .tooLarge:
            return .text(413, "A request or response body of “\(app)” is over the 8 MB limit.")
        }
    }
}
