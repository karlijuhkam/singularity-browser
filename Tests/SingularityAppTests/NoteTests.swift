import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

// The built editor in the repository (scripts/build-note-editor.sh writes it; it is committed).
private let editorFolder = TestAppState.repositoryRoot.appending(path: "Resources/note-editor", directoryHint: .isDirectory)

extension AppTests {
/// Notes: the real editor page in a real `NoteHost`, in an off-screen window that never becomes
/// key, on files in a temporary folder.
@MainActor
@Suite(.serialized) struct NoteTests {
    // MARK: The server

    @Test func theServerGivesOnlyTheEditorAndTheNotesPictures() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("assets/pic.png", Data([0x89, 0x50, 0x4E, 0x47]))
        try folder.write("secret.txt", Data("secret".utf8))
        try folder.write("Other.md", Data("other".utf8))
        let location = NoteFiles.Location(root: folder.root, path: "Note.md")

        func fetch(_ path: String, method: String = "GET") async -> NotePageServer.Reply {
            var request = URLRequest(url: URL(string: "singularity-note://editor/" + path)!)
            request.httpMethod = method
            return await NotePageServer.reply(to: request, editorFolder: editorFolder, location: location)
        }
        #expect(await fetch("").contentType.hasPrefix("text/html"))
        #expect(await fetch("editor.js").status == 200)
        #expect(await fetch("editor.css").contentType.hasPrefix("text/css"))
        let picture = await fetch("file/assets/pic.png")
        #expect(picture.status == 200)
        #expect(picture.contentType == "image/png")
        for path in ["file/secret.txt", "file/Other.md", "file/../Note.md", "file/%2e%2e/x.png", "file/assets/missing.png",
                     "Other.md", "index.html", "editor.js.map", "file/"] {
            #expect(await fetch(path).status == 404, "\(path)")
        }
        #expect(await fetch("editor.js", method: "POST").status == 405)
        let policy = await fetch("").response(for: NotePageServer.rootURL).value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        #expect(policy.contains("default-src 'none'") && policy.contains("connect-src 'none'") && policy.contains("script-src 'self';"))
    }

    // MARK: The editor

    @Test func aNoteLoadsIsEditedAndSavedAsMarkdown() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        let source = """
            # Groceries

            - [ ] milk
            - [x] bread
              - [ ] rye

            1. first
            2. second

            > a quote

            | a | b |
            | --- | --- |
            | 1 | 2 |

            Some **bold**, *italic* and a [link](https://example.com).
            """
        try folder.write("List.md", Data(source.utf8))
        let (host, window) = try await open(folder, "List.md")
        defer { close(host, window) }

        // What the editor shows: real blocks, not Markdown text.
        #expect(try await js(host, "document.querySelector('#title').textContent") as? String == "List")
        #expect(try await js(host, "document.querySelectorAll('.note ul[data-type=taskList] input[type=checkbox]').length") as? Int == 3)
        #expect(try await js(host, "document.querySelectorAll('.note input:checked').length") as? Int == 1)
        #expect(try await js(host, "document.querySelector('.note h1').textContent") as? String == "Groceries")
        #expect(try await js(host, "document.querySelectorAll('.note table td').length") as? Int == 2)
        #expect(try await js(host, "document.querySelector('.note a').getAttribute('href')") as? String == "https://example.com")

        // Loading alone writes nothing, however the editor would spell the Markdown.
        try await Task.sleep(for: .milliseconds(700))
        #expect(try folder.read("List.md") == source)

        // Typing saves by itself, a moment later.
        #expect(try await js(host, "window.__noteTest.insert('<p>eggs and butter</p>')") as? Bool == true)
        try await waitUntil("the save") { (try? folder.read("List.md"))?.contains("eggs and butter") == true }
        let saved = try folder.read("List.md")
        for piece in ["# Groceries", "- [ ] milk", "- [x] bread", "  - [ ] rye", "1. first", "> a quote", "**bold**", "*italic*",
                      "[link](https://example.com)", "| 1"] {
            #expect(saved.contains(piece), "\(piece) is missing from:\n\(saved)")
        }

        // Ticking a to-do item is an edit like any other.
        _ = try await js(host, "document.querySelector('.note input[type=checkbox]').click()")
        try await waitUntil("the tick to be saved") { (try? folder.read("List.md"))?.contains("- [x] milk") == true }
    }

    @Test func whatANoteSaysNeverBecomesMarkupOrARequest() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("assets/local.png", try #require(Self.onePixelPNG))
        try folder.write("Evil.md", Data("""
            <img src=x onerror="window.pwned = 1">

            <script>window.pwned = 2</script>

            Text <b onmouseover="window.pwned = 3">bold?</b> [click](javascript:window.pwned=4)

            ![remote](https://example.com/track.png)

            ![local](assets/local.png)
            """.utf8))
        let (host, window) = try await open(folder, "Evil.md")
        defer { close(host, window) }
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await js(host, "window.pwned === undefined") as? Bool == true)
        // The HTML is there as the text it is.
        #expect(try await js(host, "document.querySelector('.note').textContent.includes('<script>window.pwned = 2</script>')") as? Bool == true)
        #expect(try await js(host, "document.querySelectorAll('.note script, .note b, .note [onerror], .note [onmouseover]').length") as? Int == 0)
        #expect(try await js(host, "document.querySelectorAll('.note a[href^=javascript]').length") as? Int == 0)
        // A picture on the web is not asked for; the note's own picture is shown from its folder.
        #expect(try await js(host, "document.querySelector('.note img[data-remote]').getAttribute('src')") is NSNull)
        #expect(try await js(host, "document.querySelector('.note img:not([data-remote])').getAttribute('src')") as? String == "/file/assets/local.png")
        try await pollUntil("the local picture") {
            self.cached["w"] != nil
        } poll: {
            self.cached["w"] = (try? await self.js(host, "document.querySelector('.note img:not([data-remote])').naturalWidth")) as? Int == 1 ? 1 : nil
        }
        // And the page has no network at all.
        let fetched = try await js(host, "fetch('https://example.com/').then(() => 'reached', () => 'blocked')")
        #expect(fetched as? String == "blocked")
    }

    @Test func theTitleRenamesTheFile() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("Journal/Draft.md", Data("hello".utf8))
        try folder.write("Journal/Taken.md", Data("taken".utf8))
        let (host, window) = try await open(folder, "Journal/Draft.md")
        defer { close(host, window) }
        var renamedTo: [String] = []
        host.onRename = { renamedTo.append($0) }

        #expect(try await js(host, "return await window.__noteTest.setTitle('Monday: plans / ideas')") as? String == "Monday- plans - ideas")
        #expect(renamedTo == ["Journal/Monday- plans - ideas.md"])
        #expect(try folder.read("Journal/Monday- plans - ideas.md") == "hello")
        #expect(!folder.exists("Journal/Draft.md"))
        #expect(host.location.path == "Journal/Monday- plans - ideas.md")

        // Never onto another note: the title goes back and the strip says why.
        #expect(try await js(host, "return await window.__noteTest.setTitle('taken')") as? String == "Monday- plans - ideas")
        #expect((try await js(host, "window.__noteTest.stripText()") as? String)?.contains("already there") == true)
        #expect(try folder.read("Journal/Taken.md") == "taken")
        #expect(renamedTo.count == 1)

        // Saving after the rename goes to the new file.
        _ = try await js(host, "window.__noteTest.insert(' world')")
        try await waitUntil("the save") { (try? folder.read("Journal/Monday- plans - ideas.md"))?.contains("world") == true }
        #expect(!folder.exists("Journal/Draft.md"))
    }

    @Test func aFileChangedByAnotherProgramIsNeverOverwrittenUnasked() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("Shared.md", Data("first".utf8))
        let (host, window) = try await open(folder, "Shared.md")
        defer { close(host, window) }

        // Nothing typed: the new text simply shows.
        try folder.write("Shared.md", Data("second, from an agent".utf8))
        host.fileChangedOnDisk()
        try await pollUntil("the reload") {
            self.cached["t"] == 1
        } poll: {
            self.cached["t"] = ((try? await self.js(host, "document.querySelector('.note').textContent")) as? String) == "second, from an agent" ? 1 : nil
        }

        // Typed, and the file changes before the save: the save is refused and the owner is asked.
        try folder.write("Shared.md", Data("third, from an agent".utf8))
        _ = try await js(host, "window.__noteTest.insert(' and mine')")
        try await pollUntil("the question") {
            self.cached["c"] == 1
        } poll: {
            self.cached["c"] = ((try? await self.js(host, "window.__noteTest.isConflicted()")) as? Bool) == true ? 1 : nil
        }
        #expect(try folder.read("Shared.md") == "third, from an agent")
        // More typing while the question is open still writes nothing.
        _ = try await js(host, "window.__noteTest.insert('!')")
        try await Task.sleep(for: .milliseconds(700))
        #expect(try folder.read("Shared.md") == "third, from an agent")

        // "Keep Mine" writes the editor's text.
        #expect(try await js(host, "window.__noteTest.pressStripButton('Keep Mine')") as? Bool == true)
        try await waitUntil("the kept text") { (try? folder.read("Shared.md"))?.contains("and mine!") == true }
        #expect(try await js(host, "window.__noteTest.stripText()") is NSNull)
    }

    @Test func closingWritesWhatWasJustTyped() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        let (host, window) = try await open(folder, "Quick.md")
        defer { close(host, window) }
        // No file yet: the strip says so, and typing makes it.
        #expect((try await js(host, "window.__noteTest.stripText()") as? String)?.contains("file is gone") == true)
        _ = try await js(host, "window.__noteTest.insert('typed just before closing')")
        await host.flush()   // at once, not after the editor's 0.4 s
        #expect(try folder.read("Quick.md").contains("typed just before closing"))
    }

    @Test func aPastedPictureIsSavedNextToTheNote() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("Journal/Day.md", Data("".utf8))
        let (host, window) = try await open(folder, "Journal/Day.md")
        defer { close(host, window) }
        let base64 = try #require(Self.onePixelPNG).base64EncodedString()
        let reply = try await js(host, """
            return await window.webkit.messageHandlers.singularityNote.postMessage({ type: "image", name: "Screenshot.PNG", base64: b })
            """, ["b": base64]) as? [String: Any]
        let source = try #require(reply?["src"] as? String)
        #expect(source.hasPrefix("assets/") && source.hasSuffix(".png"))
        #expect(folder.exists("Journal/" + source))
        // Not a picture, by its name: refused, nothing written.
        let refused = try? await js(host, """
            return await window.webkit.messageHandlers.singularityNote.postMessage({ type: "image", name: "run.sh", base64: b })
            """, ["b": base64])
        #expect(refused == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.root.appending(path: "Journal/assets").path).count == 1)
    }

    @Test func aLinkOpensOnlyAsAWebAddress() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("Links.md", Data("x".utf8))
        let (host, window) = try await open(folder, "Links.md")
        defer { close(host, window) }
        var opened: [URL] = []
        host.onOpenLink = { opened.append($0) }
        for link in ["https://example.com/a", "file:///etc/passwd", "javascript:alert(1)", "singularity-note://editor/", "http://localhost:3000"] {
            _ = try await js(host, "return await window.webkit.messageHandlers.singularityNote.postMessage({ type: 'open', url: u })", ["u": link])
        }
        #expect(opened.map(\.absoluteString) == ["https://example.com/a", "http://localhost:3000"])
    }

    // MARK: In the app

    @Test func notesAreTabsOfTheirSpace() async throws {
        let root = TestAppState.makeRoot()
        let state = TestAppState.make(root: root)
        defer {
            TestAppState.shutDown(state)
            try? FileManager.default.removeItem(at: root)
        }
        state.notes.editorFolder = editorFolder
        var trashed: [URL] = []
        state.trashFile = { trashed.append($0); try FileManager.default.removeItem(at: $0) }
        let space = try #require(state.selectedSpace)
        let notes = state.paths.notesDirectory(space.slug)

        state.newNote()
        state.newNote()
        var tabs = try #require(state.selectedSpace).tabs.filter(\.isNote)
        #expect(tabs.map(\.notePath) == ["Untitled.md", "Untitled 2.md"])
        #expect(FileManager.default.fileExists(atPath: notes.appending(path: "Untitled 2.md").path))
        #expect(state.selectedTab?.id == tabs[1].id)
        #expect(state.notes.existingHost(tabs[1].id) != nil)

        // Today's note: made once, found again.
        state.openTodayNote()
        let today = try #require(state.selectedTab)
        #expect(today.notePath == NoteFiles.todayPath())
        state.selectTab(tabs[0].id)
        state.openTodayNote()
        #expect(state.selectedTab?.id == today.id)
        #expect(try #require(state.selectedSpace).tabs.filter(\.isNote).count == 3)

        // The editor's rename moves the tab along.
        state.noteWasRenamed(tabID: tabs[0].id, spaceID: space.id, to: "Ideas.md")
        #expect(state.space(space.id)?.tab(tabs[0].id)?.notePath == "Ideas.md")
        #expect(state.space(space.id)?.tab(tabs[0].id)?.displayTitle == "Ideas")

        // A closed note is offered by the palette; an open one is not.
        state.closeTab(tabs[1].id)
        state.refreshPaletteNotes()
        // ("Untitled.md" is listed too: the rename above moved only the tab, not the file.)
        #expect(Set(state.paletteNotes) == ["Untitled 2.md", "Untitled.md"])
        #expect(state.notes.existingHost(tabs[1].id) == nil)

        // A Markdown file from elsewhere opens as a note too, by its absolute path.
        let elsewhere = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("# Read me".utf8).write(to: elsewhere.appending(path: "README.md"))
        try Data("x".utf8).write(to: elsewhere.appending(path: "main.swift"))
        let before = try #require(state.selectedSpace).tabs.count
        state.openMarkdownFile(elsewhere.appending(path: "main.swift"))
        #expect(try #require(state.selectedSpace).tabs.count == before)
        state.openMarkdownFile(elsewhere.appending(path: "README.md"))
        let readme = try #require(state.selectedTab)
        #expect(readme.displayTitle == "README")
        #expect(readme.notePath.map(NoteFiles.isOutside) == true)
        #expect(state.notes.existingHost(readme.id)?.location.path == "README.md")
        state.openMarkdownFile(elsewhere.appending(path: "README.md"))   // again: the same tab
        #expect(try #require(state.selectedSpace).tabs.count == before + 1)

        // Deleting moves the file away and closes the tab.
        tabs = try #require(state.selectedSpace).tabs.filter(\.isNote)
        state.discardNote(tabID: today.id, spaceID: space.id)
        #expect(trashed.map(\.lastPathComponent) == [(NoteFiles.todayPath() as NSString).lastPathComponent])
        #expect(state.space(space.id)?.tab(today.id) == nil)

        // No agent tool sees a note, and `front` never names one.
        let noteTabs = state.selectedSpace?.tabs.filter(\.isNote) ?? []
        let note = try #require(noteTabs.first)
        state.selectTab(note.id)
        let front = PluginReach.front(pluginID: "x", space: state.selectedSpace, spaceIsOpen: true,
                                      welcomeCoversWindow: false, lastOtherPane: nil)
        #expect(front == .hidden(.nothing))
        state.notes.removeHosts(for: state.selectedSpace?.tabs.map(\.id) ?? [])
        state.notes.stopAll()
    }

    /// Not a check: with SG_NOTE_SNAPSHOT=<file.png> it writes a picture of the editor with a
    /// sample note (SG_NOTE_DARK=1 for dark mode), to look at it without a window on screen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_NOTE_SNAPSHOT"] != nil))
    func snapshot() async throws {
        let folder = try NoteFolder()
        defer { folder.remove() }
        try folder.write("assets/local.png", try #require(Self.onePixelPNG))
        let sample = ProcessInfo.processInfo.environment["SG_NOTE_SAMPLE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        try folder.write("Weekend in Tartu.md", Data((sample ?? Self.sampleNote).utf8))
        let (host, window) = try await open(folder, "Weekend in Tartu.md", size: NSSize(width: 900, height: 1100),
                                            dark: ProcessInfo.processInfo.environment["SG_NOTE_DARK"] != nil)
        defer { close(host, window) }
        if let script = ProcessInfo.processInfo.environment["SG_NOTE_SCRIPT"] { _ = try? await js(host, script) }
        try await Task.sleep(for: .milliseconds(600))
        let image = try await host.webView.takeSnapshot(configuration: nil)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SG_NOTE_SNAPSHOT"]!))
    }

    // MARK: Helpers

    /// A scratch box for the polling helpers below (a struct's `mutating` can't be used in them).
    private let cached = Box()
    @MainActor private final class Box {
        private var values: [String: Int] = [:]
        subscript(key: String) -> Int? {
            get { values[key] }
            set { values[key] = newValue }
        }
    }

    private func pollUntil(_ what: String, limit: Duration = .seconds(5), _ condition: () -> Bool, poll: () async -> Void) async throws {
        let deadline = ContinuousClock.now + limit
        while true {
            await poll()
            if condition() { return }
            guard ContinuousClock.now < deadline else { throw NoteTimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private struct NoteTimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { "waited for \(what)" }
    }

    private func open(_ folder: NoteFolder, _ path: String, size: NSSize = NSSize(width: 800, height: 600),
                      dark: Bool = false) async throws -> (NoteHost, NSWindow) {
        let host = NoteHost(tabID: UUID(), location: .init(root: folder.root, path: path), editorFolder: editorFolder)
        // Far off screen and never key: a key window of the test process could take the keyboard.
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.webView.frame = NSRect(origin: .zero, size: size)
        window.contentView!.addSubview(host.webView)
        window.orderFront(nil)
        try await pollUntil("the editor", limit: .seconds(15)) {
            self.cached["ready"] == 1
        } poll: {
            self.cached["ready"] = ((try? await self.js(host, "window.__noteTest && window.__noteTest.ready")) as? Bool) == true ? 1 : nil
        }
        cached["ready"] = nil
        return (host, window)
    }

    private func close(_ host: NoteHost, _ window: NSWindow) {
        host.tearDown()
        window.close()
    }

    /// Runs script in the page. A bare expression is returned; a body with `return` runs as is.
    @discardableResult
    private func js(_ host: NoteHost, _ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        let body = script.contains("return ") ? script : "return (\(script));"
        return try await host.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

    static let sampleNote = """
        A long weekend, mostly on foot. Notes to self for **next time**, and what still needs doing before we go.

        ## Before we leave

        - [x] Book the train (Friday 16:42)
        - [x] Ask Mari to water the plants
        - [ ] Pack
          - [ ] Rain jacket
          - [ ] Charger, *both* cables
        - [ ] Print the tickets

        ## Places

        1. Toy Museum, closes at 18
        2. The botanical garden
        3. Aparaaditehas, for dinner

        > "Tartu is the city of good thoughts." Worth checking whether that still holds after the third café.

        | Day | Plan | Booked |
        | --- | --- | --- |
        | Friday | Arrive, walk by the river | yes |
        | Saturday | Museums | no |

        ### Budget

        Roughly `180 €` for two, see [the spreadsheet](https://example.com/budget).

        ```
        train   2 × 14.50
        hotel   2 × 62.00
        ```

        ---

        Write the journal entry on Sunday evening.
        """
}
}

/// A temporary notes folder.
private struct NoteFolder {
    let root: URL

    init() throws {
        root = URL(filePath: "/private/tmp/sg-n-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ data: Data) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
