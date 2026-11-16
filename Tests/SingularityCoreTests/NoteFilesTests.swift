import Foundation
import Testing
@testable import SingularityCore

@Suite struct NoteFilesTests {
    // MARK: Names

    @Test func aTitleIsTheFileNameWithoutItsExtension() {
        #expect(NoteFiles.title(ofPath: "Shopping.md") == "Shopping")
        #expect(NoteFiles.title(ofPath: "Journal/2026-11-16.md") == "2026-11-16")
        #expect(NoteFiles.title(ofPath: "/Users/me/repo/README.markdown") == "README")
        #expect(NoteFiles.title(ofPath: "v1.2 plan.MD") == "v1.2 plan")
        #expect(NoteFiles.folder(ofPath: "Journal/2026/x.md") == "Journal/2026")
        #expect(NoteFiles.folder(ofPath: "x.md") == "")
    }

    @Test func aTypedTitleBecomesAUsableFileName() {
        #expect(NoteFiles.fileName(forTitle: "  Shopping list ") == "Shopping list")
        #expect(NoteFiles.fileName(forTitle: "a/b: c") == "a-b- c")
        #expect(NoteFiles.fileName(forTitle: "..hidden") == "hidden")
        #expect(NoteFiles.fileName(forTitle: "line\nbreak\u{0}") == "linebreak")
        #expect(NoteFiles.fileName(forTitle: "Õhtusöök 🍲") == "Õhtusöök 🍲")
        #expect(NoteFiles.fileName(forTitle: "   ") == nil)
        #expect(NoteFiles.fileName(forTitle: ".") == nil)
        #expect(NoteFiles.fileName(forTitle: String(repeating: "x", count: 300))?.count == 120)
    }

    @Test func aNewNoteGetsAFreeName() {
        #expect(NoteFiles.freePath(taken: []) == "Untitled.md")
        #expect(NoteFiles.freePath(taken: ["untitled.md"]) == "Untitled 2.md")
        #expect(NoteFiles.freePath(taken: ["Untitled.md", "Untitled 2.md", "Untitled 4.md"]) == "Untitled 3.md")
        #expect(NoteFiles.freePath(title: "Plan", folder: "Work", taken: ["Work/Plan.md"]) == "Work/Plan 2.md")
        // The same name in another folder is not in the way.
        #expect(NoteFiles.freePath(title: "Plan", folder: "Work", taken: ["Plan.md"]) == "Work/Plan.md")
    }

    @Test func aRenameKeepsTheFolderAndTheExtension() {
        #expect(NoteFiles.renamedPath("Journal/2026-11-16.md", title: "Monday") == "Journal/Monday.md")
        #expect(NoteFiles.renamedPath("README.markdown", title: "Read me") == "Read me.markdown")
        #expect(NoteFiles.renamedPath("a.md", title: " / ") == "-.md")
        #expect(NoteFiles.renamedPath("a.md", title: "  ") == nil)
    }

    @Test func todaysNoteIsNamedByItsDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Tallinn")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59))!
        #expect(NoteFiles.todayPath(date: date, calendar: calendar) == "Journal/2026-03-07.md")
        #expect(NoteFiles.imageName(extension: "PNG", date: date, calendar: calendar, suffix: "ab12") == "2026-03-07-ab12.png")
        #expect(NoteFiles.imageName(extension: "svg", date: date, calendar: calendar, suffix: "ab12") == nil)
        #expect(NoteFiles.imageName(extension: "", date: date, calendar: calendar, suffix: "ab12") == nil)
    }

    // MARK: Paths

    @Test func onlyPlainMarkdownPathsAreValid() {
        for good in ["a.md", "Journal/2026-11-16.md", "a b/c d.markdown", "x.MD"] {
            #expect(NoteFiles.isValidPath(good), "\(good)")
        }
        for bad in ["", "a.txt", "a", "/etc/x.md", "../x.md", "a/../x.md", "a/./x.md", ".x.md", ".git/x.md", "a//x.md",
                    "a/.hidden/x.md", "x.md\0", "a/"] {
            #expect(!NoteFiles.isValidPath(bad), "\(bad)")
        }
    }

    @Test func aNotesFileStaysInsideItsFolder() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let root = folder.url.appending(path: "notes")
        let outside = folder.url.appending(path: "outside")
        try FileManager.default.createDirectory(at: root.appending(path: "Journal"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "secret.md"))
        try Data("x".utf8).write(to: root.appending(path: "a.md"))

        // An existing note, a new note, and a new note in a folder that doesn't exist yet.
        #expect(NoteFiles.file(forPath: "a.md", root: root)?.lastPathComponent == "a.md")
        #expect(NoteFiles.file(forPath: "new.md", root: root) != nil)
        #expect(NoteFiles.file(forPath: "New Folder/Deep/new.md", root: root) != nil)
        #expect(NoteFiles.file(forPath: "../outside/secret.md", root: root) == nil)

        // A link to a file outside, a link to a folder outside, a dangling link: all refused.
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.md"), withDestinationURL: outside.appending(path: "secret.md"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Out"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "dangling.md"), withDestinationURL: outside.appending(path: "nothing.md"))
        #expect(NoteFiles.file(forPath: "link.md", root: root) == nil)
        #expect(NoteFiles.file(forPath: "Out/secret.md", root: root) == nil)
        #expect(NoteFiles.file(forPath: "Out/new.md", root: root) == nil)
        #expect(NoteFiles.file(forPath: "dangling.md", root: root) == nil)
        // A folder named like a note is not a note.
        try FileManager.default.createDirectory(at: root.appending(path: "folder.md"), withIntermediateDirectories: true)
        #expect(NoteFiles.file(forPath: "folder.md", root: root) == nil)

        // A link inside the folder to another note inside it is fine.
        try FileManager.default.createSymbolicLink(at: root.appending(path: "alias.md"), withDestinationURL: root.appending(path: "a.md"))
        #expect(NoteFiles.file(forPath: "alias.md", root: root)?.lastPathComponent == "a.md")
    }

    @Test func aNotesPicturesComeFromItsOwnFolderOnly() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let root = folder.url.appending(path: "notes")
        try FileManager.default.createDirectory(at: root.appending(path: "Journal/assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: root.appending(path: "assets/top.png"))
        try Data("png".utf8).write(to: root.appending(path: "Journal/assets/day.png"))
        try Data("text".utf8).write(to: root.appending(path: "assets/notes.txt"))
        try Data("png".utf8).write(to: folder.url.appending(path: "outside.png"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "assets/link.png"), withDestinationURL: folder.url.appending(path: "outside.png"))

        #expect(NoteFiles.imageFile(source: "assets/top.png", notePath: "a.md", root: root) != nil)
        // Relative to the note's own folder.
        #expect(NoteFiles.imageFile(source: "assets/day.png", notePath: "Journal/x.md", root: root) != nil)
        #expect(NoteFiles.imageFile(source: "assets/top.png", notePath: "Journal/x.md", root: root) == nil)
        for bad in ["../outside.png", "assets/../../outside.png", "/etc/x.png", "https://example.com/a.png", "assets/notes.txt",
                    "assets/missing.png", "assets/link.png", "assets/.hidden.png", "assets", "assets\\top.png", "file:///x.png"] {
            #expect(NoteFiles.imageFile(source: bad, notePath: "a.md", root: root) == nil, "\(bad)")
        }

        #expect(NoteFiles.newImageFile(name: "2026-11-16-ab.png", notePath: "Journal/x.md", root: root)?.path.hasSuffix("/notes/Journal/assets/2026-11-16-ab.png") == true)
        #expect(NoteFiles.newImageFile(name: "../x.png", notePath: "a.md", root: root) == nil)
        #expect(NoteFiles.newImageFile(name: "x.sh", notePath: "a.md", root: root) == nil)
    }

    @Test func theListIsNewestFirstAndSkipsPicturesAndHiddenFiles() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let root = folder.url
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "Journal/assets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        func write(_ path: String, age: TimeInterval) throws {
            let file = root.appending(path: path)
            try Data("x".utf8).write(to: file)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        }
        try write("old.md", age: 3000)
        try write("Journal/2026-11-16.md", age: 10)
        try write("mid.markdown", age: 500)
        try write("Journal/assets/readme.md", age: 1)
        try write(".hidden.md", age: 1)
        try write(".git/x.md", age: 1)
        try write("picture.png", age: 1)

        #expect(NoteFiles.list(in: root).map(\.path) == ["Journal/2026-11-16.md", "mid.markdown", "old.md"])
        #expect(NoteFiles.list(in: root.appending(path: "nothing-here")).isEmpty)
    }

    // MARK: Files from elsewhere

    @Test func aFileFromElsewhereWorksInsideItsOwnFolder() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let notes = folder.url.appending(path: "space/notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let repo = folder.url.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repo.appending(path: "README.md"))
        try Data("x".utf8).write(to: notes.appending(path: "Inside.md"))
        try Data("x".utf8).write(to: repo.appending(path: "main.swift"))

        // A file inside the Space's notes folder is that note, by its relative path.
        #expect(NoteFiles.tabPath(forFile: notes.appending(path: "Inside.md"), notesRoot: notes) == "Inside.md")
        let outside = try #require(NoteFiles.tabPath(forFile: repo.appending(path: "README.md"), notesRoot: notes))
        #expect(NoteFiles.isOutside(outside))
        #expect(outside.hasSuffix("/repo/README.md"))
        #expect(NoteFiles.tabPath(forFile: repo.appending(path: "main.swift"), notesRoot: notes) == nil)
        #expect(NoteFiles.tabPath(forFile: repo.appending(path: ".hidden.md"), notesRoot: notes) == nil)

        let location = NoteFiles.location(tabPath: outside, notesRoot: notes)
        #expect(location.path == "README.md")
        #expect(location.root.path.hasSuffix("/repo"))
        #expect(NoteFiles.location(tabPath: "Journal/x.md", notesRoot: notes) == .init(root: notes, path: "Journal/x.md"))

        #expect(NoteFiles.tabPath(renamed: "Read me.md", from: outside).hasSuffix("/repo/Read me.md"))
        #expect(NoteFiles.tabPath(renamed: "Journal/y.md", from: "Journal/x.md") == "Journal/y.md")

        #expect(NoteFiles.subtitle(tabPath: "Journal/x.md") == "notes/Journal/x.md")
        #expect(NoteFiles.subtitle(tabPath: "/Users/me/repo/README.md", home: "/Users/me") == "~/repo/README.md")
        #expect(NoteFiles.subtitle(tabPath: "/opt/README.md", home: "/Users/me") == "/opt/README.md")
    }

    // MARK: Saving

    @Test func aSaveNeverOverwritesAFileThatChangedUnderneath() {
        #expect(NoteFiles.saveDecision(known: "a", onDisk: "a", force: false) == .write)
        #expect(NoteFiles.saveDecision(known: "a", onDisk: "b", force: false) == .conflict)
        // The editor loaded no file, but one is there now.
        #expect(NoteFiles.saveDecision(known: nil, onDisk: "b", force: false) == .conflict)
        // No file: nothing to lose.
        #expect(NoteFiles.saveDecision(known: "a", onDisk: nil, force: false) == .write)
        #expect(NoteFiles.saveDecision(known: nil, onDisk: nil, force: false) == .write)
        // "Keep Mine".
        #expect(NoteFiles.saveDecision(known: "a", onDisk: "b", force: true) == .write)
    }

    // MARK: The tab

    @Test func aNoteTabIsStoredAndHiddenFromAgents() throws {
        let tab = BrowserTab.note(path: "Journal/2026-11-16.md")
        #expect(tab.displayTitle == "2026-11-16")
        #expect(tab.isNote && tab.isHiddenFromAgents && !tab.isTerminal && tab.url == nil)
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)
        #expect(BrowserTab.web(URL(string: "https://example.com")!).isHiddenFromAgents == false)
        #expect(BrowserTab.plugin(pluginID: "x").isHiddenFromAgents)
    }
}

private struct TempFolder {
    let url: URL
    init() throws {
        // Resolved, so paths compare equal after symlinks are followed (/tmp is a link on macOS).
        url = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appending(path: "sg-notes-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}
