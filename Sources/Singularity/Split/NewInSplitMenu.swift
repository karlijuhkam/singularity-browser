import AppKit
import SingularityCore
import SwiftUI

/// The "Split Right" / "Split Down" submenus: make a new tab, terminal (or launcher) or note and
/// show it straight away beside `target`, instead of at the end of Tabs. Used by a tab's
/// right-click menu (sidebar rows and split chips), the pane header's split button and the pane
/// header's right-click menu (an AppKit menu, built from the same `items`).
struct NewInSplitItem {
    let title: String
    let run: () -> Void
}

@MainActor
enum NewInSplitActions {
    /// The items of one submenu, in order; nil is a divider. `windowID`: the window the menu was
    /// opened in, made the front one first, so the new pane lands there and not in another window.
    static func items(state: AppState, edge: SplitEdge, target: UUID, windowID: UUID?) -> [NewInSplitItem?] {
        func item(_ title: String, _ action: @escaping () -> Void) -> NewInSplitItem {
            NewInSplitItem(title: title) {
                if let windowID { state.activateWindow(windowID) }
                action()
            }
        }
        var items: [NewInSplitItem?] = [
            item("New Tab") { state.newInSplit(.tab, edge: edge, beside: target) },
            item("New Terminal") { state.newInSplit(.terminal(nil), edge: edge, beside: target) },
        ]
        for launcher in state.launchers {
            items.append(item(launcher.name) { state.newInSplit(.terminal(launcher), edge: edge, beside: target) })
        }
        items.append(item("New Note") { state.newInSplit(.note, edge: edge, beside: target) })
        items.append(nil)
        items.append(item("Choose Tab or Address…") { state.showSplitPalette(edge, beside: target) })
        return items
    }

    /// The two submenus' titles and edges.
    static let edges: [(title: String, edge: SplitEdge)] = [("Split Right", .right), ("Split Down", .bottom)]
}

/// "Split Right ▸" and "Split Down ▸" for SwiftUI menus. Disabled when the split beside `target`
/// is full.
struct NewInSplitMenus: View {
    @Environment(AppState.self) private var state
    @Environment(\.browserWindowID) private var windowID
    let target: UUID
    let space: Space

    var body: some View {
        ForEach(NewInSplitActions.edges, id: \.title) { entry in
            Menu(entry.title) {
                let items = NewInSplitActions.items(state: state, edge: entry.edge, target: target, windowID: windowID)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let item {
                        Button(item.title, action: item.run)
                    } else {
                        Divider()
                    }
                }
            }
            .disabled(!space.hasRoomInSplit(beside: target))
        }
    }
}

/// The same submenus as an AppKit menu, for the pane header's right-click (the header is an
/// NSView in the window's title-bar strip, where SwiftUI's `.contextMenu` can't be relied on).
@MainActor
enum NewInSplitNSMenu {
    static func make(state: AppState, space: Space, target: UUID, windowID: UUID?) -> NSMenu {
        let menu = NSMenu()
        let hasRoom = space.hasRoomInSplit(beside: target)
        for entry in NewInSplitActions.edges {
            let parent = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: entry.title)
            for item in NewInSplitActions.items(state: state, edge: entry.edge, target: target, windowID: windowID) {
                if let item {
                    submenu.addItem(ClosureMenuItem(title: item.title, run: item.run))
                } else {
                    submenu.addItem(.separator())
                }
            }
            parent.submenu = submenu
            // A parent with a submenu is enabled by default; switch it off by hand (no auto-enabling,
            // or AppKit would turn it on again).
            parent.isEnabled = hasRoom
            menu.addItem(parent)
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove from Split") {
            if let windowID { state.activateWindow(windowID) }
            state.removeFromSplit(target)
        })
        return menu
    }
}

/// An NSMenuItem that runs a closure. AppKit menu items call a selector on a target object, so the
/// item is its own target and keeps the closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func runAction() {
        run()
    }
}
