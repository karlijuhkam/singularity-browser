import Foundation

/// What a tab drag carries on the pasteboard (as text, under Singularity's private tab type).
/// A tab row or pane header carries the tab's bare id; a split's row in the sidebar carries
/// `split:<group id>`. The panes read only a bare id, so a split's row dropped on the page does
/// nothing (it must not pull one tab out of its split or nest the split in another).
public enum TabDragPayload: Equatable, Sendable {
    case tab(UUID)
    case split(groupID: UUID)

    private static let splitPrefix = "split:"

    /// Reads a payload back; anything else is nil.
    public init?(string: String) {
        if string.hasPrefix(Self.splitPrefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(Self.splitPrefix.count))) else { return nil }
            self = .split(groupID: id)
        } else if let id = UUID(uuidString: string) {
            self = .tab(id)
        } else {
            return nil
        }
    }

    /// The text written to the pasteboard.
    public var string: String {
        switch self {
        case .tab(let id): return id.uuidString
        case .split(let groupID): return Self.splitPrefix + groupID.uuidString
        }
    }
}
