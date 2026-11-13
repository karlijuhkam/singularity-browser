import AppKit
import Foundation
import Observation
import SingularityCore

/// Owns one `TerminalSession` per open terminal tab. Like web views, sessions start lazily
/// (the first time the tab is shown) and keep running when you switch tabs or Spaces.
@MainActor
@Observable
final class TerminalRegistry {
    @ObservationIgnored weak var state: AppState?
    private var sessions: [UUID: TerminalSession] = [:]

    func existingSession(_ tabID: UUID) -> TerminalSession? {
        sessions[tabID]
    }

    func session(for tab: BrowserTab, in space: Space) -> TerminalSession {
        if let existing = sessions[tab.id] { return existing }
        let session = TerminalSession(
            tabID: tab.id,
            spaceID: space.id,
            spaceSlug: space.slug,
            workingDirectory: tab.workingDirectory ?? space.workingDirectory,
            font: state?.terminalFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
            state: state,
            // Settings → Terminal: through the owner's herdr-core, when it is switched on and installed.
            herdr: state?.settings.terminalUsesHerdrCore == true ? HerdrCore.locate() : nil,
            // A launcher's command, for the tab's first shell only: taking it forgets it, so a
            // restarted shell (`restart`) gets nothing typed.
            initialCommand: state?.takePendingCommand(tab.id)
        )
        sessions[tab.id] = session
        return session
    }

    /// Replaces an exited session with a fresh shell in the same tab. (With herdr-core: shows
    /// the tab's shell again if it is still running there, else starts a fresh one.)
    func restart(_ tab: BrowserTab, in space: Space) {
        sessions.removeValue(forKey: tab.id)?.tearDown(endProgram: false)
        _ = session(for: tab, in: space)
    }

    /// The tabs are being closed: their shells end.
    func removeSessions(for tabIDs: [UUID]) {
        for id in tabIDs {
            sessions.removeValue(forKey: id)?.tearDown()
        }
    }

    /// Sessions whose foreground is a program other than the shell (e.g. a running agent).
    var busySessions: [TerminalSession] {
        sessions.values.filter { $0.foregroundProgram != nil }
    }

    /// Settings → Terminal changed the font: apply it to every open terminal.
    func applyFont(_ font: NSFont) {
        for session in sessions.values {
            session.view.font = font
        }
    }

    /// The app quits. Shells of the built-in terminal end with it; herdr-core's keep running
    /// and their tabs find them again at the next launch.
    func tearDownAll() {
        for id in Array(sessions.keys) {
            sessions.removeValue(forKey: id)?.tearDown(endProgram: false)
        }
    }
}
