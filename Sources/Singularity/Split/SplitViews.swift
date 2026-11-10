import SingularityCore
import SwiftUI

/// What one tab shows: its web view or terminal, or a placeholder while it starts.
/// Used for a single tab and for every pane of a split.
struct TabContentView: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    /// In a split, only the focused pane's terminal grabs keyboard focus.
    var isFocused = true

    var body: some View {
        let onDrop: (UUID, PaneDropZone) -> Void = { [state, tabID = tab.id] dropped, zone in
            state.handleTabDrop(dropped, onto: tabID, zone: zone)
        }
        if let controller = state.web.existingController(tab.id) {
            HostedView(view: controller.webView, tabID: tab.id, onDrop: onDrop)
                .overlay(alignment: .top) { LoadingBar(controller: controller) }
                .overlay(alignment: .topTrailing) {
                    if controller.isFindBarVisible { FindBar(controller: controller) }
                }
        } else if let session = state.terminals.existingSession(tab.id) {
            HostedView(view: session.view, tabID: tab.id, focusOnShow: isFocused, onDrop: onDrop)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                // A new session (after a restart) gets a new view; `.id` makes SwiftUI rebuild the host.
                .id(ObjectIdentifier(session))
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// A thin progress bar at the top of a page while it loads.
struct LoadingBar: View {
    let controller: WebTabController

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * controller.estimatedProgress, height: 2)
                .opacity(controller.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: controller.estimatedProgress)
        }
        .frame(height: 2)
    }
}

/// Find in page (⌘F): a small bar in the page's top right corner. Return finds the next match,
/// ⇧Return the previous one, Esc closes it.
struct FindBar: View {
    @Bindable var controller: WebTabController
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find on page", text: $controller.findText)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($isFocused)
                .foregroundStyle(controller.findFailed ? Color.red : Color.primary)
                .onSubmit { controller.find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: controller.findText) { controller.find() }
                .onExitCommand { controller.hideFindBar() }
            Button { controller.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous match")
            Button { controller.find() } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next match")
            Button { controller.hideFindBar() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close find bar")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .padding(10)
        .onAppear { isFocused = true }
        // ⌘F while the bar is open (focus may be in the page): take the keyboard back.
        .onChange(of: controller.findFocusToken) { isFocused = true }
    }
}

// MARK: - Split layout

/// Shows a split group: a tree of panes with draggable gaps between them.
struct SplitGroupView: View {
    let group: SplitGroup
    let space: Space

    var body: some View {
        SplitNodeView(node: group.root, path: [], groupID: group.id, space: space)
    }
}

/// One node of the split tree: either a pane, or a row/column of child nodes.
private struct SplitNodeView: View {
    let node: SplitNode
    let path: [Int]
    let groupID: UUID
    let space: Space

    var body: some View {
        switch node {
        case .pane(let tabID):
            PaneView(tabID: tabID, space: space)
                .id(tabID)
        case .split(let axis, let children, let fractions):
            SplitStackView(axis: axis, children: children, fractions: fractions, path: path, groupID: groupID, space: space)
        }
    }
}

/// Lays children out side by side (horizontal) or stacked (vertical), sized by `fractions`.
/// The gaps between them are handles: drag one to resize its two neighbours.
private struct SplitStackView: View {
    @Environment(AppState.self) private var state
    let axis: SplitAxis
    let children: [SplitNode]
    let fractions: [Double]
    let path: [Int]
    let groupID: UUID
    let space: Space

    /// Fractions while a gap is being dragged (saved to the model when the drag ends).
    @State private var liveFractions: [Double]?
    @State private var dragStartFractions: [Double]?

    private static let gap: CGFloat = 6
    private static let minimumPane: CGFloat = 160

    var body: some View {
        GeometryReader { geometry in
            let horizontal = axis == .horizontal
            let total = horizontal ? geometry.size.width : geometry.size.height
            let available = max(total - Self.gap * CGFloat(children.count - 1), 1)
            let current = liveFractions ?? fractions
            let sizes = current.map { CGFloat($0) * available }
            let starts = sizes.indices.map { index in
                sizes[..<index].reduce(0, +) + CGFloat(index) * Self.gap
            }

            ZStack(alignment: .topLeading) {
                ForEach(children.indices, id: \.self) { index in
                    SplitNodeView(node: children[index], path: path + [index], groupID: groupID, space: space)
                        .frame(width: horizontal ? sizes[index] : geometry.size.width,
                               height: horizontal ? geometry.size.height : sizes[index])
                        .offset(x: horizontal ? starts[index] : 0, y: horizontal ? 0 : starts[index])
                }
                ForEach(1..<max(children.count, 1), id: \.self) { index in
                    gapHandle(between: index - 1, and: index, available: available, horizontal: horizontal)
                        .frame(width: horizontal ? Self.gap : geometry.size.width,
                               height: horizontal ? geometry.size.height : Self.gap)
                        .offset(x: horizontal ? starts[index] - Self.gap : 0, y: horizontal ? 0 : starts[index] - Self.gap)
                }
            }
        }
    }

    private func gapHandle(between first: Int, and second: Int, available: CGFloat, horizontal: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartFractions ?? fractions
                        if dragStartFractions == nil { dragStartFractions = fractions }
                        let delta = Double((horizontal ? value.translation.width : value.translation.height) / available)
                        let minimum = Double(Self.minimumPane / available)
                        let pair = start[first] + start[second]
                        // Move the boundary, keeping both neighbours at least the minimum size.
                        let newFirst = min(max(start[first] + delta, minimum), pair - minimum)
                        var updated = start
                        updated[first] = newFirst
                        updated[second] = pair - newFirst
                        liveFractions = updated
                    }
                    .onEnded { _ in
                        if let liveFractions {
                            state.setSplitFractions(groupID: groupID, path: path, fractions: liveFractions)
                        }
                        liveFractions = nil
                        dragStartFractions = nil
                    }
            )
    }
}

/// One pane: a header (title, split menu, remove button) above the tab's content.
private struct PaneView: View {
    @Environment(AppState.self) private var state
    let tabID: UUID
    let space: Space

    var body: some View {
        if let tab = space.tab(tabID) {
            let isFocused = space.selectedTabID == tabID
            VStack(spacing: 0) {
                PaneHeader(tab: tab, space: space, isFocused: isFocused)
                TabContentView(tab: tab, isFocused: isFocused)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: isFocused ? 2 : 1)
            )
        }
    }
}

private struct PaneHeader: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space
    let isFocused: Bool

    var body: some View {
        ZStack {
            // Drag the header onto another pane to move this one; click to focus it.
            PaneDragHandle(tabID: tab.id, title: tab.displayTitle) { [state, tabID = tab.id] in
                state.focusPane(tabID)
            }
            HStack(spacing: 6) {
                // Icon and title let clicks and drags fall through to the handle underneath.
                Group {
                    TabIcon(tab: tab, space: space)
                        .frame(width: 12, height: 12)
                    Text(tab.displayTitle)
                        .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    AgentBadge(tab: tab)
                    Spacer(minLength: 4)
                }
                .allowsHitTesting(false)
                Menu {
                    Button("Split Right…") { state.showSplitPalette(.right, beside: tab.id) }
                    Button("Split Down…") { state.showSplitPalette(.bottom, beside: tab.id) }
                    Divider()
                    Button("Remove from Split") { state.removeFromSplit(tab.id) }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Split this pane")
                Button {
                    state.removeFromSplit(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Remove from split (the tab stays open)")
            }
            .padding(.horizontal, 8)
        }
        .foregroundStyle(isFocused ? .primary : .secondary)
        .frame(height: 24)
        .background(.bar)
        .overlay {
            if state.isAgentBusy(tab.id) {
                agentTint.opacity(0.18).allowsHitTesting(false)
            }
        }
    }
}
