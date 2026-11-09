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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    /// Cmd+Q: ask first if a terminal is running something (e.g. an agent).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminalLog.notice("applicationShouldTerminate called; state set: \(self.state != nil)")
        return (state?.confirmQuit() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
