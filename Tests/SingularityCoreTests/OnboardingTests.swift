import Foundation
import Testing
@testable import SingularityCore

@Suite struct OnboardingTests {
    // MARK: - The step sequence

    @Test func stepsGoForwardAndBack() {
        var flow = OnboardingFlow()
        #expect(flow.step == .welcome)
        #expect(!flow.canGoBack)
        #expect(!flow.importedFromArc)

        #expect(flow.advance() == .space)
        #expect(flow.canGoBack)
        #expect(flow.advance() == .agents)
        flow.back()
        #expect(flow.step == .space)
        #expect(flow.advance() == .agents)
        #expect(flow.advance() == .plugins)
        #expect(flow.advance() == nil) // finished
    }

    @Test func backOnTheFirstStepStaysThere() {
        var flow = OnboardingFlow()
        flow.back()
        #expect(flow.step == .welcome)
    }

    @Test func anArcImportLeavesOutTheSpaceStep() {
        var flow = OnboardingFlow()
        flow.arcImportFinished()
        #expect(flow.importedFromArc)
        #expect(flow.step == .agents)
        flow.back()
        #expect(flow.step == .welcome)
        #expect(flow.advance() == .agents)
        #expect(flow.advance() == .plugins)
        #expect(flow.advance() == nil)
    }

    // MARK: - First run

    @Test func brandNewOnlyWhenNothingLoadedAndNothingFailed() {
        #expect(FirstRun.isBrandNew(loadedSpaceCount: 0, loadErrorCount: 0))
        #expect(!FirstRun.isBrandNew(loadedSpaceCount: 0, loadErrorCount: 1))
        #expect(!FirstRun.isBrandNew(loadedSpaceCount: 1, loadErrorCount: 0))
    }

    @Test func onlyTheEmptyPlaceholderMayTakeANewSlug() {
        #expect(FirstRun.mayReslug(isFirstRunPlaceholder: true, tabCount: 0))
        #expect(!FirstRun.mayReslug(isFirstRunPlaceholder: true, tabCount: 1))
        #expect(!FirstRun.mayReslug(isFirstRunPlaceholder: false, tabCount: 0))
    }

    // MARK: - Slugs for names typed in step 2

    @Test func slugsForOddNames() {
        let slug = Slug.unique(from: "🎉", existing: [])
        #expect(!slug.isEmpty)
        #expect(slug.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        #expect(Slug.unique(from: "Work", existing: ["work"]) == "work-2")
    }

    // MARK: - Moving a Space's folder

    private func makeStore() -> SpaceStore {
        SpaceStore(paths: Paths(root: FileManager.default.temporaryDirectory
            .appending(path: "singularity-tests-\(UUID().uuidString)", directoryHint: .isDirectory)))
    }

    @Test func movesTheFolder() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        try store.save(Space(name: "Personal", slug: "personal", colorHex: "#5E81F4"))

        try store.moveSpaceFolder(fromSlug: "personal", toSlug: "work")

        #expect(FileManager.default.fileExists(atPath: store.paths.spaceFile("work").path))
        #expect(!FileManager.default.fileExists(atPath: store.paths.spaceDirectory("personal").path))
    }

    @Test func aMissingFolderIsNotAnError() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }

        try store.moveSpaceFolder(fromSlug: "personal", toSlug: "work")

        #expect(!FileManager.default.fileExists(atPath: store.paths.spaceDirectory("work").path))
        #expect(!FileManager.default.fileExists(atPath: store.paths.spaceDirectory("personal").path))
    }

    @Test func refusesToMoveOntoAnExistingFolder() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        try store.save(Space(name: "Personal", slug: "personal", colorHex: "#5E81F4"))
        try store.save(Space(name: "Work", slug: "work", colorHex: "#5E81F4"))

        #expect(throws: (any Error).self) { try store.moveSpaceFolder(fromSlug: "personal", toSlug: "work") }

        let spaces = store.load().spaces
        #expect(Set(spaces.map(\.slug)) == ["personal", "work"])
        #expect(spaces.first { $0.slug == "work" }?.name == "Work")
        #expect(spaces.first { $0.slug == "personal" }?.name == "Personal")
    }
}
