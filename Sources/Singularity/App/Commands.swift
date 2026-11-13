import SwiftUI

/// The menu bar. Keyboard shortcuts are attached to menu items, which is the standard
/// macOS way: they work wherever focus is, and they are discoverable in the menus.
///
/// While the welcome flow covers the window (`state.welcomeCoversWindow`), every command that
/// acts on the hidden tab, page or sidebar is off, and Close Tab (⌘W) closes the flow instead
/// (unless a sheet is open over it: `AppState.closeTabCommand`).
/// Commands that leave the flow on purpose and go somewhere (New Tab, New Terminal, the palette,
/// Open Location, picking a Space, New Space) keep working: they close the flow themselves.
///
/// While a little window has the keyboard (`state.little.frontWindow`), the page commands act on its
/// page, ⌘W closes it and ⌘O opens it in the chosen Space; commands for the main window's tab,
/// sidebar or layout are off. Commands that go somewhere in the main window bring it forward.
struct SingularityCommands: Commands {
    let state: AppState

    var body: some Commands {
        // Under "About Singularity": Check for Updates… (off while Sparkle is busy, and in copies that
        // don't update themselves) and Welcome to Singularity… (the welcome flow again).
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { state.updates.checkNow() }
                .disabled(!state.updates.canCheck)
            Button("Welcome to Singularity…") { inMainWindow { state.showWelcome() } }
        }

        // Replaces File → New Window.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { inMainWindow { state.showPalette(.newTab) } }
                .keyboardShortcut("t")
            Button("New Terminal") { inMainWindow { state.openTerminal() } }
                .keyboardShortcut("t", modifiers: [.command, .option])
            // Shows the project picker even inside a folder that has a project. In a Space
            // without projects there is nothing to pick, and it opens a terminal like New Terminal.
            Button("New Terminal in…") { inMainWindow { state.openTerminalChoosingProject() } }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            Button("Command Palette") { inMainWindow { state.showPalette(.newTab) } }
                .keyboardShortcut("k")
            // Changes the main window's selected tab, so it is off while a little window is in front.
            Button("Open Location…") { state.showPalette(state.selectedTab == nil ? .newTab : .navigateCurrent) }
                .keyboardShortcut("l")
                .disabled(littleInFront)
            // A little window: its page becomes a tab of the Space chosen in its title bar.
            Button(openInSpaceTitle) { if let key = state.little.frontWindow { state.little.openInSpace(key) } }
                .keyboardShortcut("o")
                .disabled(!littleInFront)
            Divider()
            // Adds a folder to the hidden sidebar, so it waits until the flow is closed.
            Button("New Folder…") { state.promptNewFolder() }
                .disabled(covered || littleInFront)
            Button("New Space…") { inMainWindow { state.showSpaceEditor(spaceID: nil) } }
            Divider()
            // The flow's step 1 offers the same import; it stays open for it.
            Button("Import from Arc…") { inMainWindow { state.isImportingFromArc = true } }
        }

        // Replaces File → Close (which would close the whole window) with Close Tab.
        CommandGroup(replacing: .saveItem) {
            Button(littleInFront ? "Close Window" : "Close Tab") {
                // ⌘W on a little window closes that window. On the welcome flow it closes the
                // flow, never the tab hidden behind it, and nothing while a sheet is open over it.
                state.closeTabCommand()
            }
            .keyboardShortcut("w")
            .disabled(littleInFront ? false : (covered ? state.welcomeSheetIsOpen : state.selectedTab == nil))
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
                    Button(space.name) { inMainWindow { state.userSelectSpace(space.id) } }
                        .keyboardShortcut(key)
                } else {
                    Button(space.name) { inMainWindow { state.userSelectSpace(space.id) } }
                }
            }
            Divider()
            Button("Next Tab") { state.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled(covered || littleInFront)
            Button("Previous Tab") { state.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(covered || littleInFront)
        }

        CommandGroup(before: .toolbar) {
            // Opened by the owner, so the panel takes the keyboard (Tab moves through its buttons).
            Button("Show Inbox") { state.inbox.showPanel(takingFocus: true) }
                .keyboardShortcut("i", modifiers: [.control, .command])
            // Hidden, the sidebar slides out while the pointer is at the window's left edge.
            Button(state.settings.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { state.toggleSidebar() }
                .keyboardShortcut("s")
                .disabled(covered || littleInFront)
            Divider()
            Button("Split with Previous Tab") { state.splitWithPrevious() }
                .keyboardShortcut("\\")
                .disabled(covered || littleInFront || state.selectedTab == nil)
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

    /// A little window has the keyboard (see the type's comment).
    private var littleInFront: Bool { state.little.frontWindow != nil }

    private var openInSpaceTitle: String {
        guard let key = state.little.frontWindow,
              let space = state.space(key.chosenSpaceID) ?? state.space(key.homeSpaceID) else { return "Open in Space" }
        return "Open in \(space.name)"
    }

    /// For commands that go somewhere in the browser window: brings it forward first when a
    /// little window is in front (which stays open behind it).
    private func inMainWindow(_ action: () -> Void) {
        if littleInFront { state.showMainWindow() }
        action()
    }

    private var isInSplit: Bool {
        guard !covered, !littleInFront, let space = state.selectedSpace, let id = space.selectedTabID else { return false }
        return space.splitGroup(containing: id) != nil
    }

    /// The page in front: a little window's when one has the keyboard, else the selected tab's
    /// (nil while the welcome flow hides it). Every page command (Find, Print, Reload, Back,
    /// Forward, Zoom) goes through this.
    private var selectedController: WebTabController? { state.frontController }
}
