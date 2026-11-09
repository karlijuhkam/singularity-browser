import AppKit
import SingularityCore
import SwiftUI

@main
struct SingularityApp: App {
    // Lets us hook into a few AppKit app-lifecycle callbacks SwiftUI doesn't expose.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState(paths: .standard)

    var body: some Scene {
        // `Window` (not `WindowGroup`) = exactly one browser window; no File → New Window.
        Window("Singularity", id: "main") {
            MainView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.state = state }
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
    weak var state: AppState?
    private var appearanceObservation: NSKeyValueObservation?

    /// The icon file (Finder, Launchpad) is the white orb on a dark tile. While running, the Dock
    /// icon follows light/dark mode like the orb on singularity.rroosa.ee: black orb on a light
    /// tile in light mode, white orb on a dark tile in dark mode.
    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateDockIcon() }
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
        return (state?.confirmQuit() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
