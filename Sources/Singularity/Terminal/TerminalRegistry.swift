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
            workingDirectory: tab.workingDirectory ?? space.workingDirectory,
            state: state
        )
        sessions[tab.id] = session
        return session
    }

    /// Replaces an exited session with a fresh shell in the same tab.
    func restart(_ tab: BrowserTab, in space: Space) {
        removeSessions(for: [tab.id])
        _ = session(for: tab, in: space)
    }

    func removeSessions(for tabIDs: [UUID]) {
        for id in tabIDs {
            sessions.removeValue(forKey: id)?.tearDown()
        }
    }

    /// Sessions whose foreground is a program other than the shell (e.g. a running agent).
    var busySessions: [TerminalSession] {
        sessions.values.filter { $0.foregroundProgram != nil }
    }

    func tearDownAll() {
        removeSessions(for: Array(sessions.keys))
    }
}
