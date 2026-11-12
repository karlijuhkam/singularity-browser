import AppKit
import Darwin
import Observation
import SingularityCore
import SwiftTerm
import os

/// Visible with: log stream --predicate 'subsystem == "dev.roosa.Singularity"'
let terminalLog = Logger(subsystem: "dev.roosa.Singularity", category: "terminal")

/// One terminal tab: a SwiftTerm view running the user's login shell in a pseudo-terminal (PTY).
///
/// With "Run terminals through herdr-core" switched on (Settings → Terminal) the shell is a
/// herdr-core terminal instead, and the view runs `hc attach` to show it; see `HerdrCore` and
/// the "herdr-core" section below. Everything else (title, directory, colours) is the same.
///
/// The tab title follows what runs in it. Once a second we ask the PTY which process group is in
/// the foreground (the shell at its prompt, or e.g. `claude` while it runs), read that program's
/// name, and read the shell's current directory. No shell configuration is needed.
@MainActor
@Observable
final class TerminalSession {
    let tabID: UUID
    let spaceID: UUID
    @ObservationIgnored let view: SingularityTerminalView

    private(set) var isRunning = false
    /// Name of the program in the foreground, or nil while the shell sits at its prompt.
    private(set) var foregroundProgram: String?
    /// Becomes true once the shell has printed anything (normally its first prompt), i.e. it has
    /// finished reading its startup files and is ready for input.
    @ObservationIgnored private(set) var hasProducedOutput = false

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var isClosing = false
    /// Title set by the running program through an escape sequence, and the process group that set it.
    @ObservationIgnored private var programTitle: String?
    @ObservationIgnored private var programTitleGroup: pid_t?
    @ObservationIgnored private var lastDirectory: String?
    /// The Space's slug, exported to the shell as SINGULARITY_SPACE.
    private let spaceSlug: String
    /// The path of `hc` when this tab runs through herdr-core; nil for the built-in terminal.
    @ObservationIgnored private var herdrPath: String?
    /// The shell's process id as herdr-core reports it (the view's own child is `hc attach`).
    @ObservationIgnored private var herdrShellPID: pid_t?
    /// Keeps SwiftTerm sending us OSC sequences (notifications for the inbox); see `didStartProcess`.
    @ObservationIgnored private var oscObservation: TerminalOscObservation?

    /// - Parameter herdr: the installed `hc` to run the shell through, or nil for the built-in terminal.
    init(tabID: UUID, spaceID: UUID, spaceSlug: String, workingDirectory: String, font: NSFont, state: AppState?,
         herdr: String? = nil) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.spaceSlug = spaceSlug
        self.state = state
        self.herdrPath = herdr
        self.view = SingularityTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

        view.font = font
        // Black-on-white or white-on-black following the system appearance
        // (re-applied on every light/dark switch, see SingularityTerminalView).
        view.configureNativeColors()
        view.processDelegate = self
        view.onReturnAfterExit = { [weak self] in
            // Not while a shell is running or being started (herdr-core takes a moment).
            guard let self, !self.isRunning else { return }
            self.state?.restartTerminal(self.tabID, in: self.spaceID)
        }
        // The agent inbox: a bell may mean "waiting for you"; a click or a key in the terminal
        // means the owner went to it.
        view.onBell = { [weak self] in
            guard let self else { return }
            self.refresh() // a bell only counts with a program in front: know it now, not next poll
            self.inboxSignal(.bell)
        }
        view.onUserInput = { [weak self] in
            guard let self, !self.isClosing else { return }
            self.state?.inbox.wentToTerminal(self.tabID)
        }
        SingularityTerminalView.watchKeys()
        start(in: workingDirectory)
    }

    /// Waits until the shell has printed its first output (it is ready for input), at most `timeout`.
    func waitUntilReady(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !hasProducedOutput, isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Stops showing the terminal: hang up the view's process and stop polling.
    /// - Parameter endProgram: with herdr-core, also end the shell itself. True when the tab is
    ///   closed; false when the app quits or the tab re-attaches, so the shell lives on. The
    ///   built-in terminal's shell always ends with its view.
    func tearDown(endProgram: Bool = true) {
        isClosing = true
        pollTimer?.invalidate()
        pollTimer = nil
        if isRunning, view.process != nil { view.terminate() }
        view.removeFromSuperview()
        if endProgram, let herdrPath {
            let name = HerdrCore.terminalName(tabID: tabID)
            // Not tied to this object, which is on its way out.
            Task.detached { await Self.endHerdrTerminal(hc: herdrPath, name: name) }
        }
    }

    // MARK: - Starting the shell

    private func start(in workingDirectory: String) {
        let shell = LoginShell.path()
        var directory = HomePath.expand(workingDirectory)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) || !isDirectory.boolValue {
            directory = NSHomeDirectory()
        }
        lastDirectory = directory

        if let herdrPath {
            startThroughHerdr(hc: herdrPath, shell: shell, directory: directory)
        } else {
            startLoginShell(shell, directory: directory)
        }
    }

    /// The built-in terminal: the login shell is the view's own child process.
    private func startLoginShell(_ shell: String, directory: String) {
        // argv[0] starting with "-" makes the shell a *login* shell, exactly as Terminal.app
        // starts it. That way it reads ~/.zprofile and ~/.zshrc and gets your full PATH,
        // aliases and functions, even though GUI apps start with a minimal environment.
        view.startProcess(
            executable: shell,
            args: [],
            environment: Self.environment(shell: shell, spaceSlug: spaceSlug),
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory
        )
        didStartProcess()
    }

    /// Common to both engines, once the view has a process.
    private func didStartProcess() {
        isRunning = true

        // SwiftTerm calls this on its I/O thread after each batch of output. We only need the
        // first one, so we hop to the main thread once and then remove the handler.
        view.setProcessOutputHandler { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasProducedOutput else { return }
                self.hasProducedOutput = true
                self.view.setProcessOutputHandler(nil)
            }
        }

        // Terminal notifications for the inbox: OSC 777 (`notify;<title>;<body>`) and OSC 9 (text).
        // We observe rather than `registerOscHandler`: a registered handler replaces SwiftTerm's
        // own, and SwiftTerm's OSC 9 handler is what reads `9;4` progress reports. The observer
        // gets a copy of every OSC sequence on a private queue, after SwiftTerm handled it as
        // usual; we keep only notifications and hop to the main actor with them.
        if oscObservation == nil {
            oscObservation = view.observeOscEvents { [weak self] event in
                guard let signal = TerminalNotificationPayload.signal(code: event.code, payload: event.payload) else { return }
                Task { @MainActor in self?.inboxSignal(signal) }
            }
        }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timers scheduled from the main thread fire on the main thread.
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Hands a terminal signal to the inbox (not once the tab is closing: its entries are gone).
    private func inboxSignal(_ signal: TerminalSignal) {
        guard !isClosing else { return }
        state?.inbox.terminalSignal(signal, tabID: tabID, spaceID: spaceID, foregroundProgram: foregroundProgram)
    }

    // MARK: - herdr-core

    /// Finds the tab's herdr terminal (it is still there after a restart of the app) or starts
    /// one, then runs `hc attach` in the view. Any surprise falls back to the built-in terminal.
    private func startThroughHerdr(hc: String, shell: String, directory: String) {
        let name = HerdrCore.terminalName(tabID: tabID)
        let slug = spaceSlug
        isRunning = true // "starting": the tab isn't offered a new shell meanwhile
        Task { [weak self] in
            let outcome = await Self.prepareHerdrTerminal(hc: hc, name: name, directory: directory, spaceSlug: slug, shell: shell)
            guard let self, !self.isClosing else { return }
            switch outcome {
            case .success(let terminal):
                self.herdrShellPID = terminal.pid
                self.view.startProcess(
                    executable: hc,
                    args: HerdrCore.attachArguments(name: name),
                    environment: Self.environment(shell: shell, spaceSlug: slug),
                    execName: nil,
                    currentDirectory: directory
                )
                self.didStartProcess()
            case .failure(let problem):
                terminalLog.notice("tab \(self.tabID, privacy: .public): herdr-core not used: \(problem.message, privacy: .public)")
                self.herdrPath = nil
                self.view.feed(text: "\u{1b}[2m[herdr-core couldn't be used (\(problem.message)); this is the built-in terminal.]\u{1b}[0m\r\n")
                self.startLoginShell(shell, directory: directory)
            }
        }
    }

    private struct HerdrProblem: Error {
        let message: String
    }

    private static func hc(_ path: String, _ arguments: [String], timeout: Duration = .seconds(15)) async -> CommandResult {
        await CommandBroker.run(path: path, arguments: arguments, timeout: timeout)
    }

    /// The tab's live herdr terminal: the one from before, or a new one.
    private nonisolated static func prepareHerdrTerminal(hc path: String, name: String, directory: String, spaceSlug: String,
                                                         shell: String) async -> Result<HerdrCore.Terminal, HerdrProblem> {
        func get() async -> HerdrCore.Lookup {
            let result = await hc(path, ["get", name, "--json"])
            if result.timedOut { return .unreadable("hc didn't answer") }
            // Errors come as JSON too, on stdout or stderr depending on the version.
            return HerdrCore.parseGet(result.stdout.isEmpty ? result.stderr : result.stdout)
        }
        var lookup = await get()
        if case .found(let terminal) = lookup, terminal.state != .live {
            // The shell from last time has ended: clear it away and start afresh.
            _ = await hc(path, ["rm", name, "--json"])
            lookup = .missing
        }
        if lookup == .missing {
            let run = await hc(path, HerdrCore.runArguments(name: name, directory: directory, spaceSlug: spaceSlug, shell: shell))
            guard run.status == 0, !run.timedOut else {
                let said = HerdrCore.errorMessage(run.stdout) ?? HerdrCore.errorMessage(run.stderr)
                return .failure(HerdrProblem(message: said ?? (run.timedOut ? "hc run didn't answer" : "hc run failed")))
            }
            lookup = await get()
        }
        switch lookup {
        case .found(let terminal) where terminal.state == .live: return .success(terminal)
        case .found: return .failure(HerdrProblem(message: "the shell ended at once"))
        case .missing: return .failure(HerdrProblem(message: "hc lost the terminal it just started"))
        case .unreadable(let why): return .failure(HerdrProblem(message: why))
        }
    }

    /// The tab was closed: end the shell (`hc kill` hangs up, then escalates) and remove the
    /// finished terminal from herdr-core's list.
    private nonisolated static func endHerdrTerminal(hc path: String, name: String) async {
        _ = await hc(path, ["kill", name, "--json"])
        for _ in 0..<25 {
            let result = await hc(path, ["get", name, "--json"])
            switch HerdrCore.parseGet(result.stdout.isEmpty ? result.stderr : result.stdout) {
            case .found(let terminal) where terminal.state == .live:
                try? await Task.sleep(for: .milliseconds(200))
            case .found:
                _ = await hc(path, ["rm", name, "--json"])
                return
            case .missing, .unreadable:
                return
            }
        }
    }

    /// `hc attach` ended. Either the shell ended (then this is an ordinary exit), or only the
    /// view let go of it (the detach key, ctrl+\ by default, or herdr-core restarting).
    private func herdrAttachEnded(hc path: String) {
        let name = HerdrCore.terminalName(tabID: tabID)
        Task { [weak self] in
            let result = await Self.hc(path, ["get", name, "--json"])
            let lookup = HerdrCore.parseGet(result.stdout.isEmpty ? result.stderr : result.stdout)
            guard let self, !self.isClosing else { return }
            switch lookup {
            case .found(let terminal) where terminal.state == .live:
                self.view.feed(text: "\r\n\u{1b}[2m[Detached. The shell is still running in herdr-core. Press Return to show it again.]\u{1b}[0m\r\n")
            case .found(let terminal):
                _ = await Self.hc(path, ["rm", name, "--json"])
                guard !self.isClosing else { return }
                self.shellEnded(exitCode: terminal.exitCode)
            case .missing, .unreadable:
                self.shellEnded(exitCode: nil)
            }
        }
    }

    /// The app's own environment (which carries SSH_AUTH_SOCK, TMPDIR, …) plus terminal settings.
    private static func environment(shell: String, spaceSlug: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID"] {
            environment.removeValue(forKey: key)
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Singularity"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        environment["SHELL"] = shell
        // Tells agents running in this terminal which Space they are in, i.e. which
        // "<slug>.<tool>" MCP tools act on the browser around them.
        environment["SINGULARITY_SPACE"] = spaceSlug
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Title and directory

    /// Works out the foreground program, current directory and title, and passes them to AppState.
    private func refresh() {
        guard isRunning, let process = view.process else { return }
        // With herdr-core the view's child is `hc attach`; the shell is herdr-core's.
        let shellPID = herdrShellPID ?? process.shellPid
        let group = foregroundGroup()
        let isShellInForeground = group == nil || group == shellPID

        // A title belongs to the program that set it; forget it once that program is gone.
        if programTitleGroup != group {
            programTitle = nil
            programTitleGroup = nil
        }

        let program = isShellInForeground ? nil : group.flatMap { ProcessInspector.programName(pid: $0) }
        if program != foregroundProgram {
            terminalLog.notice("tab \(self.tabID, privacy: .public): foreground \(program ?? "<shell>", privacy: .public) (group \(group ?? -1), shell \(shellPID))")
            let backAtTheShell = foregroundProgram != nil && program == nil
            foregroundProgram = program
            // The agent (or whatever ran) is gone: its inbox entry and working count go too.
            if backAtTheShell { inboxSignal(.programExited) }
        }

        if let directory = ProcessInspector.currentDirectory(pid: shellPID) {
            lastDirectory = directory
        }

        let title = TerminalTitle.make(
            foregroundProgram: program,
            isShellInForeground: isShellInForeground,
            programTitle: programTitle,
            directory: lastDirectory
        )
        state?.terminalDidChange(
            tabID: tabID,
            spaceID: spaceID,
            title: title,
            workingDirectory: lastDirectory.map { HomePath.abbreviate($0) }
        )
    }

    /// The process group that has the keyboard: the shell at its prompt, or the program it runs.
    private func foregroundGroup() -> pid_t? {
        if let herdrShellPID { return ProcessInspector.foregroundProcessGroup(ofTerminalOf: herdrShellPID) }
        return view.process.flatMap { ProcessInspector.foregroundProcessGroup(ptyFileDescriptor: $0.childfd) }
    }

    /// The shell is gone: close the tab (a normal exit, if the setting says so) or say what happened.
    private func shellEnded(exitCode: Int32?) {
        if exitCode == 0, state?.settings.closeTerminalOnExit ?? true {
            // `exit` or Ctrl-D at the prompt: close the tab, like most terminals do.
            state?.closeTab(tabID, in: spaceID, confirmIfBusy: false)
        } else {
            let reason = exitCode == 0 ? "exited" : (exitCode.map { "exit code \($0)" } ?? "terminated by a signal")
            view.feed(text: "\r\n\u{1b}[2m[Process ended: \(reason). Press Return to start a new shell.]\u{1b}[0m\r\n")
        }
    }
}

// MARK: - SwiftTerm callbacks

// `@MainActor` conformance: SwiftTerm calls these on the main thread (see its docs), so we can
// touch our main-actor state directly.
extension TerminalSession: @MainActor LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// A program set the window title with an escape sequence (OSC 0/2).
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        programTitle = title
        programTitleGroup = foregroundGroup()
        refresh()
    }

    /// The shell reported its directory (OSC 7). We read the directory ourselves, so just refresh.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        refresh()
    }

    /// A program reported its state (OSC 7501): all of the tab's current records, `[]` when none
    /// are left. SwiftTerm has already decoded the base64 text and answered the program's
    /// start-up probe (`ESC ] 7501 ; ?`), without which Claude Code sends no records at all.
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        // SwiftTerm tidies the records when the shell ends and tells us after `processTerminated`;
        // leftovers ("done") of an ended shell must not make a new entry.
        guard isRunning else { return }
        let mapped = records.compactMap { record in
            StatusRecord(terminalID: record.id, state: record.state.rawValue, kind: record.kind?.rawValue,
                         app: record.effectiveApp ?? record.app, message: record.message)
        }
        inboxSignal(.status(mapped))
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        foregroundProgram = nil
        pollTimer?.invalidate()
        pollTimer = nil
        guard !isClosing else { return }
        inboxSignal(.programExited)

        if let herdrPath {
            herdrAttachEnded(hc: herdrPath)
        } else {
            shellEnded(exitCode: exitCode)
        }
    }
}

/// SwiftTerm's view, with a few additions: it follows light/dark mode, after the shell has
/// exited Return starts a new one, and it tells the session about bells and the owner's clicks
/// and keys (for the agent inbox).
final class SingularityTerminalView: LocalProcessTerminalView {
    var onReturnAfterExit: (() -> Void)?
    /// The program rang the bell (BEL). Main actor; a burst of bells arrives as one call.
    var onBell: (() -> Void)?
    /// The owner clicked or typed in the terminal.
    var onUserInput: (() -> Void)?
    /// True while a bell is on its way to the main actor. A lock, because SwiftTerm rings the bell
    /// from its I/O thread.
    private nonisolated let bellPending = OSAllocatedUnfairLock(initialState: false)

    /// SwiftTerm calls this on its I/O thread, for every BEL. Its own handling (sound or flash,
    /// debounced) goes on as before; we add one hop to the main actor per burst of bells.
    override nonisolated func bell(source: Terminal) {
        super.bell(source: source)
        let isFirst = bellPending.withLock { pending in
            defer { pending = true }
            return !pending
        }
        guard isFirst else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bellPending.withLock { $0 = false }
            self.onBell?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        super.mouseDown(with: event)
    }

    /// Keys: SwiftTerm's `keyDown` is `public`, not `open`, so a subclass in another module can't
    /// override it. Instead one app-wide "local monitor" (AppKit shows it every key press of this
    /// app before the window delivers it) tells the terminal that has the keyboard focus. The
    /// event itself goes on unchanged. Installed once, the first time a terminal is made.
    static func watchKeys() { _ = keyMonitor }

    private static let keyMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let window = event.window
        // Local monitors run on the main thread.
        MainActor.assumeIsolated {
            (window?.firstResponder as? SingularityTerminalView)?.onUserInput?()
        }
        return event
    }

    /// Light/dark mode changed. SwiftTerm turns the system colours into fixed RGB values when
    /// they are set, so we set them again. `performAsCurrentDrawingAppearance` makes the dynamic
    /// system colours (textColor, textBackgroundColor) resolve for this view's new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if process?.running == true {
            super.send(source: source, data: data)
        } else if data.contains(13) { // 13 = carriage return
            onReturnAfterExit?()
        }
    }
}
