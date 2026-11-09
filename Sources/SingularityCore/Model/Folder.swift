import Foundation

/// A one-level folder in the sidebar. Folders only group tabs; they hold no tabs themselves
/// (a tab points at its folder through `Tab.folderID`).
public struct Folder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
    }
}
