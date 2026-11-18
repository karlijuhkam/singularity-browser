import AppKit
import SingularityCore
import SwiftUI

@main
struct SingularityApp: App {
    // Lets us hook into a few AppKit app-lifecycle callbacks SwiftUI doesn't expose.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState

    /// Held for as long as the app runs; see `InstanceLock`.
    private static var instanceLock: InstanceLock?

    init() {
        // Before anything touches the data folder: if another copy already works on it, bring
        // that one forward and leave. (Two copies would overwrite each other's Spaces.)
        guard let lock = InstanceLock.acquire(paths: .standard) else {
            let me = NSRunningApplication.current
            let other = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != me.processIdentifier && $0.bundleIdentifier != nil && $0.bundleIdentifier == me.bundleIdentifier
            }
            other?.activate()
            FileHandle.standardError.write(Data("Singularity is already running on \(Paths.standard.root.path).\n".utf8))
            exit(0)
        }
        Self.instanceLock = lock
        _state = State(initialValue: AppState(paths: .standard))
    }

    var body: some Scene {
        // Any number of browser windows, all equal; each one's value is its record in
        // `state.json` (`BrowserWindowState`, see AppState+Windows.swift and BrowserWindowRoot).
        WindowGroup("Singularity", id: "browser", for: UUID.self) { $windowID in
            BrowserWindowRoot(requested: $windowID)
                .environment(state)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    appDelegate.state = state
                    appDelegate.reportLoadErrors()
                }
        }
        // Title bar is invisible and content runs underneath it, as in Arc/Safari's compact tabs.
        .windowStyle(.hiddenTitleBar)
        .commands { SingularityCommands(state: state) }

        // ⌘, opens this (SwiftUI adds the "Settings…" menu item).
        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState? {
        // Links that arrived before the app state was attached (a link that started the app).
        didSet {
            links.deliver = state.map { state in
                { [weak state] url in
                    // A Markdown file from Finder opens as a note; a web link in a little window.
                    if LinkInbox.isMarkdownFile(url) { state?.openMarkdownFile(url) } else { state?.openLink(url) }
                }
            }
        }
    }
    /// Links from other apps, on their way to little windows.
    let links = LinkInbox()
    private var appearanceObservation: NSKeyValueObservation?
    private var sigtermSource: DispatchSourceSignal?

    /// The icon file (Finder, Launchpad) is the white orb on a dark tile. While running, the Dock
    /// icon follows light/dark mode like the orb on singularity.rroosa.ee: black orb on a light
    /// tile in light mode, white orb on a dark tile in dark mode.
    /// Take web links ourselves, before AppKit's own handler would: registered this early, it also
    /// gets the link that started the app. Our handler replaces AppKit's for this one event, so
    /// SwiftUI never sees the link and doesn't react to it with the main window's scene.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// "Open this URL": what macOS sends the default browser when a link is clicked in another app.
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        links.receive([url])
    }

    /// The same links, should AppKit's handler be the one that runs after all. Only one of the
    /// two is ever called for a link (there is one handler per event), so no link opens twice.
    func application(_ application: NSApplication, open urls: [URL]) {
        links.receive(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOnSigterm()
        updateDockIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateDockIcon() }
        }
    }

    /// SIGTERM (scripts/run.sh, a plain `kill`) quits like Cmd+Q: the busy-terminal prompt, saves
    /// and shutdown all run. Without this, AppKit's default is to die at once. SIGKILL still does.
    /// The default action is switched off so the dispatch source (on the main queue) gets the signal.
    private func quitOnSigterm() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source // keep it alive; a released source stops delivering
    }

    /// Spaces or settings that couldn't be read at launch. Their files are never overwritten, but
    /// without a message a Space would simply be gone.
    func reportLoadErrors() {
        guard let state, !state.loadErrors.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some of your data could not be opened"
        alert.informativeText = state.loadErrors.prefix(8).joined(separator: "\n\n")
            + "\n\nThe files are untouched, in \(state.paths.root.path)."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        state.loadErrors = []
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(state.paths.spacesDirectory)
        }
    }

    private func updateDockIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = isDark ? "DockIcon-dark" : "DockIcon-light"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    /// Cmd+Q: ask first if a terminal is running something (e.g. an agent).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminalLog.notice("applicationShouldTerminate called; state set: \(self.state != nil)")
        // Second pass (see below): the question was answered and the notes are written.
        if notesWrittenForQuit { return .terminateNow }
        guard state?.confirmQuit() ?? true else { return .terminateCancel }
        // From here on the app quits: windows closing now keep their records for the next launch.
        state?.isTerminating = true
        // Open notes may hold a moment's typing that isn't on disk yet (the editor saves 0.4 s
        // after the last keystroke). So this quit is called off, the editors write, and the app
        // quits again by itself right after; each editor gives up after 2 s.
        //
        // Not `.terminateLater`: that waits in a nested run loop, and when the quit came from
        // inside a main-queue block (SIGTERM does: `quitOnSigterm`) the main queue can't run
        // there, so the writes would never happen and the app would never quit.
        guard let state, !state.notes.isEmpty else { return .terminateNow }
        Task { @MainActor in
            await state.notes.flushAll()
            self.notesWrittenForQuit = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    /// Set once the open notes were written for a quit that is about to be repeated.
    private var notesWrittenForQuit = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
