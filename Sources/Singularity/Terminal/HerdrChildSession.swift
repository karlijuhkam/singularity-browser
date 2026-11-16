import AppKit
import SingularityCore
import SwiftTerm

/// A view onto a herdr-core terminal that is *not* a tab's own: a Bot's worker, a topic session,
/// a dev server started with `hc run --bg` (see `HerdrTree` in Core). The sidebar lists these
/// under their tab; a click shows one in the tab's pane.
///
/// It only looks and types: the view runs `hc attach <address>`, exactly what the owner would
/// type in a terminal. It never starts, ends or removes the terminal (`hc run`, `hc kill`,
/// `hc rm`); tearing this down only ends `hc attach`. It sends nothing to the inbox and no agent
/// tool can reach it.
@MainActor
final class HerdrChildSession {
    /// herdr-core's id of the terminal, e.g. "t64".
    let address: String
    let view: SingularityTerminalView
    private let hcPath: String?
    private let onGone: () -> Void
    private let onReattach: () -> Void
    private var isClosing = false
    /// `hc attach` ended while the terminal lives on (see `attachEnded`).
    private var isDetached = false

    /// - Parameter hc: the installed `hc`; nil shows an empty view and starts nothing (tests).
    /// - Parameter onGone: the terminal itself has ended (not merely this view let go of it).
    /// - Parameter onReattach: Return was pressed after a detach. The registry then replaces this
    ///   session with a fresh one, as a tab's own terminal is replaced after its shell ended.
    init(address: String, hc: String?, font: NSFont, onGone: @escaping () -> Void, onReattach: @escaping () -> Void) {
        self.address = address
        self.hcPath = hc
        self.onGone = onGone
        self.onReattach = onReattach
        self.view = SingularityTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.font = font
        view.configureNativeColors()
        view.processDelegate = self
        // After a detach (below) Return shows the terminal again.
        view.onReturnAfterExit = { [weak self] in
            guard let self, self.isDetached, !self.isClosing else { return }
            self.onReattach()
        }
        attach()
    }

    /// Ends `hc attach`. The terminal and its program go on in herdr-core.
    func tearDown() {
        isClosing = true
        if view.process?.running == true { view.terminate() }
        view.removeFromSuperview()
    }

    private func attach() {
        guard let hcPath, !isClosing, view.process?.running != true else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Singularity"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        view.startProcess(
            executable: hcPath,
            args: HerdrCore.attachArguments(name: address),
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: NSHomeDirectory()
        )
    }

    /// `hc attach` ended: either the terminal ended, or only this view let go (herdr's detach
    /// key, ctrl+\ by default, or herdr-core restarting).
    private func attachEnded() {
        guard let hcPath, !isClosing else { return }
        let address = address
        Task { [weak self] in
            let result = await CommandBroker.run(path: hcPath, arguments: ["get", address, "--json"], timeout: .seconds(15))
            let lookup = HerdrCore.parseGet(result.stdout.isEmpty ? result.stderr : result.stdout)
            guard let self, !self.isClosing else { return }
            if case .found(let terminal) = lookup, terminal.state == .live {
                self.isDetached = true
                self.view.feed(text: "\r\n\u{1b}[2m[Detached. It is still running in herdr-core. Press Return to show it again.]\u{1b}[0m\r\n")
            } else {
                self.onGone()
            }
        }
    }
}

// `@MainActor` conformance: SwiftTerm calls these on the main thread, as for `TerminalSession`.
extension HerdrChildSession: @MainActor LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        attachEnded()
    }
}
