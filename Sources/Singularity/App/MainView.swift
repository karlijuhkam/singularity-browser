import SingularityCore
import SwiftUI

/// The whole window: sidebar on the left, the selected tab's content on the right,
/// and the command palette floating on top when open. While the welcome flow is open it
/// replaces the sidebar and content.
struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state

        ZStack {
            if state.welcomeCoversWindow {
                // The welcome flow takes the whole window. The sheets below (Arc import) and the
                // palette still work on top of it.
                OnboardingView()
                    .background(VisualEffectBackground())
            } else {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 270)
                    ContentArea()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .padding([.top, .bottom, .trailing], 8)
                }
                .background {
                    ZStack {
                        VisualEffectBackground()
                        Color(hex: state.selectedSpace?.colorHex ?? "#8A8F98").opacity(0.14)
                    }
                }
            }

            if let mode = state.palette {
                // `.id(mode)`: a new mode is a new palette, with an empty field and the first
                // row selected. Without it, choosing "New Terminal" in the palette would hand the
                // typed text and the selected row over to the project picker (SwiftUI keeps a
                // view's @State while the view stays in place).
                CommandPaletteView(mode: mode)
                    .id(mode)
            }
        }
        // Tells AppState which NSWindow the browser window is (little windows bring it forward).
        .background(MainWindowReader { [state] window in state.mainWindow = window })
        // Let the sidebar run up under the (invisible) title bar, next to the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $state.spaceEditor) { request in
            SpaceEditorSheet(request: request)
        }
        .sheet(item: $state.nameRequest) { request in
            NameSheet(request: request)
        }
        .sheet(isPresented: $state.isImportingFromArc) {
            ArcImportSheet()
        }
        .onAppear {
            state.openSettingsWindow = { [openSettings] in openSettings() }
            // "main" is the id of the browser window's scene (SingularityApp). Opening it shows
            // the window again after it was closed, or brings it forward.
            state.openMainWindow = { [openWindow] in openWindow(id: "main") }
            state.loadSelectedTab()
            // Clicking inside a pane (a web page or terminal) focuses it.
            PaneContainerView.installFocusMonitor { [state] tabID in state.focusPane(tabID) }
        }
    }

}

/// The selected tab's content: the tab alone, or the whole split it belongs to (Arc-style:
/// a split comes back whenever one of its tabs is selected).
private struct ContentArea: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let space = state.selectedSpace, let tab = space.selectedTab {
            if let group = space.splitGroup(containing: tab.id) {
                SplitGroupView(group: group, space: space)
            } else {
                TabContentView(tab: tab)
            }
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                VStack(spacing: 8) {
                    // Like singularity.rroosa.ee: a white orb in dark mode, a black one in light mode.
                    // It may stay on screen all day, so it holds still when nobody moves the pointer.
                    OrbView(size: 96, stopsWhenIdle: true)
                        .padding(.bottom, 8)
                    Text(state.selectedSpace?.name ?? "")
                        .font(.title2.weight(.semibold))
                    Text("Press ⌘T to open a tab, or ⌥⌘T for a terminal")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The translucent "sidebar" material behind the window content, via AppKit's NSVisualEffectView
/// (SwiftUI materials blend with the window's content; this one blends with the desktop behind it).
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Finds the NSWindow this SwiftUI view is shown in. SwiftUI has no API for that, so an invisible
/// AppKit view reports its `window` once it has been put into one.
private struct MainWindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window yet while it is being made; ask one run-loop turn later.
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { found(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { found(window) }
    }
}
