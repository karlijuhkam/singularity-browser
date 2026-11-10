import Foundation

/// Reads the sidebar of the Arc browser and turns its Spaces into Singularity Spaces.
///
/// Arc keeps its sidebar in `~/Library/Application Support/Arc/StorableSidebar.json`. The parts
/// used here (the format isn't documented; this is what the file looks like in 2026):
///
/// ```
/// sidebar.containers[]            one of them has "spaces" and "items"
///   spaces: [id, {…}, id, {…}]    alternating id and object
///     title, containerIDs: ["unpinned", <item id>, "pinned", <item id>]
///     customInfo.windowTheme.primaryColorPalette.midTone: {red, green, blue}   (0…1)
///     profile: {default: true} or {custom: {_0: {directoryBasename}}}
///   items: [id, {…}, id, {…}]
///     id, parentID, childrenIds, title (a custom name, or null)
///     data: {tab: {savedURL, savedTitle}} | {list: {}} (a folder) | {tabGroup} | {splitView}
///           | {itemContainer} | {arcDocument} (a note or easel: not a web page)
/// ```
///
/// What maps onto what:
/// - an Arc Space → a new Singularity Space (same name and colour);
/// - tabs directly under "pinned" → pinned tabs; under "unpinned" → open tabs;
/// - an Arc folder → a folder, and a folder inside it → a folder inside that one. Within a
///   folder Singularity lists the folders first and the tabs after them, so where Arc mixes the
///   two the order differs; empty folders are kept;
/// - tab groups and split views → their tabs, in place;
/// - notes, easels and anything that isn't an http(s) address are left out (and counted).
///
/// Logins and cookies are not imported: Arc is Chromium and keeps them encrypted in its own
/// profile; Singularity's Spaces use WebKit's store.
public enum ArcImport {
    /// Where Arc keeps the file.
    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Arc/StorableSidebar.json")
    }

    public enum Failure: Error, Equatable {
        case unreadable
        /// The file is JSON but not shaped like Arc's sidebar (a newer Arc may have changed it).
        case unrecognised

        public var message: String {
            switch self {
            case .unreadable: return "The file couldn't be read."
            case .unrecognised: return "This doesn't look like Arc's sidebar file. Arc may have changed its format."
            }
        }
    }

    public indirect enum Node: Equatable, Sendable {
        case tab(title: String, url: URL)
        case folder(name: String, children: [Node])
    }

    public struct ArcSpace: Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// "#RRGGBB" from Arc's theme, when it has one.
        public var colorHex: String?
        /// Arc profiles keep separate logins; shown so the owner can tell Spaces apart.
        public var profile: String
        public var pinned: [Node]
        public var unpinned: [Node]
        /// Notes, easels and non-web addresses that can't be imported.
        public var skipped: Int

        public var pinnedTabCount: Int { ArcImport.countTabs(pinned) }
        public var unpinnedTabCount: Int { ArcImport.countTabs(unpinned) }
    }

    static func countTabs(_ nodes: [Node]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .tab: return total + 1
            case .folder(_, let children): return total + countTabs(children)
            }
        }
    }

    // MARK: - Reading Arc's file

    public static func read(_ file: URL) -> Result<[ArcSpace], Failure> {
        guard let data = try? Data(contentsOf: file) else { return .failure(.unreadable) }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Result<[ArcSpace], Failure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.unreadable) }
        guard let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["spaces"] != nil && $0["items"] != nil }),
              let rawSpaces = container["spaces"] as? [Any], let rawItems = container["items"] as? [Any]
        else { return .failure(.unrecognised) }

        // Both lists alternate id strings and objects; the objects carry their id too.
        var items: [String: [String: Any]] = [:]
        for case let item as [String: Any] in rawItems {
            if let id = item["id"] as? String { items[id] = item }
        }

        var spaces: [ArcSpace] = []
        for case let space as [String: Any] in rawSpaces {
            guard let id = space["id"] as? String else { continue }
            // containerIDs: ["unpinned", id, "pinned", id] (the order varies).
            var roots: [String: String] = [:]
            let ids = space["containerIDs"] as? [Any] ?? []
            var index = 0
            while index + 1 < ids.count {
                if let kind = ids[index] as? String, let itemID = ids[index + 1] as? String { roots[kind] = itemID }
                index += 2
            }
            var skipped = 0
            var seen = Set<String>()
            let pinned = roots["pinned"].map { children(of: $0, items: items, skipped: &skipped, seen: &seen) } ?? []
            let unpinned = roots["unpinned"].map { children(of: $0, items: items, skipped: &skipped, seen: &seen) } ?? []
            let title = (space["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            spaces.append(ArcSpace(id: id, name: title.isEmpty ? "Arc" : title, colorHex: color(of: space),
                                   profile: profile(of: space), pinned: pinned, unpinned: unpinned, skipped: skipped))
        }
        return .success(spaces)
    }

    /// The importable nodes under an item, in Arc's order. `seen` guards against a file whose
    /// items point at each other in a circle.
    private static func children(of id: String, items: [String: [String: Any]], skipped: inout Int, seen: inout Set<String>) -> [Node] {
        guard seen.insert(id).inserted, let item = items[id] else { return [] }
        var nodes: [Node] = []
        for case let childID as String in item["childrenIds"] as? [Any] ?? [] {
            guard let child = items[childID], let data = child["data"] as? [String: Any] else { continue }
            let customTitle = (child["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let tab = data["tab"] as? [String: Any] {
                guard let text = tab["savedURL"] as? String, let url = URL(string: text),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else {
                    skipped += 1
                    continue
                }
                let title = customTitle.isEmpty ? (tab["savedTitle"] as? String ?? "") : customTitle
                nodes.append(.tab(title: title, url: url))
            } else if data["list"] != nil {
                let inner = children(of: childID, items: items, skipped: &skipped, seen: &seen)
                nodes.append(.folder(name: customTitle.isEmpty ? "Folder" : customTitle, children: inner))
            } else if data["tabGroup"] != nil || data["splitView"] != nil || data["itemContainer"] != nil {
                // Only their tabs matter here.
                nodes += children(of: childID, items: items, skipped: &skipped, seen: &seen)
            } else {
                skipped += 1 // arcDocument (a note or easel) and anything newer
            }
        }
        return nodes
    }

    private static func color(of space: [String: Any]) -> String? {
        guard let info = space["customInfo"] as? [String: Any], let theme = info["windowTheme"] as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any], let tone = palette["midTone"] as? [String: Any],
              let red = tone["red"] as? Double, let green = tone["green"] as? Double, let blue = tone["blue"] as? Double
        else { return nil }
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    private static func profile(of space: [String: Any]) -> String {
        guard let profile = space["profile"] as? [String: Any] else { return "Default" }
        if let custom = profile["custom"] as? [String: Any], let value = custom["_0"] as? [String: Any],
           let name = value["directoryBasename"] as? String { return name }
        return "Default"
    }

    // MARK: - Making Singularity Spaces

    public struct Options: Equatable, Sendable {
        /// Also bring Arc's unpinned tabs ("Today") as open tabs.
        public var includeUnpinned: Bool

        public init(includeUnpinned: Bool = true) {
            self.includeUnpinned = includeUnpinned
        }
    }

    /// A new Singularity Space with the Arc Space's tabs and folders. Nothing is loaded: tabs
    /// only open their page when first shown. `slug` must be free (see `Slug.unique`).
    public static func makeSpace(from arc: ArcSpace, slug: String, fallbackColorHex: String, options: Options = Options()) -> Space {
        var space = Space(name: arc.name, slug: slug, colorHex: arc.colorHex ?? fallbackColorHex)
        var folders: [Folder] = []
        var tabs: [BrowserTab] = []

        // Folders keep their nesting (`Folder.parentID`). They start collapsed: an Arc sidebar
        // easily holds hundreds of tabs.
        func addFolder(_ name: String, _ children: [Node], parentID: UUID?) {
            let folder = Folder(name: name, isExpanded: false, parentID: parentID)
            folders.append(folder)
            for child in children {
                switch child {
                case .tab(let title, let url):
                    var tab = BrowserTab.web(url, title: title)
                    tab.folderID = folder.id
                    tabs.append(tab)
                case .folder(let childName, let grandchildren):
                    addFolder(childName, grandchildren, parentID: folder.id)
                }
            }
        }

        for node in arc.pinned {
            switch node {
            case .tab(let title, let url):
                var tab = BrowserTab.web(url, title: title)
                tab.isPinned = true
                tabs.append(tab)
            case .folder(let name, let children):
                addFolder(name, children, parentID: nil)
            }
        }
        if options.includeUnpinned {
            for node in arc.unpinned {
                switch node {
                case .tab(let title, let url): tabs.append(BrowserTab.web(url, title: title))
                case .folder(let name, let children): addFolder(name, children, parentID: nil) // not seen in practice
                }
            }
        }
        space.folders = folders
        space.tabs = tabs
        return space
    }
}
