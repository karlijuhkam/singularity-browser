import Foundation
import Testing
@testable import Singularity
@testable import SingularityCore

extension AppTests {
/// The welcome flow's state in a real `AppState` on a temporary data folder (no window).
@MainActor
@Suite(.serialized) struct OnboardingStateTests {
    private func makeRoot() -> URL { TestAppState.makeRoot() }
    private func shutDown(_ state: AppState) { TestAppState.shutDown(state) }

    private struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }

    /// Polls `condition` every 20 ms until it holds; fails the test after `limit`.
    private func waitUntil(_ what: String, limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut(description: "waited \(limit) for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func spaceFolders(_ root: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: Paths(root: root).spacesDirectory.path)) ?? [])
    }

    @Test func aBrandNewInstallShowsTheFlowOnce() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        #expect(state.onboarding?.step == .welcome)
        #expect(state.spaces.count == 1)
        let placeholder = try #require(state.firstRunPlaceholderID)
        #expect(placeholder == state.spaces[0].id)
        #expect(state.welcomeSpace?.id == placeholder)
        state.flushSaves()
        shutDown(state)

        let again = TestAppState.make(root: root)
        defer { shutDown(again) }
        #expect(again.onboarding == nil)
        #expect(again.firstRunPlaceholderID == nil)
    }

    @Test func renamingThePlaceholderMovesItsFolder() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        let id = try #require(state.firstRunPlaceholderID)
        #expect(state.space(id)?.slug == "personal")

        state.applyWelcomeSpace(name: "Work", colorHex: SpaceColors.presets[2], workingDirectory: "~/Code")
        state.flushSaves()
        shutDown(state)

        let space = try #require(state.space(id))
        #expect(space.slug == "work")
        #expect(space.name == "Work")
        #expect(space.colorHex == SpaceColors.presets[2])
        #expect(space.workingDirectory == "~/Code")
        #expect(spaceFolders(root) == ["work"])

        let again = TestAppState.make(root: root)
        defer { shutDown(again) }
        #expect(again.spaces.map(\.slug) == ["work"])
        #expect(again.loadErrors.isEmpty)
    }

    /// The old folder was already on disk (saved, and the artifact server started in it).
    @Test func renamingAfterTheFolderWasWritten() async throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = try #require(state.firstRunPlaceholderID)
        state.flushSaves()
        try await waitUntil("the artifact server to start") { state.artifacts.host(id) != nil }
        #expect(spaceFolders(root) == ["personal"])
        #expect(state.artifacts.host(id)?.root.path.contains("/spaces/personal/") == true)

        state.applyWelcomeSpace(name: "Work", colorHex: SpaceColors.presets[0], workingDirectory: "~")
        state.flushSaves()
        try await waitUntil("the artifact server to start again, on the new folder") {
            state.artifacts.host(id)?.root.path.contains("/spaces/work/") == true
        }

        #expect(state.space(id)?.slug == "work")
        #expect(spaceFolders(root) == ["work"])
        #expect(FileManager.default.fileExists(atPath: Paths(root: root).spaceFile("work").path))
        #expect(state.artifacts.host(id)?.root.path.contains("/spaces/work/") == true)
    }

    @Test func onlyThePlaceholderTakesANewSlug() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = try #require(state.firstRunPlaceholderID)

        // Reopened from the menu (no placeholder any more): the name changes, the slug doesn't.
        state.closeWelcome()
        state.showWelcome()
        #expect(state.firstRunPlaceholderID == nil)
        #expect(state.welcomeSpace?.id == id)
        state.applyWelcomeSpace(name: "Work", colorHex: SpaceColors.presets[0], workingDirectory: "~")
        #expect(state.space(id)?.name == "Work")
        #expect(state.space(id)?.slug == "personal")
    }

    @Test func aTabEndsThePlaceholder() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = try #require(state.firstRunPlaceholderID)
        // An agent's page or a new artifact can add a tab without leaving the flow.
        _ = state.agentOpenTab(url: URL(string: "about:blank")!, spaceID: id)
        #expect(state.onboarding != nil)
        #expect(state.firstRunPlaceholderID == nil)
        state.applyWelcomeSpace(name: "Work", colorHex: SpaceColors.presets[0], workingDirectory: "~")
        #expect(state.space(id)?.slug == "personal")
    }

    @Test func stepsAndLeaving() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        state.advanceWelcome()
        #expect(state.onboarding?.step == .space)
        state.welcomeBack()
        #expect(state.onboarding?.step == .welcome)
        for _ in 0..<3 { state.advanceWelcome() }
        #expect(state.onboarding?.step == .plugins)
        #expect(state.welcomeCoversWindow) // page and tab menu commands are off
        state.advanceWelcome()
        #expect(state.onboarding == nil)
        #expect(!state.welcomeCoversWindow)
        #expect(state.firstRunPlaceholderID == nil)

        // Opening the palette (New Tab, ⌘K) leaves the flow; the Arc import sheet doesn't.
        state.showWelcome()
        state.isImportingFromArc = true
        #expect(state.onboarding != nil)
        state.isImportingFromArc = false
        state.showPalette(.newTab)
        #expect(state.onboarding == nil)
        #expect(state.palette == .newTab)
        state.showWelcome()
        #expect(state.palette == nil)
    }

    /// The import removes the placeholder with the real `deleteSpace`. Its folder is on disk first
    /// (saved); `TestAppState` removes it inside the test's folder instead of the Trash.
    @Test func anArcImportReplacesThePlaceholder() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let placeholder = try #require(state.firstRunPlaceholderID)
        state.flushSaves()
        #expect(spaceFolders(root) == ["personal"])
        let arc = ArcImport.ArcSpace(id: "a", name: "Work", colorHex: nil, profile: "Default",
                                     pinned: [], unpinned: [], skipped: 0)
        state.importArcSpaces([arc], options: ArcImport.Options())
        state.flushSaves()

        #expect(spaceFolders(root) == ["work"])
        #expect(state.space(placeholder) == nil)
        #expect(state.spaces.map(\.name) == ["Work"])
        #expect(state.firstRunPlaceholderID == nil)
        #expect(state.onboarding?.step == .agents)
        #expect(state.onboarding?.importedFromArc == true)
    }

    /// Once step 2's Continue named the placeholder, it is the user's Space: a later import (File →
    /// Import from Arc… on a later step, or step 1's button after Back) keeps it.
    @Test func anArcImportKeepsASpaceTheUserNamed() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = try #require(state.firstRunPlaceholderID)
        state.applyWelcomeSpace(name: "Work", colorHex: SpaceColors.presets[2], workingDirectory: "~")
        #expect(state.space(id)?.slug == "work")

        let arc = ArcImport.ArcSpace(id: "a", name: "Home", colorHex: nil, profile: "Default",
                                     pinned: [], unpinned: [], skipped: 0)
        state.importArcSpaces([arc], options: ArcImport.Options())

        #expect(state.space(id)?.name == "Work")
        #expect(state.space(id)?.slug == "work")
        #expect(state.spaces.map(\.name) == ["Work", "Home"])
        #expect(FileManager.default.fileExists(atPath: Paths(root: root).spaceFile("work").path))
        #expect(state.firstRunPlaceholderID == nil)
        #expect(state.onboarding?.step == .agents)
    }

    /// An artifact page's `singularity.open` (→ `openInNewTab`) needs no click, so it must not close
    /// the flow; the tab opens behind it.
    @Test func openingATabWithoutTheUserKeepsTheFlow() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = try #require(state.firstRunPlaceholderID)
        state.openInNewTab(URL(string: "about:blank")!, spaceID: id)
        #expect(state.onboarding?.step == .welcome)
        #expect(state.space(id)?.tabs.count == 1)
    }

    @Test func switchingAgentsOnKeepsThePolicy() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = state.spaces[0].id
        state.setAgentsEnabled(true, spaceID: id)
        #expect(state.space(id)?.agentsEnabled == true)
        #expect(state.space(id)?.agentPolicy == .ask)
        state.setAgentsEnabled(false, spaceID: id)
        #expect(state.space(id)?.agentsEnabled == false)
    }
}
}
