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
    /// Views onto herdr-core terminals under a tab (a Bot's workers), by herdr address. Made on
    /// the first click on a child row and kept while that terminal lives; see `HerdrChildSession`.
    private var childSessions: [String: HerdrChildSession] = [:]

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
        // The first terminal tab of this run: the sidebar may now have rows to listen for.
        state?.herdr.updateRunning()
        return session
    }

    // MARK: - Terminals under a tab (herdr-core children)

    func existingChildSession(_ address: String) -> HerdrChildSession? {
        childSessions[address]
    }

    /// The view onto herdr terminal `address`, made on first use. It only attaches.
    func childSession(address: String) -> HerdrChildSession {
        if let existing = childSessions[address] { return existing }
        let session = HerdrChildSession(
            address: address,
            // Nil in tests and wherever `hc` isn't installed: an empty view, nothing started.
            hc: state?.settings.terminalUsesHerdrCore == true ? HerdrCore.locate() : nil,
            font: state?.terminalFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
            onGone: { [weak self] in self?.state?.herdrChildGone(address) },
            onReattach: { [weak self] in self?.reattachChild(address) }
        )
        childSessions[address] = session
        return session
    }

    /// Return after a detach: a fresh view attaches to the same terminal. (`TabContentView` keys
    /// its host on the session, so the pane picks the new view up.)
    private func reattachChild(_ address: String) {
        childSessions.removeValue(forKey: address)?.tearDown()
        _ = childSession(address: address)
    }

    func removeChildSession(_ address: String) {
        childSessions.removeValue(forKey: address)?.tearDown()
    }

    /// Lets go of the views of terminals that are no longer there. Only `hc attach` ends.
    func removeChildSessions(keeping addresses: Set<String>) {
        for address in Array(childSessions.keys) where !addresses.contains(address) {
            childSessions.removeValue(forKey: address)?.tearDown()
        }
    }

    /// Replaces an exited session with a fresh shell in the same tab. (With herdr-core: shows
    /// the tab's shell again if it is still running there, else starts a fresh one.)
    func restart(_ tab: BrowserTab, in space: Space) {
        sessions.removeValue(forKey: tab.id)?.tearDown(endProgram: false)
        _ = session(for: tab, in: space)
    }

    /// The tabs are being closed: their shells end.
    func removeSessions(for tabIDs: [UUID]) {
        // A herdr-core tab that was not shown since launch has no session, but its shell (and
        // what runs under it) is still in herdr-core from before: closing the tab ends it too.
        let hc = state?.settings.terminalUsesHerdrCore == true ? HerdrCore.locate() : nil
        for id in tabIDs {
            if let session = sessions.removeValue(forKey: id) {
                session.tearDown()
            } else if let hc, state?.spaces.contains(where: { $0.tab(id)?.isTerminal == true }) == true {
                TerminalSession.endHerdrTerminal(hc: hc, tabID: id)
            }
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
        for session in childSessions.values {
            session.view.font = font
        }
    }

    /// The app quits. Shells of the built-in terminal end with it; herdr-core's keep running
    /// and their tabs find them again at the next launch.
    func tearDownAll() {
        for id in Array(sessions.keys) {
            sessions.removeValue(forKey: id)?.tearDown(endProgram: false)
        }
        removeChildSessions(keeping: [])
    }
}
