import Foundation

/// A folder in the sidebar. Folders hold no tabs themselves: a tab points at its folder through
/// `BrowserTab.folderID`, and a folder inside another folder points at it through `parentID`.
/// `Space.folders` is one flat list; folders with the same parent appear in that list's order.
public struct Folder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isExpanded: Bool
    /// The folder this one is inside; nil at the top level. (Missing in space.json files written
    /// before folders could be nested, which decodes as nil.)
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, isExpanded: Bool = true, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.parentID = parentID
    }
}
