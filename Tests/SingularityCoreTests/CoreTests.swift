import Foundation
import Testing
@testable import SingularityCore

// MARK: - Slug

@Suite struct SlugTests {
    @Test func basicSlugs() {
        #expect(Slug.make(from: "Client Work (2026)") == "client-work-2026")
        #expect(Slug.make(from: "  Ülemiste Café ") == "ulemiste-cafe")
        #expect(Slug.make(from: "🚀🚀") == "space")
        #expect(Slug.make(from: "a---b") == "a-b")
    }

    @Test func collisionsGetASuffix() {
        #expect(Slug.unique(from: "Work", existing: []) == "work")
        #expect(Slug.unique(from: "Work", existing: ["work"]) == "work-2")
        #expect(Slug.unique(from: "Work", existing: ["work", "work-2"]) == "work-3")
    }
}

// MARK: - URL input

@Suite struct URLInputTests {
    @Test func urls() {
        #expect(URLInput.classify("https://example.com/a?b=1") == .url(URL(string: "https://example.com/a?b=1")!))
        #expect(URLInput.classify("example.com") == .url(URL(string: "https://example.com")!))
        #expect(URLInput.classify("news.ycombinator.com/item?id=1") == .url(URL(string: "https://news.ycombinator.com/item?id=1")!))
        #expect(URLInput.classify("localhost:3000") == .url(URL(string: "http://localhost:3000")!))
        #expect(URLInput.classify("192.168.1.1/admin") == .url(URL(string: "https://192.168.1.1/admin")!))
    }

    @Test func searches() {
        #expect(URLInput.classify("swift concurrency") == .search(URL(string: "https://duckduckgo.com/?q=swift%20concurrency")!))
        #expect(URLInput.classify("a&b") == .search(URL(string: "https://duckduckgo.com/?q=a%26b")!))
        #expect(URLInput.classify("version 1.2") == .search(URL(string: "https://duckduckgo.com/?q=version%201.2")!))
        #expect(URLInput.classify("file.txt") != nil) // "txt" looks like a TLD; acceptable
        #expect(URLInput.classify("   ") == nil)
    }
}

// MARK: - Fuzzy matcher

@Suite struct FuzzyMatcherTests {
    @Test func matchesSubsequences() {
        #expect(FuzzyMatcher.score("gh", in: "GitHub") != nil)
        #expect(FuzzyMatcher.score("xyz", in: "GitHub") == nil)
        #expect(FuzzyMatcher.score("", in: "anything") == 0)
    }

    @Test func prefersWordStartsAndConsecutiveRuns() throws {
        let prefix = try #require(FuzzyMatcher.score("git", in: "GitHub"))
        let scattered = try #require(FuzzyMatcher.score("git", in: "Large image tool"))
        #expect(prefix > scattered)

        let wordStart = try #require(FuzzyMatcher.score("ns", in: "New Space"))
        let middle = try #require(FuzzyMatcher.score("ns", in: "Funds"))
        #expect(wordStart > middle)
    }
}

// MARK: - Space sections and moves

@Suite struct SpaceTests {
    func makeSpace() -> (Space, folder: Folder) {
        let folder = Folder(name: "Docs")
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", folders: [folder])
        space.append(BrowserTab.web(URL(string: "https://a.com")!, title: "A"))                // open
        var pinned = BrowserTab.web(URL(string: "https://p.com")!, title: "P")
        pinned.isPinned = true
        space.append(pinned)                                                             // pinned
        space.append(BrowserTab.web(URL(string: "https://b.com")!, title: "B"))                // open
        var inFolder = BrowserTab.web(URL(string: "https://f.com")!, title: "F")
        inFolder.folderID = folder.id
        space.append(inFolder)                                                           // folder
        space.append(BrowserTab.web(URL(string: "https://c.com")!, title: "C"))                // open
        return (space, folder)
    }

    @Test func sectionsAndSidebarOrder() {
        let (space, folder) = makeSpace()
        #expect(space.tabs(in: .pinned).map(\.title) == ["P"])
        #expect(space.tabs(in: .folder(folder.id)).map(\.title) == ["F"])
        #expect(space.tabs(in: .open).map(\.title) == ["A", "B", "C"])
        #expect(space.tabsInSidebarOrder.map(\.title) == ["P", "F", "A", "B", "C"])
    }

    @Test func moveWithinSectionLeavesOthersAlone() {
        var (space, _) = makeSpace()
        // Move "C" to the top of the open section (SwiftUI onMove: from [2] to 0).
        space.moveTabs(in: .open, fromOffsets: [2], toOffset: 0)
        #expect(space.tabs(in: .open).map(\.title) == ["C", "A", "B"])
        // Move "C" to the end (destination is "after the last item").
        space.moveTabs(in: .open, fromOffsets: [0], toOffset: 3)
        #expect(space.tabs(in: .open).map(\.title) == ["A", "B", "C"])
        #expect(space.tabsInSidebarOrder.map(\.title) == ["P", "F", "A", "B", "C"])
    }

    @Test func moveBetweenSections() {
        var (space, folder) = makeSpace()
        let a = space.tabs(in: .open)[0].id
        space.moveTab(a, to: .folder(folder.id))
        #expect(space.tabs(in: .folder(folder.id)).map(\.title) == ["F", "A"])
        space.moveTab(a, to: .pinned)
        #expect(space.tabs(in: .pinned).map(\.title) == ["P", "A"])
        space.moveTab(a, to: .open)
        #expect(space.tabs(in: .open).map(\.title) == ["B", "C", "A"])
    }

    @Test func deletingAFolderKeepsItsTabs() {
        var (space, folder) = makeSpace()
        space.deleteFolder(folder.id)
        #expect(space.folders.isEmpty)
        // "F" keeps its position in the underlying array (between B and C).
        #expect(space.tabs(in: .open).map(\.title) == ["A", "B", "F", "C"])
    }

    @Test func closingTheSelectedTabSelectsANeighbour() {
        var (space, _) = makeSpace()
        let order = space.tabsInSidebarOrder.map(\.id) // P F A B C
        space.selectedTabID = order[2]                   // A
        space.closeTab(order[2])
        #expect(space.selectedTabID == order[3])          // B
        space.selectedTabID = order[4]                   // C (last)
        space.closeTab(order[4])
        #expect(space.selectedTabID == order[3])          // B
        space.closeTab(order[0])                          // not selected: selection unchanged
        #expect(space.selectedTabID == order[3])
    }
}

// MARK: - Persistence

@Suite struct PersistenceTests {
    func temporaryPaths() -> Paths {
        Paths(root: FileManager.default.temporaryDirectory.appending(path: "singularity-tests-\(UUID().uuidString)"))
    }

    @Test func spacesRoundTripInSavedOrder() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = SpaceStore(paths: paths)

        var work = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        work.append(.web(URL(string: "https://example.com")!, title: "Example"))
        work.selectedTabID = work.tabs[0].id
        let home = Space(name: "Home", slug: "home", colorHex: "#4FB286")

        try store.save(work)
        try store.save(home)
        try store.save(AppStateFile(spaceOrder: [work.id, home.id], selectedSpaceID: home.id))

        let loaded = store.load()
        #expect(loaded.errors.isEmpty)
        #expect(loaded.spaces == [work, home])
        #expect(loaded.state.selectedSpaceID == home.id)
        #expect(FileManager.default.fileExists(atPath: paths.spaceFile("work").path))
    }

    @Test func historyKeepsLatestVisitPerURL() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let history = HistoryStore(file: paths.historyFile("work"))
        let a = URL(string: "https://a.com")!
        let b = URL(string: "https://b.com")!

        try history.append(HistoryEntry(date: Date(timeIntervalSince1970: 1), url: a, title: "A old"))
        try history.append(HistoryEntry(date: Date(timeIntervalSince1970: 2), url: b, title: "B"))
        try history.append(HistoryEntry(date: Date(timeIntervalSince1970: 3), url: a, title: "A new"))

        let entries = history.load()
        #expect(entries.map(\.title) == ["A new", "B"])
        #expect(history.load(limit: 1).map(\.title) == ["A new"])
    }
}
