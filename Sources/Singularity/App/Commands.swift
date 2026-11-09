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

    private var isInSplit: Bool {
        guard let space = state.selectedSpace, let id = space.selectedTabID else { return false }
        return space.splitGroup(containing: id) != nil
    }

    private var selectedController: WebTabController? {
        state.selectedTab.flatMap { state.web.existingController($0.id) }
    }
}
