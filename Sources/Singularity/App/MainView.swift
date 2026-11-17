import SingularityCore
import SwiftUI

/// The whole window: sidebar on the left, the selected tab's content on the right,
/// and the command palette floating on top when open. While the welcome flow is open it
/// replaces the sidebar and content.
struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var state = state

        ZStack {
            if state.welcomeCoversWindow {
                // The welcome flow takes the whole window. The sheets below (Arc import) and the
                // palette still work on top of it.
                OnboardingView()
                    .background(VisualEffectBackground())
            } else {
                browser
            }

            if let mode = state.palette {
                // `.id(mode)`: a new mode is a new palette, with an empty field and the first
                // row selected. Without it, choosing "New Terminal" in the palette would hand the
                // typed text and the selected row over to the project picker (SwiftUI keeps a
                // view's @State while the view stays in place).
                // Centred over the page: beside the sidebar and a plugin's panel, not the window.
                GeometryReader { window in
                    CommandPaletteView(mode: mode, frame: paletteFrame(windowWidth: window.size.width))
                }
                .id(mode)
            }
        }
        // Tells AppState which NSWindow the browser window is (little windows bring it forward).
        .background(MainWindowReader { [state] window in
            state.mainWindow = window
            state.applyWindowButtons()
        })
        .onChange(of: state.sidebarIsOffScreen) { state.applyWindowButtons() }
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
        // A browser extension waiting for Install (Chrome Web Store, Add Extension…, a download).
        .sheet(item: Binding(
            get: { state.extensions.pending },
            // Closed some other way than its buttons: same as Cancel (the staged files go).
            set: { if $0 == nil, let pending = state.extensions.pending { state.extensions.cancel(pending) } }
        )) { pending in
            ExtensionApprovalSheet(pending: pending)
        }
        .alert(item: Binding(get: { state.extensions.installMessage }, set: { state.extensions.installMessage = $0 })) { message in
            Alert(title: Text(verbatim: message.title), message: Text(verbatim: message.text))
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

extension MainView {
    /// Sidebar and page. The sidebar is one view in three states: beside the page; hidden (moved
    /// off the window's left edge, so it keeps its scroll position and open folders); and slid
    /// out over the page while the pointer is at the left edge (`SidebarPeekController`).
    /// A plugin's panel, when open, is a column at the window's right edge, beside the page, as
    /// wide as the window allows (`PluginPanelLayout.shownWidth`: the page keeps at least 320 pt).
    fileprivate var browser: some View {
        // Only for the window's width (the panel's room); it fills the window like the ZStack did.
        GeometryReader { window in
            browser(windowWidth: window.size.width)
        }
    }

    /// The width the plugin's panel is drawn at in a window this wide; nil while none is drawn.
    private func shownPanelWidth(windowWidth: CGFloat) -> Double? {
        guard state.shownPanelPlugin != nil else { return nil }
        let sidebar = state.settings.sidebarHidden ? 8 : Double(state.sidebarWidth)
        return PluginPanelLayout.shownWidth(state.pluginPanelWidth, windowWidth: Double(windowWidth), sidebarWidth: sidebar)
    }

    /// Where the palette goes: over the page, between the sidebar (when it is beside the page, not
    /// hidden or slid out over it) and the panel. The welcome flow has neither.
    fileprivate func paletteFrame(windowWidth: CGFloat) -> PaletteLayout.Frame {
        guard !state.welcomeCoversWindow else {
            return PaletteLayout.frame(windowWidth: Double(windowWidth), pageLeading: 0, pageTrailing: 0)
        }
        let leading = state.settings.sidebarHidden ? 8 : Double(state.sidebarWidth)
        let trailing = 8 + (shownPanelWidth(windowWidth: windowWidth) ?? 0)
        return PaletteLayout.frame(windowWidth: Double(windowWidth), pageLeading: leading, pageTrailing: trailing)
    }

    @ViewBuilder
    private func browser(windowWidth: CGFloat) -> some View {
        let width = CGFloat(state.sidebarWidth)
        let hidden = state.settings.sidebarHidden
        let peeking = state.sidebarPeek.isPeeking
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ContentArea()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .padding([.top, .bottom, .trailing], 8)
                    // Hidden: the page has the whole window, with the same 8 pt margin on the left.
                    .padding(.leading, hidden ? 8 : width)
                // Too narrow a window draws no panel; it stays open and ⌃⌘J still closes it.
                if let pluginID = state.shownPanelPlugin, let panelWidth = shownPanelWidth(windowWidth: windowWidth) {
                    PluginPanel(pluginID: pluginID, width: panelWidth)
                }
            }

            if hidden {
                // In that left margin: the strip that notices the pointer at the window's edge.
                SidebarEdgeTrigger { [state] in state.sidebarPeek.pointerReachedEdge() }
                    .frame(width: SidebarPeekController.edgeWidth)
                    .frame(maxHeight: .infinity)
            }

            SidebarView()
                .frame(width: width)
                .overlay(alignment: .trailing) {
                    // The last 6 pt of the sidebar (its own padding, never the page) drag its width.
                    SidebarResizeHandle(
                        width: Double(width),
                        dragged: { [state] in state.sidebarPeek.liveWidth = SidebarLayout.clamp($0) },
                        ended: { [state] in
                            guard let width = state.sidebarPeek.liveWidth else { return }
                            state.updateSettings { $0.sidebarWidth = width }
                            state.sidebarPeek.liveWidth = nil
                        },
                        reset: { [state] in state.updateSettings { $0.sidebarWidth = SidebarLayout.defaultWidth } })
                        .frame(width: 6)
                }
                .background {
                    // Slid out, it floats over the page and needs its own background.
                    if hidden {
                        ZStack {
                            VisualEffectBackground()
                            spaceTint
                        }
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 12, x: 2)
                    }
                }
                // 30 pt further than its width, so the shadow is off screen too.
                .offset(x: hidden && !peeking ? -(width + 30) : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: peeking)
        }
        .background {
            ZStack {
                VisualEffectBackground()
                spaceTint
            }
        }
        .onChange(of: state.welcomeCoversWindow) { state.sidebarPeek.close() }
    }

    private var spaceTint: some View {
        Color(hex: state.selectedSpace?.colorHex ?? "#8A8F98").opacity(0.14)
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
            // An empty Space shows its home without a tab (none is made until something opens).
            HomeView(tabID: nil)
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
