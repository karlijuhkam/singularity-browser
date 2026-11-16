import AppKit
import SingularityCore
import UniformTypeIdentifiers

/// Notes: Markdown files shown in Singularity's own editor, as tabs.
///
/// A Space's notes live in `spaces/<slug>/notes/`; a Markdown file from anywhere else on the disk
/// can be opened the same way (its tab stores the absolute path). The rules about names and
/// places are in Core (`NoteFiles`); the editor and the file access are in `NoteHost`.
extension AppState {
    // MARK: Opening

    /// New Note (⌘N, the palette): an empty note called "Untitled" (then "Untitled 2", …) in the
    /// selected Space. The file is made right away, so the name is taken and the note is listed.
    func newNote() {
        guard let space = selectedSpace else { return }
        let root = paths.notesDirectory(space.slug)
        let taken = NoteFiles.list(in: root).map(\.path) + space.tabs.compactMap(\.notePath)
        let path = NoteFiles.freePath(taken: taken)
        createEmptyNote(path, root: root)
        openNote(path)
    }

    /// Today's Note (⌥⌘N, the palette): the day's journal note, `Journal/2026-11-16.md`, made
    /// when it isn't there yet.
    func openTodayNote() {
        guard let space = selectedSpace else { return }
        let path = NoteFiles.todayPath()
        createEmptyNote(path, root: paths.notesDirectory(space.slug))
        openNote(path)
    }

    private func createEmptyNote(_ path: String, root: URL) {
        guard let file = NoteFiles.file(forPath: path, root: root), !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file, options: .withoutOverwriting)
        } catch {
            // The editor still opens; its first save makes the file or says why it can't.
            notesLog.error("could not create a note's file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the note at `tabPath` (relative: in the Space's notes folder; absolute: a file from
    /// elsewhere) in the selected Space, or selects its tab when it is already open there.
    func openNote(_ tabPath: String) {
        guard let space = selectedSpace else { return }
        closeWelcome()
        if let existing = space.tabs.first(where: { $0.notePath?.lowercased() == tabPath.lowercased() }) {
            selectTab(existing.id)
            return
        }
        let tab = BrowserTab.note(path: tabPath)
        mutateSpace(space.id) {
            $0.append(tab)
            $0.selectedTabID = tab.id
        }
        loadSelectedTab()
    }

    /// File → Open File… (⌘O): pick Markdown files anywhere on the disk.
    func openMarkdownFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = NoteFiles.fileExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Open"
        panel.message = "Choose Markdown files to open in \(selectedSpace?.name ?? "this Space")."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openMarkdownFile)
    }

    /// A Markdown file the owner chose: the Open panel, or a file handed to the app from Finder
    /// ("Open With", a drop on the Dock icon). Anything that isn't Markdown is ignored.
    func openMarkdownFile(_ file: URL) {
        guard file.isFileURL, let space = selectedSpace,
              let tabPath = NoteFiles.tabPath(forFile: file, notesRoot: paths.notesDirectory(space.slug)) else { return }
        showMainWindow()
        openNote(tabPath)
    }

    // MARK: From the editor

    /// The editor renamed its note's file: the tab follows.
    func noteWasRenamed(tabID: UUID, spaceID: UUID, to newPath: String) {
        guard let old = space(spaceID)?.tab(tabID)?.notePath else { return }
        let tabPath = NoteFiles.tabPath(renamed: newPath, from: old)
        mutateSpace(spaceID) {
            $0.updateTab(tabID) {
                $0.kind = .note(path: tabPath)
                $0.title = NoteFiles.title(ofPath: tabPath)
            }
        }
    }

    /// A link in a note was ⌘-clicked: a new tab right after the note, in the note's Space.
    func openLinkFromNote(_ url: URL, tabID: UUID, spaceID: UUID) {
        let tab = BrowserTab.web(url)
        mutateSpace(spaceID) {
            $0.insert(tab, after: tabID)
            $0.selectedTabID = tab.id
        }
        if spaceID == selectedSpaceID { loadSelectedTab() }
    }

    // MARK: The file of a note tab

    func noteFile(tabID: UUID, spaceID: UUID) -> URL? {
        guard let space = space(spaceID), let tabPath = space.tab(tabID)?.notePath else { return nil }
        let location = NoteFiles.location(tabPath: tabPath, notesRoot: paths.notesDirectory(space.slug))
        return NoteFiles.file(forPath: location.path, root: location.root)
    }

    func revealNote(tabID: UUID, spaceID: UUID) {
        guard let file = noteFile(tabID: tabID, spaceID: spaceID) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }

    func revealNotesFolder() {
        guard let space = selectedSpace else { return }
        let folder = paths.notesDirectory(space.slug)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// "Delete Note…" on a note's row: asks, then closes the tab and moves the file to the Trash
    /// (so it can be put back). Its pictures in `assets/` stay: other notes may use them.
    func deleteNote(tabID: UUID, spaceID: UUID) {
        guard let tab = space(spaceID)?.tab(tabID), tab.isNote else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(tab.displayTitle)”?"
        alert.informativeText = "The note's file moves to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        discardNote(tabID: tabID, spaceID: spaceID)
    }

    /// The deleting itself (no question asked; tests call this with `trashFile` replaced).
    func discardNote(tabID: UUID, spaceID: UUID) {
        let file = noteFile(tabID: tabID, spaceID: spaceID)
        // Closed first, without its last save: a save after the move would make the file again.
        notes.existingHost(tabID)?.tearDown()
        closeTab(tabID, in: spaceID, confirmIfBusy: false)
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try trashFile(file)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The Space's notes that have no tab, newest first, for the palette. Read from disk when the
    /// palette opens (`showPalette`), not at every keystroke.
    func refreshPaletteNotes() {
        guard let space = selectedSpace else { paletteNotes = []; return }
        let open = Set(space.tabs.compactMap { $0.notePath?.lowercased() })
        paletteNotes = NoteFiles.list(in: paths.notesDirectory(space.slug), limit: 2000)
            .map(\.path).filter { !open.contains($0.lowercased()) }
    }
}
