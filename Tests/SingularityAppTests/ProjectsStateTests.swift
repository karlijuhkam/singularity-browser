import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// Projects through the real `AppState`: when New Terminal asks, what the picker lists, and
/// that the choices are saved. No test here opens a terminal (that would start a login shell);
/// what a start creates is covered by Core's `ProjectTests`.
@MainActor
@Suite(.serialized) struct ProjectsStateTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let web: Project, docs: Project
        let task: Folder, loose: Folder
        let looseTab: UUID, openTab: UUID
        var space: Space { state.selectedSpace! }
    }

    /// One Space with projects web and docs, folder `task` (project web), folder `loose` (none),
    /// a web page in `loose` and one in Tabs (selected).
    func make() throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let web = Project(name: "acme-web", path: "~/Developer/acme-web")
        let docs = Project(name: "acme-docs", path: "~/Developer/acme-docs")
        let task = Folder(name: "Task", projectID: web.id), loose = Folder(name: "Loose")
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~/Developer",
                          folders: [task, loose], projects: [web, docs], lastProjectID: docs.id)
        var inLoose = BrowserTab.web(URL(string: "https://example.com/loose")!)
        inLoose.folderID = loose.id
        let open = BrowserTab.web(URL(string: "https://example.com/open")!)
        space.append(inLoose)
        space.append(open)
        space.selectedTabID = open.id
        try SpaceStore(paths: Paths(root: root)).save(space)
        let state = TestAppState.make(root: root)
        return Fixture(root: root, state: state, web: web, docs: docs, task: task, loose: loose,
                       looseTab: inLoose.id, openTab: open.id)
    }

    func finish(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    @Test func outsideAFolderAsks() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openTerminal()
        #expect(f.state.palette == .newTerminalIn(folderID: nil, adoptForFolder: false))
        #expect(f.space.tabs.count == 2)
    }

    @Test func inALooseFolderAsksAndWouldAdopt() throws {
        let f = try make()
        defer { finish(f) }
        f.state.selectTab(f.looseTab)
        f.state.openTerminal()
        #expect(f.state.palette == .newTerminalIn(folderID: f.loose.id, adoptForFolder: true))
        // "New Terminal in…" never changes the folder's project.
        f.state.palette = nil
        f.state.openTerminalChoosingProject()
        #expect(f.state.palette == .newTerminalIn(folderID: f.loose.id, adoptForFolder: false))
        // From a folder header: that folder, whatever is selected.
        f.state.palette = nil
        f.state.selectTab(f.openTab)
        f.state.openTerminal(inFolder: f.loose.id)
        #expect(f.state.palette == .newTerminalIn(folderID: f.loose.id, adoptForFolder: true))
        #expect(f.space.tabs.count == 2)
    }

    @Test func pickerRows() throws {
        let f = try make()
        defer { finish(f) }
        let mode = PaletteMode.newTerminalIn(folderID: nil, adoptForFolder: false)
        let rows = PaletteResults.items(for: "", mode: mode, state: f.state)
        #expect(rows.map(\.title) == ["acme-docs", "acme-web", "Space folder"]) // docs was used last
        #expect(rows.map(\.subtitle) == ["~/Developer/acme-docs", "~/Developer/acme-web", "~/Developer"])
        #expect(rows.map(\.hint) == ["Last used", "", ""])

        let filtered = PaletteResults.items(for: "docs", mode: mode, state: f.state)
        #expect(filtered.map(\.title) == ["acme-docs"])

        // The ordinary palette offers "New Terminal in…" because this Space has projects.
        let commands = PaletteResults.items(for: "", mode: .newTab, state: f.state)
        #expect(commands.contains { $0.id == "cmd-new-terminal-in" })
        f.state.setProjects([], spaceID: f.space.id)
        #expect(!PaletteResults.items(for: "", mode: .newTab, state: f.state).contains { $0.id == "cmd-new-terminal-in" })
    }

    @Test func pickerWithNoMatchOpensNothing() throws {
        let f = try make()
        defer { finish(f) }
        let mode = PaletteMode.newTerminalIn(folderID: nil, adoptForFolder: false)
        // Not a project, and in this mode text is never a URL or a web search.
        #expect(PaletteResults.items(for: "zzzz", mode: mode, state: f.state).isEmpty)
        #expect(PaletteResults.items(for: "example.com", mode: mode, state: f.state).isEmpty)
    }

    @Test func folderProjectAndProjectListAreSaved() throws {
        let f = try make()
        defer { finish(f) }
        let spaceID = f.space.id
        f.state.setFolderProject(f.loose.id, f.docs.id)
        #expect(f.space.folder(f.loose.id)?.projectID == f.docs.id)

        // Removing web clears the folder that pointed at it.
        f.state.setProjects([f.docs], spaceID: spaceID)
        #expect(f.space.projects == [f.docs])
        #expect(f.space.folder(f.task.id)?.projectID == nil)

        f.state.flushSaves()
        let loaded = try #require(SpaceStore(paths: Paths(root: f.root)).load().spaces.first { $0.id == spaceID })
        #expect(loaded.projects == [f.docs])
        #expect(loaded.folder(f.loose.id)?.projectID == f.docs.id)
    }
}
}
