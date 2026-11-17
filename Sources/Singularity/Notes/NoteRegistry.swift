import Foundation
import Observation
import SingularityCore

/// Owns one `NoteHost` per open note tab. Like web views and terminals, a note's editor is made
/// lazily (the first time the tab is shown) and kept while the tab exists.
///
/// It also watches the folders the open notes are in, so a note that another program rewrites
/// (an agent, a sync tool, a text editor) shows the new text, or asks which version to keep when
/// the owner was typing at that moment (`NoteHost.fileChangedOnDisk`).
@MainActor
@Observable
final class NoteRegistry {
    @ObservationIgnored weak var state: AppState?
    private var hosts: [UUID: NoteHost] = [:]
    /// One watcher per folder that has an open note, by the folder's path.
    @ObservationIgnored private var watchers: [String: ArtifactWatcher] = [:]
    /// Where the editor's files are. Tests point this at the repository's `Resources/note-editor`.
    @ObservationIgnored var editorFolder = NotePageServer.bundledEditorFolder

    /// Whether notes can be shown at all (a bare debug binary has no editor beside it).
    var editorIsAvailable: Bool { NoteHost.editorIsBundled(editorFolder) }

    var isEmpty: Bool { hosts.isEmpty }

    func existingHost(_ tabID: UUID) -> NoteHost? {
        hosts[tabID]
    }

    /// The tab's editor, made now if this is the first time the tab is shown. Nil when the tab is
    /// not a note or the editor's files are missing.
    func host(for tab: BrowserTab, in space: Space) -> NoteHost? {
        if let existing = hosts[tab.id] { return existing }
        guard let tabPath = tab.notePath, let state, editorIsAvailable else { return nil }
        let location = NoteFiles.location(tabPath: tabPath, notesRoot: state.paths.notesDirectory(space.slug))
        let host = NoteHost(tabID: tab.id, location: location, editorFolder: editorFolder)
        let tabID = tab.id, spaceID = space.id
        host.onRename = { [weak state] newPath in state?.noteWasRenamed(tabID: tabID, spaceID: spaceID, to: newPath) }
        host.onOpenLink = { [weak state] url in state?.openLinkFromNote(url, tabID: tabID, spaceID: spaceID) }
        host.onFileChange = { [weak state] in state?.homeFilesDidChange() }
        host.isOpenElsewhere = { [weak self] path in
            self?.hosts.values.contains { $0.tabID != tabID && $0.location.root == location.root && $0.location.path.lowercased() == path.lowercased() } ?? false
        }
        hosts[tab.id] = host
        watch(location.root)
        return host
    }

    /// The tabs are being closed. Each editor first writes what it hasn't saved yet (the page
    /// saves 0.4 s after the last keystroke, so there may be a moment's typing left).
    func removeHosts(for tabIDs: [UUID]) {
        for id in tabIDs {
            guard let host = hosts.removeValue(forKey: id) else { continue }
            Task {
                await host.flush()
                host.tearDown()
            }
        }
        dropUnusedWatchers()
    }

    /// Every open editor writes what it hasn't saved yet (before the app quits).
    func flushAll() async {
        // All at once, then wait for each (an editor gives up after 2 s).
        let writes = hosts.values.map { host in Task { @MainActor in await host.flush() } }
        for write in writes { await write.value }
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    // MARK: Watching

    private func watch(_ root: URL) {
        let key = root.standardizedFileURL.path
        guard watchers[key] == nil else { return }
        // FSEvents needs the folder to be there.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watcher = ArtifactWatcher(root: root) { [weak self] changes in
            self?.filesChanged(inRoot: key, changes: changes)
        }
        watcher.start()
        watchers[key] = watcher
    }

    private func dropUnusedWatchers() {
        let used = Set(hosts.values.map { $0.location.root.standardizedFileURL.path })
        for (key, watcher) in watchers where !used.contains(key) {
            watcher.stop()
            watchers.removeValue(forKey: key)
        }
    }

    /// Matched by file name only (a busy folder, say a repository with an open README, reports
    /// many files); the host then compares the file's text with what its editor has.
    private func filesChanged(inRoot key: String, changes: [ArtifactWatcher.Change]) {
        let names = Set(changes.map { ($0.relativePath as NSString).lastPathComponent.lowercased() })
        for host in hosts.values where host.location.root.standardizedFileURL.path == key {
            if names.contains((host.location.path as NSString).lastPathComponent.lowercased()) {
                host.fileChangedOnDisk()
            }
        }
    }
}
