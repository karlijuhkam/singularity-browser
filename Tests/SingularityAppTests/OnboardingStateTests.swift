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

    /// ⌘W (`closeTabCommand`, the menu item's action) closes the flow, never the tab behind it, and
    /// does nothing while a sheet is open over the flow (the Arc import, a plugin's approval).
    @Test func closeTabLeavesTheFlowAloneWhileASheetIsOpen() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let id = state.spaces[0].id
        state.openInNewTab(URL(string: "about:blank")!, spaceID: id) // a tab hidden behind the flow
        #expect(state.onboarding != nil)

        state.isImportingFromArc = true
        #expect(state.welcomeSheetIsOpen)
        state.closeTabCommand()
        #expect(state.onboarding != nil)
        state.isImportingFromArc = false

        state.welcomePluginReview = "1password"
        #expect(state.welcomeSheetIsOpen)
        state.closeTabCommand()
        #expect(state.onboarding != nil)
        state.welcomePluginReview = nil

        #expect(!state.welcomeSheetIsOpen)
        state.closeTabCommand()
        #expect(state.onboarding == nil)
        #expect(state.space(id)?.tabs.count == 1)

        // Without the flow, ⌘W closes the selected tab; an open sheet no longer counts as the flow's.
        state.isImportingFromArc = true
        #expect(!state.welcomeSheetIsOpen)
        state.isImportingFromArc = false
        state.closeTabCommand()
        #expect(state.space(id)?.tabs.isEmpty == true)
    }

    /// Step 4's row: Add while the plugin isn't in the plugins folder, a spinner while it is copied,
    /// Review… until it is approved, then "Added".
    @Test func pluginRowAction() {
        #expect(PluginRowAction.of(adding: false, installedNeedsReview: nil) == .add)
        #expect(PluginRowAction.of(adding: true, installedNeedsReview: nil) == .adding)
        #expect(PluginRowAction.of(adding: true, installedNeedsReview: true) == .adding)
        #expect(PluginRowAction.of(adding: false, installedNeedsReview: true) == .review)
        #expect(PluginRowAction.of(adding: false, installedNeedsReview: false) == .added)
    }

    /// Step 4's Add with the repo's 1Password plugin: copied into the (temporary) plugins folder,
    /// listed, not approved and not running, so the row shows Review…. Nothing is approved in
    /// code: that only happens in `PluginApprovalSheet`.
    @Test func addingABundledPluginLeavesItWaitingForReview() async throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Plugins/1password", directoryHint: .isDirectory)
        #expect(state.plugins.plugin("1password") == nil)
        #expect(PluginRowAction.of(adding: false, installedNeedsReview: state.plugins.plugin("1password")?.needsReview) == .add)

        let id = try await state.plugins.addPlugin(from: source)
        #expect(id == "1password")
        #expect(FileManager.default.fileExists(atPath: state.paths.pluginsDirectory.appending(path: "1password/plugin.json").path))
        let plugin = try #require(state.plugins.plugin(id))
        #expect(plugin.needsReview)
        #expect(plugin.decision == .notApproved)
        #expect(plugin.runState == .stopped)
        #expect(PluginRowAction.of(adding: false, installedNeedsReview: plugin.needsReview) == .review)
    }

    /// The palette's "Welcome to Singularity…" (`cmd-welcome`) from an ordinary window with a tab:
    /// the flow opens at step 1 and the palette is gone. The menu item Singularity → "Welcome to
    /// Singularity…" calls the same `showWelcome()` (`Commands.swift`).
    @Test func thePaletteEntryOpensTheFlow() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        state.closeWelcome()
        state.openInNewTab(URL(string: "about:blank")!)
        #expect(state.selectedTab != nil)

        state.showPalette(.newTab)
        #expect(state.palette == .newTab)
        let item = try #require(PaletteResults.items(for: "welcome", mode: .newTab, state: state)
            .first { $0.id == "cmd-welcome" })
        PaletteResults.perform(item, mode: .newTab, state: state)
        #expect(state.onboarding?.step == .welcome)
        #expect(state.palette == nil)
        #expect(state.selectedTab != nil) // the tab is only hidden
    }

    /// Step 1's Arc import with a real file (`ArcImport.read` on the Core tests' fixture): the
    /// imported Spaces have agents off and policy ask, the untouched placeholder is gone (its folder
    /// removed inside the test folder, not put in the Trash), and the flow skips the Space step.
    @Test func anArcImportFromAFileDuringTheFlow() throws {
        MainRunLoopGuard.start
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = TestAppState.make(root: root)
        defer { shutDown(state) }
        let placeholder = try #require(state.firstRunPlaceholderID)
        state.flushSaves()
        #expect(spaceFolders(root) == ["personal"])

        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "SingularityCoreTests/Fixtures/arc/StorableSidebar.json")
        let arcSpaces = try ArcImport.read(file).get()
        #expect(arcSpaces.map(\.name) == ["Work", "Arc"])
        state.importArcSpaces(arcSpaces, options: ArcImport.Options())
        state.flushSaves()

        #expect(state.space(placeholder) == nil)
        #expect(state.spaces.map(\.name) == ["Work", "Arc"])
        #expect(state.spaces.allSatisfy { !$0.agentsEnabled && $0.agentPolicy == .ask })
        #expect(state.spaces[0].tabs.count == 8) // 6 pinned + 2 open
        #expect(spaceFolders(root) == Set(state.spaces.map(\.slug)))
        #expect(!spaceFolders(root).contains("personal"))
        #expect(state.onboarding?.step == .agents)
        #expect(state.onboarding?.importedFromArc == true)
        #expect(state.onboarding?.visibleSteps == [.welcome, .agents, .plugins]) // three dots
        state.welcomeBack()
        #expect(state.onboarding?.step == .welcome)
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
