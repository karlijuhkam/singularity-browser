import Foundation
import Testing
@testable import Singularity
@testable import SingularityCore

extension AppTests {
/// The welcome flow's state in a real `AppState` on a temporary data folder (no window).
@MainActor
@Suite(.serialized) struct OnboardingStateTests {
    /// A short path: the agent socket lives under it, and Unix sockets allow ~100 characters.
    private func makeRoot() -> URL {
        URL(filePath: "/private/tmp/sg-t-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    /// Stops what `AppState.init` started (agent socket, plugin watcher, artifact servers).
    private func shutDown(_ state: AppState) {
        state.mcp?.stop()
        state.plugins.terminateAll()
        for space in state.spaces { state.artifacts.stop(space.id) }
    }

    private func spaceFolders(_ root: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: Paths(root: root).spacesDirectory.path)) ?? [])
    }

    @Test func aBrandNewInstallShowsTheFlowOnce() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(paths: Paths(root: root))
        #expect(state.onboarding?.step == .welcome)
        #expect(state.spaces.count == 1)
        let placeholder = try #require(state.firstRunPlaceholderID)
        #expect(placeholder == state.spaces[0].id)
        #expect(state.welcomeSpace?.id == placeholder)
        state.flushSaves()
        shutDown(state)

        let again = AppState(paths: Paths(root: root))
        defer { shutDown(again) }
        #expect(again.onboarding == nil)
        #expect(again.firstRunPlaceholderID == nil)
    }

    @Test func renamingThePlaceholderMovesItsFolder() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(paths: Paths(root: root))
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

        let again = AppState(paths: Paths(root: root))
        defer { shutDown(again) }
        #expect(again.spaces.map(\.slug) == ["work"])
        #expect(again.loadErrors.isEmpty)
    }

    /// The old folder was already on disk (saved, and the artifact server started in it).
    @Test func renamingAfterTheFolderWasWritten() async throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(paths: Paths(root: root))
        defer { shutDown(state) }
        let id = try #require(state.firstRunPlaceholderID)
        state.flushSaves()
        try await Task.sleep(for: .milliseconds(300)) // lets the artifact server start
        #expect(spaceFolders(root) == ["personal"])
        #expect(state.artifacts.host(id)?.root.path.contains("/spaces/personal/") == true)

        state.applyWelcomeSpace(name: "Work", colorHex: SpaceColors.presets[0], workingDirectory: "~")
        state.flushSaves()
        try await Task.sleep(for: .milliseconds(300)) // the server starts again, on the new folder

        #expect(state.space(id)?.slug == "work")
        #expect(spaceFolders(root) == ["work"])
        #expect(FileManager.default.fileExists(atPath: Paths(root: root).spaceFile("work").path))
        #expect(state.artifacts.host(id)?.root.path.contains("/spaces/work/") == true)
    }

    @Test func onlyThePlaceholderTakesANewSlug() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(paths: Paths(root: root))
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

        let state = AppState(paths: Paths(root: root))
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

        let state = AppState(paths: Paths(root: root))
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

    @Test func anArcImportReplacesThePlaceholder() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(paths: Paths(root: root))
        defer { shutDown(state) }
        let placeholder = try #require(state.firstRunPlaceholderID)
        let arc = ArcImport.ArcSpace(id: "a", name: "Work", colorHex: nil, profile: "Default",
                                     pinned: [], unpinned: [], skipped: 0)
        state.importArcSpaces([arc], options: ArcImport.Options())

        #expect(state.space(placeholder) == nil)
        #expect(state.spaces.map(\.name) == ["Work"])
        #expect(state.firstRunPlaceholderID == nil)
        #expect(state.onboarding?.step == .agents)
        #expect(state.onboarding?.importedFromArc == true)
    }

    @Test func switchingAgentsOnKeepsThePolicy() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(paths: Paths(root: root))
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
