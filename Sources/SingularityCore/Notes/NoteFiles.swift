import Foundation

/// File rules for a Space's `notes/` folder.
///
/// A note is one Markdown file (`.md`) somewhere inside the folder; its title is its file name
/// without the extension. Pictures pasted into a note are saved in an `assets/` folder next to
/// it, so the Markdown refers to them with a relative path ("assets/2026-11-16-a1b2.png") that
/// any other Markdown program understands too.
///
/// Everything here is pure (text and paths in, text and paths out) except the few functions that
/// take a `root`, which only look at the disk.
public enum NoteFiles {
    /// The extension a new note gets.
    public static let fileExtension = "md"
    /// The extensions that are opened as notes.
    public static let fileExtensions: Set<String> = ["md", "markdown"]
    /// A note larger than this is not opened or saved (2 MB of text is a very long note).
    public static let maxNoteBytes = 2 * 1024 * 1024
    /// A pasted or dropped picture larger than this is refused.
    public static let maxImageBytes = 10 * 1024 * 1024
    /// The folder, next to a note, that holds its pictures.
    public static let assetsFolder = "assets"
    /// The folder "Today's Note" writes into.
    public static let journalFolder = "Journal"
    /// Picture types a note may show and the editor may save. No SVG: it is a document format
    /// that can carry scripts and links, and a note only ever needs photos and screenshots.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    // MARK: Titles and names

    /// A note's title: its file name without ".md".
    public static func title(ofPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return isNoteName(name) ? (name as NSString).deletingPathExtension : name
    }

    /// Whether a file name ends in one of the Markdown extensions.
    public static func isNoteName(_ name: String) -> Bool {
        fileExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The folder part of a note's path ("" at the top of the notes folder, else "Journal").
    public static func folder(ofPath path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }

    /// Turns what the owner typed as a title into a file name (without the extension), or nil when
    /// nothing usable is left. "/" and ":" can't be in a macOS file name, so they become "-";
    /// control characters go; a leading "." would hide the file, so it goes too.
    public static func fileName(forTitle title: String) -> String? {
        var name = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        // File names are limited to 255 bytes; 120 characters leaves room for ".md" and accents.
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? nil : name
    }

    /// A path for a new note called `title` in `folder` that no note in `taken` has: "Untitled",
    /// then "Untitled 2", "Untitled 3"… Names are compared without regard to case, because the
    /// usual macOS disk treats "Notes.md" and "notes.md" as the same file.
    public static func freePath(title: String = "Untitled", folder: String = "", taken: [String]) -> String {
        let base = fileName(forTitle: title) ?? "Untitled"
        let used = Set(taken.map { $0.lowercased() })
        func path(_ name: String) -> String {
            (folder.isEmpty ? "" : folder + "/") + name + "." + fileExtension
        }
        if !used.contains(path(base).lowercased()) { return path(base) }
        var number = 2
        while used.contains(path("\(base) \(number)").lowercased()) { number += 1 }
        return path("\(base) \(number)")
    }

    /// Where a note lands when its title changes: same folder, new name, same extension. Nil
    /// when the title leaves no usable name.
    public static func renamedPath(_ path: String, title: String) -> String? {
        guard let name = fileName(forTitle: title) else { return nil }
        let folder = folder(ofPath: path)
        let ext = (path as NSString).pathExtension
        return (folder.isEmpty ? "" : folder + "/") + name + "." + (ext.isEmpty ? fileExtension : ext)
    }

    /// The day's journal note: "Journal/2026-11-16.md". Dates sort by name this way.
    public static func todayPath(date: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return journalFolder + "/" + name + "." + fileExtension
    }

    /// The name for a pasted picture, inside `assets/`: the day, then a few random characters so
    /// two pictures pasted in the same second don't collide. `suffix` is passed in by tests.
    public static func imageName(extension ext: String, date: Date = Date(), calendar: Calendar = .current,
                                 suffix: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String? {
        let ext = ext.lowercased()
        guard imageExtensions.contains(ext) else { return nil }
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d-%@.%@", day.year ?? 0, day.month ?? 0, day.day ?? 0, suffix, ext)
    }

    // MARK: Paths on disk

    /// Whether `path` could be a note's path at all: only plain components, no "..", nothing
    /// hidden, ends in ".md" (or ".markdown").
    public static func isValidPath(_ path: String) -> Bool {
        guard !path.contains("\0"), !path.hasPrefix("/"), isNoteName(path) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    /// The file for a note's path, whether or not it exists yet. Nil when the path is not valid,
    /// or when the file (or, for a new note, its folder) is not really inside `root` once
    /// symlinks are followed: a link in the notes folder must never make the editor read or
    /// write somewhere else. An existing folder at that path is refused too.
    public static func file(forPath path: String, root: URL) -> URL? {
        guard isValidPath(path) else { return nil }
        return contained(path, root: root)
    }

    /// The file of a picture a note refers to: `source` as written in the Markdown, relative to
    /// the note's own folder. Only the picture types above, only existing regular files inside
    /// `root`. Nil for anything else (an address on the web, an absolute path, "..").
    public static func imageFile(source: String, notePath: String, root: URL) -> URL? {
        guard !source.contains("\0"), !source.hasPrefix("/"), !source.contains("://"), !source.contains("\\") else { return nil }
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return nil }
        guard imageExtensions.contains((source as NSString).pathExtension.lowercased()) else { return nil }
        let folder = folder(ofPath: notePath)
        let relative = (folder.isEmpty ? "" : folder + "/") + source
        guard let file = contained(relative, root: root) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return file
    }

    /// Where a new picture called `name` (from `imageName`) goes: the `assets/` folder next to
    /// the note. Nil when that would not be inside `root`.
    public static func newImageFile(name: String, notePath: String, root: URL) -> URL? {
        guard !name.contains("/"), !name.hasPrefix("."), imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        let folder = folder(ofPath: notePath)
        return contained((folder.isEmpty ? "" : folder + "/") + assetsFolder + "/" + name, root: root)
    }

    // MARK: Notes in the Space's folder, and Markdown files anywhere

    /// Where a note tab's file is. A tab's stored path is either relative (a note in the Space's
    /// `notes/` folder) or absolute (a Markdown file the owner opened from somewhere else on the
    /// disk). Either way the editor works inside one folder, `root`, with a path relative to it:
    /// for a file from elsewhere that folder is the file's own, so its pictures (`assets/…`) and
    /// a rename stay next to it and nothing above that folder can be reached.
    public struct Location: Equatable, Sendable {
        public var root: URL
        public var path: String

        public init(root: URL, path: String) {
            self.root = root
            self.path = path
        }
    }

    public static func isOutside(_ tabPath: String) -> Bool {
        tabPath.hasPrefix("/")
    }

    public static func location(tabPath: String, notesRoot: URL) -> Location {
        guard isOutside(tabPath) else { return Location(root: notesRoot, path: tabPath) }
        let file = URL(fileURLWithPath: tabPath)
        return Location(root: file.deletingLastPathComponent(), path: file.lastPathComponent)
    }

    /// The tab path for `path` inside the note's folder, in the same form as `tabPath` was
    /// (after a rename).
    public static func tabPath(renamed path: String, from tabPath: String) -> String {
        guard isOutside(tabPath) else { return path }
        return URL(fileURLWithPath: tabPath).deletingLastPathComponent().appending(path: path).path
    }

    /// The tab path for a file the owner picked: relative when it is inside the Space's notes
    /// folder (so it is the same note as the one the palette lists), absolute otherwise. Nil for
    /// a file that isn't Markdown, or is hidden.
    public static func tabPath(forFile file: URL, notesRoot: URL) -> String? {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard isNoteName(resolved.lastPathComponent), !resolved.lastPathComponent.hasPrefix(".") else { return nil }
        let rootPath = notesRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.path.hasPrefix(rootPath + "/") {
            let relative = String(resolved.path.dropFirst(rootPath.count + 1))
            if isValidPath(relative) { return relative }
        }
        return resolved.path
    }

    /// What the palette says under a note's title: where it is inside `notes/`, or its place on
    /// disk with the home folder shortened to "~".
    public static func subtitle(tabPath: String, home: String = NSHomeDirectory()) -> String {
        guard isOutside(tabPath) else { return "notes/" + tabPath }
        return tabPath.hasPrefix(home + "/") ? "~" + tabPath.dropFirst(home.count) : tabPath
    }

    /// `relative` inside `root`, checked after symlinks are followed. For a file that doesn't
    /// exist yet, the nearest existing folder above it is what gets checked.
    private static func contained(_ relative: String, root: URL) -> URL? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var candidate = URL(fileURLWithPath: rootPath, isDirectory: true)
        for part in relative.split(separator: "/") { candidate.append(path: String(part)) }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        // `attributesOfItem` doesn't follow a link at the last component, so a dangling link is
        // still seen as "something is here".
        if (try? manager.attributesOfItem(atPath: candidate.path)) != nil {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPath + "/") else { return nil }
            // Still a link after resolving: it points at nothing (Foundation leaves such a link
            // as it is). Writing "through" it would create a file wherever it points.
            if (try? manager.attributesOfItem(atPath: resolved.path))?[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
            if manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue { return nil }
            return resolved
        }
        // Not there yet: walk up to the first folder that exists and check that one.
        var parent = candidate.deletingLastPathComponent()
        while (try? manager.attributesOfItem(atPath: parent.path)) == nil, parent.path.count > rootPath.count {
            parent = parent.deletingLastPathComponent()
        }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == rootPath || resolvedParent.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    /// One note found in the folder.
    public struct Listed: Equatable, Sendable {
        public var path: String
        public var modified: Date
    }

    /// The notes in `root`, newest first: every visible `.md` file in visible folders, except the
    /// pictures' `assets/` folders. Stops at `limit` files looked at, so a huge folder dropped
    /// into `notes/` can't stall the palette.
    public static func list(in root: URL, limit: Int = 2000) -> [Listed] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [Listed] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            if url.lastPathComponent == assetsFolder { walker.skipDescendants(); continue }
            guard isNoteName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard isValidPath(relative) else { continue }
            found.append(Listed(path: relative, modified: values.contentModificationDate ?? .distantPast))
        }
        return found.sorted { ($0.modified, $1.path) > ($1.modified, $0.path) }
    }

    // MARK: Saving

    /// What a save from the editor should do, given the text the editor last got from the disk
    /// (or last wrote) and what is on the disk now.
    public enum SaveDecision: Equatable, Sendable {
        /// Write the editor's text.
        case write
        /// The file changed underneath the editor (another program, an agent, a sync tool): don't
        /// overwrite it; the editor asks the owner which version to keep.
        case conflict
    }

    /// - Parameters:
    ///   - known: the text the editor last loaded or saved; nil when it has loaded no file.
    ///   - onDisk: the file's text right now; nil when there is no file.
    ///   - force: the owner chose "Keep mine".
    public static func saveDecision(known: String?, onDisk: String?, force: Bool) -> SaveDecision {
        if force { return .write }
        // No file: writing loses nothing (a new note, or one whose file was deleted while open).
        guard let onDisk else { return .write }
        return onDisk == known ? .write : .conflict
    }
}
