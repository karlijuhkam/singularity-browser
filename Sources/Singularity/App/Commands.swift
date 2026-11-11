import SwiftUI

/// The menu bar. Keyboard shortcuts are attached to menu items, which is the standard
/// macOS way: they work wherever focus is, and they are discoverable in the menus.
///
/// While the welcome flow covers the window (`state.welcomeCoversWindow`), every command that
/// acts on the hidden tab, page or sidebar is off, and Close Tab (⌘W) closes the flow instead
/// (unless a sheet is open over it: `AppState.closeTabCommand`).
/// Commands that leave the flow on purpose and go somewhere (New Tab, New Terminal, the palette,
/// Open Location, picking a Space, New Space) keep working: they close the flow themselves.
struct SingularityCommands: Commands {
    let state: AppState

    var body: some Commands {
        // Singularity → Welcome to Singularity… (under "About Singularity"): the welcome flow again.
        CommandGroup(after: .appInfo) {
            Button("Welcome to Singularity…") { state.showWelcome() }
        }

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
            // Adds a folder to the hidden sidebar, so it waits until the flow is closed.
            Button("New Folder…") { state.promptNewFolder() }
                .disabled(covered)
            Button("New Space…") { state.showSpaceEditor(spaceID: nil) }
            Divider()
            // The flow's step 1 offers the same import; it stays open for it.
            Button("Import from Arc…") { state.isImportingFromArc = true }
        }

        // Replaces File → Close (which would close the whole window) with Close Tab.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                // ⌘W on the welcome flow closes the flow, never the tab hidden behind it, and
                // nothing while a sheet is open over the flow.
                state.closeTabCommand()
            }
            .keyboardShortcut("w")
            .disabled(covered ? state.welcomeSheetIsOpen : state.selectedTab == nil)
        }

        // Edit → Find. Web pages only; WKWebView has no find bar, so the tab draws its own (FindBar).
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { selectedController?.showFindBar() }
                .keyboardShortcut("f")
                .disabled(selectedController == nil)
            Button("Find Next") { selectedController?.find() }
                .keyboardShortcut("g")
                .disabled(selectedController?.findText.isEmpty != false)
            Button("Find Previous") { selectedController?.find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(selectedController?.findText.isEmpty != false)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { selectedController?.printPage() }
                .keyboardShortcut("p")
                .disabled(selectedController == nil)
        }

        // Spaces: ⌘1…⌘8 pick that Space, ⌘9 the last one (as tabs do in other browsers).
        CommandMenu("Spaces") {
            ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                if let key = Self.spaceShortcut(index: index, count: state.spaces.count) {
                    Button(space.name) { state.userSelectSpace(space.id) }
                        .keyboardShortcut(key)
                } else {
                    Button(space.name) { state.userSelectSpace(space.id) }
                }
            }
            Divider()
            Button("Next Tab") { state.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled(covered)
            Button("Previous Tab") { state.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(covered)
        }

        CommandGroup(before: .toolbar) {
            Button("Split with Previous Tab") { state.splitWithPrevious() }
                .keyboardShortcut("\\")
                .disabled(covered || state.selectedTab == nil)
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
            Button("Zoom In") { selectedController?.zoom(larger: true) }
                .keyboardShortcut("+")
                .disabled(selectedController == nil)
            Button("Zoom Out") { selectedController?.zoom(larger: false) }
                .keyboardShortcut("-")
                .disabled(selectedController == nil)
            Button("Actual Size") { selectedController?.resetZoom() }
                .keyboardShortcut("0")
                .disabled(selectedController == nil)
            Divider()
        }
    }

    /// ⌘1…⌘8 for the first eight Spaces, ⌘9 for the last one.
    private static func spaceShortcut(index: Int, count: Int) -> KeyEquivalent? {
        if index == count - 1 { return "9" }
        guard index < 8 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    /// The welcome flow hides the sidebar and the tab (see the type's comment).
    private var covered: Bool { state.welcomeCoversWindow }

    private var isInSplit: Bool {
        guard !covered, let space = state.selectedSpace, let id = space.selectedTabID else { return false }
        return space.splitGroup(containing: id) != nil
    }

    /// The selected tab's web page, or nil while the welcome flow hides it. Every page command
    /// (Find, Print, Reload, Back, Forward, Zoom) goes through this, so they are all off then.
    private var selectedController: WebTabController? {
        guard !covered else { return nil }
        return state.selectedTab.flatMap { state.web.existingController($0.id) }
    }
}
