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

    init(tabID: UUID, spaceID: UUID, spaceSlug: String, workingDirectory: String, state: AppState?) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.spaceSlug = spaceSlug
        self.state = state
        self.view = SingularityTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // Black-on-white or white-on-black following the system appearance
        // (re-applied on every light/dark switch, see SingularityTerminalView).
        view.configureNativeColors()
        view.processDelegate = self
        view.onReturnAfterExit = { [weak self] in
            guard let self else { return }
            self.state?.restartTerminal(self.tabID, in: self.spaceID)
        }
        start(in: workingDirectory)
    }

    /// Waits until the shell has printed its first output (it is ready for input), at most `timeout`.
    func waitUntilReady(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !hasProducedOutput, isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Called when the tab is closed or the app quits: hang up the shell and stop polling.
    func tearDown() {
        isClosing = true
        pollTimer?.invalidate()
        pollTimer = nil
        if isRunning { view.terminate() }
        view.removeFromSuperview()
    }

    // MARK: - Starting the shell

    private func start(in workingDirectory: String) {
        let shell = Self.loginShell
        var directory = HomePath.expand(workingDirectory)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) || !isDirectory.boolValue {
            directory = NSHomeDirectory()
        }
        lastDirectory = directory

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

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timers scheduled from the main thread fire on the main thread.
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// The user's login shell from the user database (what `chsh` sets), falling back to zsh.
    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
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
        let shellPID = process.shellPid
        let group = ProcessInspector.foregroundProcessGroup(ptyFileDescriptor: process.childfd)
        let isShellInForeground = group == nil || group == shellPID

        // A title belongs to the program that set it; forget it once that program is gone.
        if programTitleGroup != group {
            programTitle = nil
            programTitleGroup = nil
        }

        let program = isShellInForeground ? nil : group.flatMap { ProcessInspector.programName(pid: $0) }
        if program != foregroundProgram {
            terminalLog.notice("tab \(self.tabID, privacy: .public): foreground \(program ?? "<shell>", privacy: .public) (group \(group ?? -1), shell \(shellPID))")
            foregroundProgram = program
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
}

// MARK: - SwiftTerm callbacks

// `@MainActor` conformance: SwiftTerm calls these on the main thread (see its docs), so we can
// touch our main-actor state directly.
extension TerminalSession: @MainActor LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// A program set the window title with an escape sequence (OSC 0/2).
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        programTitle = title
        programTitleGroup = view.process.flatMap { ProcessInspector.foregroundProcessGroup(ptyFileDescriptor: $0.childfd) }
        refresh()
    }

    /// The shell reported its directory (OSC 7). We read the directory ourselves, so just refresh.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        refresh()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        foregroundProgram = nil
        pollTimer?.invalidate()
        pollTimer = nil
        guard !isClosing else { return }

        if exitCode == 0 {
            // `exit` or Ctrl-D at the prompt: close the tab, like most terminals do.
            state?.closeTab(tabID, in: spaceID, confirmIfBusy: false)
        } else {
            let reason = exitCode.map { "exit code \($0)" } ?? "terminated by a signal"
            view.feed(text: "\r\n\u{1b}[2m[Process ended: \(reason). Press Return to start a new shell.]\u{1b}[0m\r\n")
        }
    }
}

/// SwiftTerm's view, with two additions: it follows light/dark mode, and after the shell has
/// exited, Return starts a new one.
final class SingularityTerminalView: LocalProcessTerminalView {
    var onReturnAfterExit: (() -> Void)?

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
