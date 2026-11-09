import SwiftUI

/// The menu bar. Keyboard shortcuts are attached to menu items, which is the standard
/// macOS way: they work wherever focus is, and they are discoverable in the menus.
struct SingularityCommands: Commands {
    let state: AppState

    var body: some Commands {
        // Replaces File → New Window.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { state.showPalette(.newTab) }
                .keyboardShortcut("t")
            Button("New Terminal") { state.openTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Command Palette") { state.showPalette(.newTab) }
                .keyboardShortcut("k")
            Button("Open Location…") { state.showPalette(state.selectedTab == nil ? .newTab : .navigateCurrent) }
                .keyboardShortcut("l")
            Divider()
            Button("New Folder…") { state.promptNewFolder() }
            Button("New Space…") { state.spaceEditor = SpaceEditorRequest(spaceID: nil) }
        }

        // Replaces File → Close (which would close the whole window) with Close Tab.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { state.closeSelectedTab() }
                .keyboardShortcut("w")
                .disabled(state.selectedTab == nil)
        }

        // Spaces: ⌘1…⌘8 pick that Space, ⌘9 the last one (as tabs do in other browsers).
        CommandMenu("Spaces") {
            ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                if let key = Self.spaceShortcut(index: index, count: state.spaces.count) {
                    Button(space.name) { state.selectSpace(space.id) }
                        .keyboardShortcut(key)
                } else {
                    Button(space.name) { state.selectSpace(space.id) }
                }
            }
            Divider()
            Button("Next Tab") { state.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("Previous Tab") { state.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }

        CommandGroup(before: .toolbar) {
            Button("Split with Previous Tab") { state.splitWithPrevious() }
                .keyboardShortcut("\\")
                .disabled(state.selectedTab == nil)
            Button("Remove from Split") { if let id = state.selectedTab?.id { state.removeFromSplit(id) } }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(!isInSplit)
            Menu("Focus Pane") {
                Button("Left") { state.moveFocus(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Right") { state.moveFocus(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Up") { state.moveFocus(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Down") { state.moveFocus(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            .disabled(!isInSplit)
            Divider()
            Button("Reload Page") { selectedController?.reload() }
                .keyboardShortcut("r")
                .disabled(selectedController == nil)
            Button("Back") { selectedController?.goBack() }
                .keyboardShortcut("[")
                .disabled(selectedController?.canGoBack != true)
            Button("Forward") { selectedController?.goForward() }
                .keyboardShortcut("]")
                .disabled(selectedController?.canGoForward != true)
            Divider()
        }
    }

    /// ⌘1…⌘8 for the first eight Spaces, ⌘9 for the last one.
    private static func spaceShortcut(index: Int, count: Int) -> KeyEquivalent? {
        if index == count - 1 { return "9" }
        guard index < 8 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    private var isInSplit: Bool {
        guard let space = state.selectedSpace, let id = space.selectedTabID else { return false }
        return space.splitGroup(containing: id) != nil
    }

    private var selectedController: WebTabController? {
        state.selectedTab.flatMap { state.web.existingController($0.id) }
    }
}
