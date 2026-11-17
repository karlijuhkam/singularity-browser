import Foundation
import SingularityCore

/// Reads the files the home's Recent section lists: the Space's notes and its artifact pages, an
/// app's pages counted as one row for the app. Runs off the main actor (it walks folders and reads
/// file dates); the order and the cut are Core's (`HomeRules.recent`). Only reads: a folder that
/// isn't there is an empty list, and nothing is made.
enum HomeRecentLoader {
    static func load(notesRoot: URL, artifactsRoot: URL, limit: Int = 8) -> [HomeRecentFile] {
        var files = NoteFiles.list(in: notesRoot, limit: 2000).map {
            HomeRecentFile(kind: .note, path: $0.path, modified: $0.modified)
        }
        var apps: [String: Date] = [:]
        for page in ArtifactFiles.listPages(in: artifactsRoot) {
            let file = artifactsRoot.appending(path: page)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let app = ArtifactApps.app(forArtifactPath: page, root: artifactsRoot) {
                apps[app] = max(apps[app] ?? .distantPast, modified)
            } else {
                files.append(HomeRecentFile(kind: .artifact, path: page, modified: modified))
            }
        }
        files += apps.map { HomeRecentFile(kind: .app, path: $0.key, modified: $0.value) }
        return HomeRules.recent(files, limit: limit)
    }

    /// The page that opens an app from the Recent list: its `index.html`, else its first page.
    static func entryPage(ofApp app: String, pages: [String]) -> String? {
        let inside = pages.filter { $0.hasPrefix(app + "/") }
        return inside.first { $0 == app + "/index.html" } ?? inside.first
    }
}
