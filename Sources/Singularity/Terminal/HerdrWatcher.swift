import Foundation
import Observation
import SingularityCore

/// Listens to herdr-core for the terminals under each terminal tab (a Bot's workers and the
/// like; spec `docs/superpowers/specs/2026-11-16-herdr-child-terminals-design.md`).
///
/// It runs one `hc events --json`: a line with every terminal, then a line per change. Core's
/// `HerdrFacts` turns the lines into the picture the sidebar draws. Nothing is saved, and the
/// process is the owner's own installed `hc`, only ever reading.
///
/// If the process ends (herdr-core restarting, `hc` updated) it is started again after 2 s, then
/// 4, 8 … up to 60 s. Rows are kept for 10 s without it and then removed: a stale row would
/// offer a terminal that may be gone.
@MainActor
@Observable
final class HerdrWatcher {
    @ObservationIgnored weak var state: AppState?
    private(set) var facts = HerdrFacts()
    /// Tabs whose child rows the owner folded away. In memory only.
    var collapsed: Set<UUID> = []

    @ObservationIgnored private var process: Process?
    /// Goes up with every start and stop, so a line or an exit of an older process is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartDelay = HerdrWatcher.firstRestartDelay
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var staleTask: Task<Void, Never>?

    static let firstRestartDelay: Duration = .seconds(2)
    static let longestRestartDelay: Duration = .seconds(60)
    static let staleAfter: Duration = .seconds(10)

    /// The rows under a terminal tab (none for a tab that doesn't run through herdr-core).
    func children(of tabID: UUID) -> HerdrChildren {
        facts.children(ofTerminalNamed: HerdrCore.terminalName(tabID: tabID))
    }

    // MARK: - Lines

    /// One line from `hc events --json`. Tests call this directly; no test runs `hc`.
    func feed(line: String) {
        var updated = facts
        switch updated.apply(line: line) {
        case .changed:
            facts = updated
            heardFromCore()
            state?.herdrFactsChanged()
        case .unchanged:
            heardFromCore()
        case .resync:
            // herdr-core says we fell behind: listen again from a full picture.
            if process != nil { restart(after: .zero) }
        case .skipped:
            // Never the line itself: it can carry anything a program put in a title.
            terminalLog.notice("herdr watcher: a line was not understood (\(line.utf8.count) bytes)")
        }
    }

    private func heardFromCore() {
        restartDelay = Self.firstRestartDelay
        staleTask?.cancel()
        staleTask = nil
    }

    // MARK: - The process

    /// May the listener run? Only with the setting on and a terminal tab to hang rows under. A
    /// test or development copy (`SINGULARITY_HOME`) listens only to a herdr core of its own
    /// (`HC_SESSION`), never to the owner's real terminals.
    nonisolated static func mayRun(herdrOn: Bool, hasTerminalTab: Bool, environment: [String: String]) -> Bool {
        guard herdrOn, hasTerminalTab else { return false }
        let ownDataFolder = !(environment["SINGULARITY_HOME"] ?? "").isEmpty
        return !ownDataFolder || !(environment["HC_SESSION"] ?? "").isEmpty
    }

    /// Starts or stops the listener to match the settings and tabs. Cheap; call it freely.
    func updateRunning() {
        guard let state else { return }
        let wanted = Self.mayRun(herdrOn: state.settings.terminalUsesHerdrCore,
                                 hasTerminalTab: state.spaces.contains { $0.tabs.contains(where: \.isTerminal) },
                                 environment: ProcessInfo.processInfo.environment)
        if !wanted {
            stop()
        } else if process == nil, restartTask == nil {
            start()
        }
    }

    /// Ends the listener and forgets every row.
    func stop() {
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        staleTask?.cancel()
        staleTask = nil
        endProcess()
        clearFacts()
    }

    private func endProcess() {
        guard let process else { return }
        self.process = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func clearFacts() {
        guard !facts.terminals.isEmpty else { return }
        facts.clear()
        state?.herdrFactsChanged()
    }

    private func start() {
        guard let hc = HerdrCore.locate() else { return }
        generation += 1
        let generation = generation
        let process = Process()
        process.executableURL = URL(filePath: hc)
        process.arguments = ["events", "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        // The pipe's handler runs on a background queue: it cuts the bytes into lines there and
        // hands each line to the main actor.
        let lines = LineCutter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty means the process closed its end; without this the handler would keep firing.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let complete = lines.add(data)
            guard !complete.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                for line in complete { self.feed(line: line) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.processEnded()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            terminalLog.notice("herdr watcher: hc events didn't start: \(error.localizedDescription, privacy: .public)")
            processEnded()
        }
    }

    /// The listener ended by itself: try again later, and drop the rows if that takes long.
    private func processEnded() {
        endProcess()
        if staleTask == nil, !facts.terminals.isEmpty {
            staleTask = Task { [weak self] in
                try? await Task.sleep(for: Self.staleAfter)
                guard !Task.isCancelled, let self else { return }
                self.staleTask = nil
                self.clearFacts()
            }
        }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.longestRestartDelay)
        restart(after: delay)
    }

    private func restart(after delay: Duration) {
        generation += 1
        endProcess()
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.updateRunning()
        }
    }
}

/// Cuts a stream of bytes into lines. Used from the pipe's background queue only, one call at a
/// time (a pipe's readability handler is never called concurrently with itself).
private final class LineCutter: @unchecked Sendable {
    private var buffer = Data()

    func add(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        // A line that never ends must not grow without limit (a full picture of many terminals
        // is well under this).
        if buffer.count > 16 * 1024 * 1024 { buffer.removeAll() }
        return lines
    }
}
