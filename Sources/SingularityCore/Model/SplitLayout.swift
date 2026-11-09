import Foundation

/// Split view ("tiling"): several tabs of a Space shown side by side and/or stacked.
///
/// A split is a tree. Leaves are panes (one tab each); inner nodes lay their children out
/// horizontally (side by side) or vertically (stacked), each child getting a fraction of the space.
/// Splits behave like Arc's: a `SplitGroup` remembers its tabs, selecting any of them shows the
/// whole group, and selecting a tab outside it shows that tab alone.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Children side by side, left to right.
    case horizontal
    /// Children stacked, top to bottom.
    case vertical
}

/// Where a new pane goes, relative to an existing one.
public enum SplitEdge: Hashable, Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// Whether the new pane goes before (left/above) the existing one.
    var isBefore: Bool { self == .left || self == .top }
}

/// Direction for moving keyboard focus between panes.
public enum PaneDirection: Sendable {
    case left, right, up, down
}

/// A rectangle in a 0…1 coordinate space (the whole split is 0,0 to 1,1; y grows downwards).
public struct UnitRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public indirect enum SplitNode: Codable, Hashable, Sendable {
    case pane(tabID: UUID)
    /// `fractions` has one entry per child and sums to 1.
    case split(axis: SplitAxis, children: [SplitNode], fractions: [Double])

    /// All tabs in this subtree, in reading order (left to right, top to bottom).
    public var tabIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, let children, _): return children.flatMap(\.tabIDs)
        }
    }

    public func contains(_ tabID: UUID) -> Bool {
        tabIDs.contains(tabID)
    }

    /// Puts `newTab` next to `target` on the given edge.
    /// If the target already sits in a container with the same axis, the new pane becomes its
    /// sibling (sharing the target's space) instead of nesting another container.
    func inserting(_ newTab: UUID, beside target: UUID, edge: SplitEdge) -> SplitNode {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            let children: [SplitNode] = edge.isBefore ? [.pane(tabID: newTab), self] : [self, .pane(tabID: newTab)]
            return .split(axis: edge.axis, children: children, fractions: [0.5, 0.5])

        case .split(let axis, var children, var fractions):
            if axis == edge.axis, let index = children.firstIndex(of: .pane(tabID: target)) {
                let half = fractions[index] / 2
                fractions[index] = half
                let insertAt = edge.isBefore ? index : index + 1
                children.insert(.pane(tabID: newTab), at: insertAt)
                fractions.insert(half, at: insertAt)
                return .split(axis: axis, children: children, fractions: fractions)
            }
            return .split(axis: axis, children: children.map { $0.inserting(newTab, beside: target, edge: edge) }, fractions: fractions)
        }
    }

    /// The tree without `tabID`; nil if nothing is left. The remaining siblings share the space.
    func removing(_ tabID: UUID) -> SplitNode? {
        switch self {
        case .pane(let id):
            return id == tabID ? nil : self
        case .split(let axis, let children, let fractions):
            var keptChildren: [SplitNode] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removing(tabID) {
                    keptChildren.append(kept)
                    keptFractions.append(fraction)
                }
            }
            if keptChildren.isEmpty { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            return .split(axis: axis, children: keptChildren, fractions: Self.normalised(keptFractions))
        }
    }

    /// Replaces the pane showing `old` with one showing `new`.
    func replacing(_ old: UUID, with new: UUID) -> SplitNode {
        switch self {
        case .pane(let id):
            return id == old ? .pane(tabID: new) : self
        case .split(let axis, let children, let fractions):
            return .split(axis: axis, children: children.map { $0.replacing(old, with: new) }, fractions: fractions)
        }
    }

    /// Simplifies the tree: a container with one child becomes that child, and a container
    /// inside a container of the same axis is merged into its parent.
    func simplified() -> SplitNode {
        guard case .split(let axis, let children, let fractions) = self else { return self }
        var flatChildren: [SplitNode] = []
        var flatFractions: [Double] = []
        for (child, fraction) in zip(children, fractions) {
            let child = child.simplified()
            if case .split(let childAxis, let grandchildren, let childFractions) = child, childAxis == axis {
                flatChildren += grandchildren
                flatFractions += childFractions.map { $0 * fraction }
            } else {
                flatChildren.append(child)
                flatFractions.append(fraction)
            }
        }
        if flatChildren.count == 1 { return flatChildren[0] }
        return .split(axis: axis, children: flatChildren, fractions: Self.normalised(flatFractions))
    }

    /// New fractions for the container at `path` (child indices from this node down).
    func settingFractions(_ newFractions: [Double], at path: [Int]) -> SplitNode {
        guard case .split(let axis, var children, let fractions) = self else { return self }
        guard let first = path.first else {
            guard newFractions.count == children.count else { return self }
            return .split(axis: axis, children: children, fractions: Self.normalised(newFractions))
        }
        guard children.indices.contains(first) else { return self }
        children[first] = children[first].settingFractions(newFractions, at: Array(path.dropFirst()))
        return .split(axis: axis, children: children, fractions: fractions)
    }

    /// Where each pane sits, in 0…1 coordinates.
    public func layoutRects(in rect: UnitRect = UnitRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: UnitRect] {
        switch self {
        case .pane(let id):
            return [id: rect]
        case .split(let axis, let children, let fractions):
            var result: [UUID: UnitRect] = [:]
            var offset = 0.0
            for (child, fraction) in zip(children, fractions) {
                let childRect = axis == .horizontal
                    ? UnitRect(x: rect.x + offset * rect.width, y: rect.y, width: fraction * rect.width, height: rect.height)
                    : UnitRect(x: rect.x, y: rect.y + offset * rect.height, width: rect.width, height: fraction * rect.height)
                result.merge(child.layoutRects(in: childRect)) { first, _ in first }
                offset += fraction
            }
            return result
        }
    }

    /// The pane next to `tabID` in a direction: the closest pane on that side that overlaps it
    /// along the other axis. Ties go to the one overlapping most, then the topmost/leftmost.
    public func neighbour(of tabID: UUID, _ direction: PaneDirection) -> UUID? {
        let rects = layoutRects()
        guard let current = rects[tabID] else { return nil }
        let epsilon = 1e-9

        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
            max(0, min(a1, b1) - max(a0, b0))
        }

        var best: (id: UUID, distance: Double, overlap: Double, position: Double)?
        for (id, rect) in rects where id != tabID {
            let distance: Double
            let shared: Double
            switch direction {
            case .right:
                guard rect.x >= current.maxX - epsilon else { continue }
                distance = rect.x - current.maxX
                shared = overlap(rect.y, rect.maxY, current.y, current.maxY)
            case .left:
                guard rect.maxX <= current.x + epsilon else { continue }
                distance = current.x - rect.maxX
                shared = overlap(rect.y, rect.maxY, current.y, current.maxY)
            case .down:
                guard rect.y >= current.maxY - epsilon else { continue }
                distance = rect.y - current.maxY
                shared = overlap(rect.x, rect.maxX, current.x, current.maxX)
            case .up:
                guard rect.maxY <= current.y + epsilon else { continue }
                distance = current.y - rect.maxY
                shared = overlap(rect.x, rect.maxX, current.x, current.maxX)
            }
            guard shared > epsilon else { continue }
            // Final tie-breaker: the topmost (moving sideways) or leftmost (moving up/down) pane.
            let position = (direction == .left || direction == .right) ? rect.y : rect.x
            let candidate = (id: id, distance: distance, overlap: shared, position: position)
            guard let current = best else {
                best = candidate
                continue
            }
            if distance < current.distance - epsilon {
                best = candidate
            } else if abs(distance - current.distance) <= epsilon {
                if shared > current.overlap + epsilon
                    || (abs(shared - current.overlap) <= epsilon && position < current.position) {
                    best = candidate
                }
            }
        }
        return best?.id
    }

    static func normalised(_ fractions: [Double]) -> [Double] {
        let total = fractions.reduce(0, +)
        guard total > 0 else { return fractions.map { _ in 1 / Double(max(fractions.count, 1)) } }
        return fractions.map { $0 / total }
    }
}

/// A remembered split: one tree of panes.
public struct SplitGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var root: SplitNode

    public init(id: UUID = UUID(), root: SplitNode) {
        self.id = id
        self.root = root
    }
}

// MARK: - Space operations

extension Space {
    /// At most this many panes in one split; beyond that panes get too small to be useful.
    public static let maxPanesPerSplit = 6

    public func splitGroup(containing tabID: UUID) -> SplitGroup? {
        splits.first { $0.root.contains(tabID) }
    }

    /// Tabs on screen: the selected tab's whole split, or just the selected tab.
    public var visibleTabIDs: [UUID] {
        guard let selected = selectedTabID else { return [] }
        return splitGroup(containing: selected)?.root.tabIDs ?? [selected]
    }

    /// Shows `tabID` next to `target` on `edge`. If `tabID` was in another split, it leaves it.
    /// Returns false (and changes nothing) for the same tab twice, unknown tabs, or a full split.
    @discardableResult
    public mutating func split(_ tabID: UUID, beside target: UUID, edge: SplitEdge) -> Bool {
        guard tabID != target, tab(tabID) != nil, tab(target) != nil else { return false }
        if let group = splitGroup(containing: target), !group.root.contains(tabID),
           group.root.tabIDs.count >= Self.maxPanesPerSplit {
            return false
        }
        removeFromSplit(tabID)
        if let index = splits.firstIndex(where: { $0.root.contains(target) }) {
            splits[index].root = splits[index].root.inserting(tabID, beside: target, edge: edge).simplified()
        } else {
            splits.append(SplitGroup(root: SplitNode.pane(tabID: target).inserting(tabID, beside: target, edge: edge)))
        }
        return true
    }

    /// Takes a tab out of its split. A split left with one tab dissolves.
    public mutating func removeFromSplit(_ tabID: UUID) {
        guard let index = splits.firstIndex(where: { $0.root.contains(tabID) }) else { return }
        guard let remaining = splits[index].root.removing(tabID)?.simplified(), case .split = remaining else {
            splits.remove(at: index)
            return
        }
        splits[index].root = remaining
    }

    /// Swaps the panes of two tabs in the same split (a pane dropped onto another pane's middle).
    @discardableResult
    public mutating func swapInSplit(_ first: UUID, _ second: UUID) -> Bool {
        guard first != second, let index = splits.firstIndex(where: { $0.root.contains(first) }),
              splits[index].root.contains(second) else { return false }
        // Swap via a placeholder id so the two replacements don't overwrite each other.
        let placeholder = UUID()
        splits[index].root = splits[index].root
            .replacing(first, with: placeholder)
            .replacing(second, with: first)
            .replacing(placeholder, with: second)
        return true
    }

    /// Shows `newTab` in the pane that currently shows `oldTab` (dropping a tab from outside the
    /// split onto a pane's middle). Tabs of the same split are swapped instead.
    public mutating func replaceInSplit(_ oldTab: UUID, with newTab: UUID) {
        if swapInSplit(oldTab, newTab) { return }
        guard oldTab != newTab, tab(newTab) != nil, splitGroup(containing: oldTab) != nil else { return }
        removeFromSplit(newTab)
        guard let index = splits.firstIndex(where: { $0.root.contains(oldTab) }) else { return }
        splits[index].root = splits[index].root.replacing(oldTab, with: newTab)
    }

    /// Resizes the container at `path` inside a split (after a divider drag).
    public mutating func setSplitFractions(groupID: UUID, path: [Int], fractions: [Double]) {
        guard let index = splits.firstIndex(where: { $0.id == groupID }) else { return }
        splits[index].root = splits[index].root.settingFractions(fractions, at: path)
    }
}

// MARK: - Sidebar rows

/// One row in a sidebar section: a single tab, or a whole split shown as one row (like Arc).
public enum SidebarItem: Hashable, Identifiable, Sendable {
    case tab(UUID)
    case split(groupID: UUID, tabIDs: [UUID])

    public var id: String {
        switch self {
        case .tab(let id): return "tab-\(id)"
        case .split(let groupID, _): return "split-\(groupID)"
        }
    }

    /// The tabs this row stands for.
    public var tabIDs: [UUID] {
        switch self {
        case .tab(let id): return [id]
        case .split(_, let ids): return ids
        }
    }
}

extension Space {
    /// The rows of a sidebar section. A split appears once, as one row, in the section of its
    /// first tab in sidebar order (its "home"); its other tabs are not listed separately.
    public func sidebarItems(in section: SidebarSection) -> [SidebarItem] {
        let order = tabsInSidebarOrder
        var homeSection: [UUID: SidebarSection] = [:]
        for tab in order {
            if let group = splitGroup(containing: tab.id), homeSection[group.id] == nil {
                homeSection[group.id] = tab.section
            }
        }
        var items: [SidebarItem] = []
        var emitted = Set<UUID>()
        for tab in tabs(in: section) {
            guard let group = splitGroup(containing: tab.id) else {
                items.append(.tab(tab.id))
                continue
            }
            guard homeSection[group.id] == section, emitted.insert(group.id).inserted else { continue }
            items.append(.split(groupID: group.id, tabIDs: group.root.tabIDs))
        }
        return items
    }

    /// Reorders rows within a section (SwiftUI `onMove` indices into `sidebarItems(in:)`).
    /// A split row moves all of its tabs in that section together.
    public mutating func moveSidebarItems(in section: SidebarSection, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var items = sidebarItems(in: section)
        let moving = offsets.sorted().map { items[$0] }
        let adjusted = destination - offsets.filter { $0 < destination }.count
        for offset in offsets.sorted(by: >) { items.remove(at: offset) }
        items.insert(contentsOf: moving, at: adjusted)

        // New order of this section's tabs: each row's tabs (in their current array order), then
        // any tabs not shown as rows here (members of a split whose row lives in another section).
        let sectionTabs = tabs(in: section).map(\.id)
        var newOrder: [UUID] = []
        for item in items {
            let members = Set(item.tabIDs)
            newOrder += sectionTabs.filter { members.contains($0) }
        }
        newOrder += sectionTabs.filter { !newOrder.contains($0) }

        let slots = tabs.indices.filter { tabs[$0].section == section }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for (slot, id) in zip(slots, newOrder) {
            if let tab = byID[id] { tabs[slot] = tab }
        }
    }
}
