import AppKit
import SingularityCore
import SwiftUI

/// The herdr-core terminals under a terminal tab (a Bot's workers, its topics, a dev server
/// started with `hc run --bg`), listed under the tab's row. They are not tabs: nothing here is
/// saved, dragged, pinned or closed. A click shows the terminal in the tab's pane.
/// Spec: `docs/superpowers/specs/2026-11-16-herdr-child-terminals-design.md`.

/// A terminal tab that has child terminals: its own row with a fold triangle, then their rows.
///
/// All of it is one List row, and it is not tagged for the List's selection (like a split's row
/// of chips): the List would highlight the whole block and take the clicks meant for one line
/// of it. So the taps select and the highlight is drawn here.
struct TabWithChildrenRow: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let space: Space
    let children: HerdrChildren

    var body: some View {
        let isCollapsed = state.herdr.collapsed.contains(tab.id)
        let isSelected = space.selectedTabID == tab.id
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                TabRow(tab: tab, space: space)
                // Folded away, the tab's row says when something under it waits for the owner.
                if isCollapsed, children.needsYou { HerdrMarkView(mark: .needsYou) }
                // Inside the row, at its end: a view hung outside the row's bounds may get no clicks.
                Button {
                    if isCollapsed { state.herdr.collapsed.remove(tab.id) } else { state.herdr.collapsed.insert(tab.id) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Show the terminals under this one" : "Hide the terminals under this one")
            }
            .frame(minHeight: 22)
            // The highlight reaches a little past the row, so the tab's icon stays in line with
            // the icons of the rows above and below.
            .background(HerdrRowHighlight(isOn: HerdrShown.ownIsHighlighted(isSelected: isSelected, shownChild: state.shownChild[tab.id]))
                .padding(.horizontal, -4))
            .contentShape(Rectangle())
            .onTapGesture { state.showOwnTerminal(tab.id) }
            if !isCollapsed {
                HerdrChildList(tab: tab, children: children, tabIsOnScreen: isSelected)
            }
        }
        .background(ListDragOperations())
        // At the List row's root, where the List looks for it: the tab can still be dragged onto
        // the page (a split) or into another section.
        .itemProvider { TabDrag.provider(for: tab.id) }
    }
}

/// The child rows of one tab (also used under a split's row, for each of its terminal tabs).
struct HerdrChildList: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let children: HerdrChildren
    /// The tab's pane is on screen: the tab is selected, or (under a split's row) its split is shown.
    let tabIsOnScreen: Bool

    var body: some View {
        ForEach(children.rows) { row in
            HerdrChildRowView(row: row, isShown: HerdrShown.childIsHighlighted(tabIsOnScreen: tabIsOnScreen,
                                                                    shownChild: state.shownChild[tab.id],
                                                                    address: row.address))
                .onTapGesture { state.showChild(row.address, under: tab.id) }
        }
        if children.more > 0 {
            Text("and \(children.more) more")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }
}

private struct HerdrChildRowView: View {
    let row: HerdrChildRow
    let isShown: Bool

    var body: some View {
        HStack(spacing: 6) {
            HerdrMarkView(mark: row.mark)
            // The name comes from whatever program named the terminal: text only, never markup.
            Text(verbatim: row.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.level * 14))
        .padding(.trailing, 4)
        .frame(minHeight: 20)
        .background(HerdrRowHighlight(isOn: isShown))
        .contentShape(Rectangle())
        .help(row.folder.map { "\(row.address) in \(HomePath.abbreviate($0))" } ?? row.address)
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.address, forType: .string)
            }
        }
    }
}

private struct HerdrRowHighlight: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(isOn ? 0.14 : 0))
    }
}

/// What a child terminal's program last reported, as a small mark.
struct HerdrMarkView: View {
    let mark: HerdrMark

    var body: some View {
        Group {
            switch mark {
            case .working:
                Image(systemName: "circle.fill").foregroundStyle(Color.accentColor)
            case .needsYou:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .error:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .done:
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
            case .none:
                Color.clear
            }
        }
        .font(.system(size: mark == .working || mark == .idle ? 7 : 10))
        .frame(width: 12, height: 12)
        .accessibilityLabel(Self.label(mark))
    }

    static func label(_ mark: HerdrMark) -> String {
        switch mark {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .error: return "Error"
        case .done: return "Done"
        case .idle: return "Idle"
        case .none: return ""
        }
    }
}

/// The strip under a child terminal shown in a tab's pane: whose child this is, and the way back.
/// Without it the owner could type into a worker believing it is the Bot. (At the bottom, not
/// the top: the top of a lone pane is the window's title-bar strip, where clicks drag the window.)
struct HerdrChildStrip: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab
    let address: String

    var body: some View {
        let name = state.herdr.facts.terminals[address].map(HerdrFacts.rowName) ?? address
        HStack(spacing: 6) {
            Button {
                state.showOwnTerminal(tab.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    Text(verbatim: tab.displayTitle).lineLimit(1)
                }
            }
            .buttonStyle(.borderless)
            Text("/").foregroundStyle(.tertiary)
            Text(verbatim: name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(verbatim: address).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color.primary.opacity(0.06))
    }
}

/// What a tab's pane shows after the child terminal shown in it has ended. The tab's own terminal
/// does not take the pane back by itself: the owner may be in the middle of typing to the child,
/// and the rest would land in the tab's own program.
struct HerdrChildEnded: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            VStack(spacing: 10) {
                Text("This terminal has ended.")
                    .foregroundStyle(.secondary)
                Button {
                    state.showOwnTerminal(tab.id)
                } label: {
                    Text(verbatim: "Back to \(tab.displayTitle)")
                }
            }
        }
    }
}
