import Foundation
import Testing
@testable import SingularityCore

/// Projects in a Space: where a new terminal starts, when to ask, and what the sidebar shows.
@Suite struct ProjectTests {
    struct Fixture {
        var space: Space
        let web: Project, docs: Project
        let task: Folder, inner: Folder, loose: Folder
    }

    /// "Work" with projects web and docs; folder `task` (project web) holding folder `inner`
    /// (no project of its own); folder `loose` (no project).
    func make() -> Fixture {
        let web = Project(name: "acme-web", path: "~/Developer/acme-web")
        let docs = Project(name: "acme-docs", path: "~/Developer/acme-docs")
        let task = Folder(name: "Task", projectID: web.id)
        let inner = Folder(name: "Inner", parentID: task.id)
        let loose = Folder(name: "Loose")
        let space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~/Developer",
                          folders: [task, inner, loose], projects: [web, docs])
        return Fixture(space: space, web: web, docs: docs, task: task, inner: inner, loose: loose)
    }

    func terminal(project: UUID?, folder: UUID?) -> BrowserTab {
        var tab = BrowserTab.terminal(workingDirectory: "~/somewhere")
        tab.projectID = project
        tab.folderID = folder
        return tab
    }

    /// Encodes `value`, removes `keys` from the JSON object, and returns the data: a file as an
    /// older version of the app wrote it.
    func json<T: Encodable>(_ value: T, without keys: [String]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for key in keys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func oldFilesStillLoad() throws {
        var f = make()
        f.space.lastProjectID = f.docs.id
        f.space.append(terminal(project: f.web.id, folder: f.task.id))

        let oldSpace = try JSONDecoder().decode(Space.self, from: json(f.space, without: ["projects", "lastProjectID"]))
        #expect(oldSpace.projects.isEmpty && oldSpace.lastProjectID == nil)
        let oldFolder = try JSONDecoder().decode(Folder.self, from: json(f.task, without: ["projectID"]))
        #expect(oldFolder.projectID == nil && oldFolder.name == "Task")
        let oldTab = try JSONDecoder().decode(BrowserTab.self, from: json(f.space.tabs[0], without: ["projectID"]))
        #expect(oldTab.projectID == nil && oldTab.isTerminal)

        let again = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(f.space))
        #expect(again == f.space)
        #expect(again.projects == [f.web, f.docs] && again.lastProjectID == f.docs.id)
        #expect(again.folders[0].projectID == f.web.id && again.tabs[0].projectID == f.web.id)
    }

    @Test func effectiveProject() {
        let f = make()
        #expect(f.space.effectiveProject(ofFolder: f.task.id) == f.web)
        #expect(f.space.effectiveProject(ofFolder: f.inner.id) == f.web)
        #expect(f.space.effectiveProject(ofFolder: f.loose.id) == nil)
        #expect(f.space.effectiveProject(ofFolder: nil) == nil)
        #expect(f.space.ownProject(ofFolder: f.task.id) == f.web)
        #expect(f.space.ownProject(ofFolder: f.inner.id) == nil)
    }

    @Test func effectiveProjectSurvivesBrokenTree() {
        var f = make()
        var a = Folder(name: "A"), b = Folder(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        let orphan = Folder(name: "Orphan", parentID: UUID())
        f.space.folders += [a, b, orphan]
        #expect(f.space.effectiveProject(ofFolder: a.id) == nil)
        #expect(f.space.effectiveProject(ofFolder: orphan.id) == nil)
    }

    @Test func terminalStartTable() {
        let f = make()
        let web = TerminalStart.start(directory: "~/Developer/acme-web", projectID: f.web.id)
        #expect(f.space.terminalStart(inFolder: f.task.id, alwaysAsk: false) == web)
        #expect(f.space.terminalStart(inFolder: f.inner.id, alwaysAsk: false) == web)
        #expect(f.space.terminalStart(inFolder: f.loose.id, alwaysAsk: false) == .ask)
        #expect(f.space.terminalStart(inFolder: nil, alwaysAsk: false) == .ask)
        #expect(f.space.terminalStart(inFolder: f.task.id, alwaysAsk: true) == .ask)

        // A Space without projects never asks.
        var plain = f.space
        plain.setProjects([])
        let spaceFolder = TerminalStart.start(directory: "~/Developer", projectID: nil)
        for folder in [f.task.id, f.inner.id, f.loose.id, nil] {
            #expect(plain.terminalStart(inFolder: folder, alwaysAsk: false) == spaceFolder)
            #expect(plain.terminalStart(inFolder: folder, alwaysAsk: true) == spaceFolder)
        }
    }

    @Test func ghostFolderMeansNoFolder() throws {
        var f = make()
        let ghost = UUID()
        var tab = BrowserTab.web(URL(string: "https://example.com")!)
        tab.folderID = ghost
        f.space.append(tab)
        f.space.selectedTabID = tab.id
        #expect(f.space.folderForNewTerminal == nil)

        let id = f.space.addTerminal(directory: "~", projectID: nil, inFolder: ghost, select: true)
        #expect(try #require(f.space.tab(id)).folderID == nil)

        // And the ordinary case: the selected tab's folder.
        let looseID = f.loose.id
        f.space.updateTab(tab.id) { $0.folderID = looseID }
        f.space.selectedTabID = tab.id // the terminal added above took the selection
        #expect(f.space.folderForNewTerminal == f.loose.id)
        f.space.selectedTabID = nil
        #expect(f.space.folderForNewTerminal == nil)
    }

    @Test func addTerminalPlacesAndSelects() throws {
        var f = make()
        let first = f.space.addTerminal(directory: "~/Developer/acme-web", projectID: f.web.id, inFolder: f.task.id, select: true)
        let tab = try #require(f.space.tab(first))
        #expect(tab.folderID == f.task.id && !tab.isPinned)
        #expect(tab.projectID == f.web.id && tab.workingDirectory == "~/Developer/acme-web")
        #expect(f.space.selectedTabID == first)

        let second = f.space.addTerminal(directory: "~", projectID: nil, inFolder: nil, select: false)
        #expect(f.space.selectedTabID == first)
        #expect(try #require(f.space.tab(second)).section == .open)
    }

    @Test func pickerOrder() {
        var f = make()
        #expect(f.space.projectChoices.map(\.name) == ["acme-web", "acme-docs", "Space folder"])
        f.space.lastProjectID = UUID() // points at nothing
        #expect(f.space.projectChoices.map(\.name) == ["acme-web", "acme-docs", "Space folder"])
        f.space.lastProjectID = f.docs.id
        let choices = f.space.projectChoices
        #expect(choices.map(\.name) == ["acme-docs", "acme-web", "Space folder"])
        #expect(choices.map(\.projectID) == [f.docs.id, f.web.id, nil])
        #expect(choices.map(\.path) == ["~/Developer/acme-docs", "~/Developer/acme-web", "~/Developer"])
        #expect(Set(choices.map(\.id)).count == 3)
    }

    @Test func recordPickerChoice() {
        var f = make()
        f.space.recordPickerChoice(f.docs.id, adoptForFolder: nil)
        #expect(f.space.lastProjectID == f.docs.id)
        // "Space folder" is not remembered and never becomes a folder's project.
        f.space.recordPickerChoice(nil, adoptForFolder: f.loose.id)
        #expect(f.space.lastProjectID == f.docs.id)
        #expect(f.space.folder(f.loose.id)?.projectID == nil)
        // A folder that already has a project (its own or an enclosing folder's) keeps it.
        f.space.recordPickerChoice(f.docs.id, adoptForFolder: f.task.id)
        f.space.recordPickerChoice(f.docs.id, adoptForFolder: f.inner.id)
        #expect(f.space.folder(f.task.id)?.projectID == f.web.id)
        #expect(f.space.folder(f.inner.id)?.projectID == nil)
        // A folder without one takes the choice.
        f.space.recordPickerChoice(f.web.id, adoptForFolder: f.loose.id)
        #expect(f.space.folder(f.loose.id)?.projectID == f.web.id)
        #expect(f.space.lastProjectID == f.web.id)
        // A choice that is no project of this Space changes nothing.
        f.space.recordPickerChoice(UUID(), adoptForFolder: nil)
        #expect(f.space.lastProjectID == f.web.id)
    }

    @Test func splitRule() {
        var f = make()
        let docsInTask = terminal(project: f.docs.id, folder: f.task.id)
        var page = BrowserTab.web(URL(string: "https://example.com")!)
        page.folderID = f.task.id
        let plainInTabs = terminal(project: nil, folder: nil)
        let plainInTask = terminal(project: nil, folder: f.task.id)
        for tab in [docsInTask, page, plainInTabs, plainInTask] { f.space.append(tab) }

        func start(_ tab: BrowserTab) -> String { f.space.splitTerminalStart(beside: tab.id).directory }
        #expect(start(docsInTask) == "~/Developer/acme-docs")
        #expect(f.space.splitTerminalStart(beside: docsInTask.id).projectID == f.docs.id)
        #expect(start(page) == "~/Developer/acme-web")
        #expect(f.space.splitTerminalStart(beside: page.id).projectID == f.web.id)
        #expect(start(plainInTabs) == "~/Developer")
        // Beside a terminal with no project it is the Space folder, whatever folder that terminal is in.
        #expect(start(plainInTask) == "~/Developer")
        #expect(f.space.splitTerminalStart(beside: plainInTask.id).projectID == nil)
        #expect(start(BrowserTab.terminal(workingDirectory: "~")) == "~/Developer") // a tab that isn't in the Space
    }

    @Test func tagRule() {
        let f = make()
        // In a folder whose project is the same: the folder header already says it.
        let same = terminal(project: f.web.id, folder: f.task.id)
        #expect(f.space.projectTag(of: same) == nil)
        #expect(f.space.projectName(of: same) == "acme-web")
        #expect(f.space.projectTag(of: terminal(project: f.web.id, folder: f.inner.id)) == nil)
        #expect(f.space.projectTag(of: terminal(project: f.docs.id, folder: f.task.id)) == "acme-docs")
        #expect(f.space.projectTag(of: terminal(project: f.web.id, folder: nil)) == "acme-web")
        #expect(f.space.projectTag(of: terminal(project: f.web.id, folder: f.loose.id)) == "acme-web")
        #expect(f.space.projectTag(of: terminal(project: nil, folder: f.task.id)) == nil)
        // Only terminals have a project.
        var page = BrowserTab.web(URL(string: "https://example.com")!)
        page.projectID = f.web.id
        #expect(f.space.projectTag(of: page) == nil && f.space.projectName(of: page) == nil)
    }

    @Test func removingAProjectScrubsEverything() {
        var f = make()
        let webTab = terminal(project: f.web.id, folder: nil), docsTab = terminal(project: f.docs.id, folder: nil)
        f.space.append(webTab)
        f.space.append(docsTab)
        f.space.setFolderProject(f.loose.id, f.docs.id)
        f.space.lastProjectID = f.web.id

        var renamed = f.docs
        renamed.name = "handbook"
        f.space.setProjects([renamed])
        #expect(f.space.projects == [renamed])
        #expect(f.space.folder(f.task.id)?.projectID == nil)
        #expect(f.space.folder(f.loose.id)?.projectID == f.docs.id)
        #expect(f.space.tab(webTab.id)?.projectID == nil)
        #expect(f.space.tab(docsTab.id)?.projectID == f.docs.id)
        #expect(f.space.lastProjectID == nil)
        // The rename shows everywhere.
        #expect(f.space.projectTag(of: f.space.tab(docsTab.id)!) == "handbook")
    }

    @Test func danglingIDsCountAsNil() {
        var f = make()
        let unknown = UUID()
        f.space.folders[0].projectID = unknown // `task`, set by hand as a damaged file would have it
        #expect(f.space.project(unknown) == nil && f.space.project(nil) == nil)
        #expect(f.space.effectiveProject(ofFolder: f.task.id) == nil)
        #expect(f.space.terminalStart(inFolder: f.task.id, alwaysAsk: false) == .ask)
        #expect(f.space.projectTag(of: terminal(project: unknown, folder: nil)) == nil)
        // `setFolderProject` refuses an id that is no project of this Space.
        f.space.setFolderProject(f.loose.id, unknown)
        #expect(f.space.folder(f.loose.id)?.projectID == nil)
        f.space.setFolderProject(f.loose.id, f.docs.id)
        f.space.setFolderProject(f.loose.id, nil)
        #expect(f.space.folder(f.loose.id)?.projectID == nil)
    }

    @Test func emptyNameFallsBackToFolderName() {
        #expect(Project(name: "  ", path: "~/Developer/acme-web").displayName == "acme-web")
        #expect(Project(name: " Web ", path: "~/Developer/acme-web").displayName == "Web")
        #expect(Project(name: "", path: "~/Developer/acme-web/").displayName == "acme-web")
        #expect(Project(name: "", path: "~").displayName == "Home")
        #expect(Project(name: "", path: "/").displayName == "/")

        // Two projects with the same name are both offered.
        var f = make()
        f.space.setProjects([f.web, Project(name: "acme-web", path: "~/Other/acme-web")])
        #expect(f.space.projectChoices.map(\.name) == ["acme-web", "acme-web", "Space folder"])
        #expect(Set(f.space.projectChoices.map(\.id)).count == 3)
    }
}
