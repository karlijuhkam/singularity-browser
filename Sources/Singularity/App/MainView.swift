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
    /// This window's record (nil when hosted outside a window scene, as in tests: the front one).
    @Environment(\.browserWindowID) private var windowID

    /// Sheets and the palette belong to the front window only: with two windows, each would
    /// otherwise show the same sheet, and closing one would close both.
    private var isFront: Bool { state.isFront(windowID) }

    private func onlyInFront<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { [state, windowID] in state.isFront(windowID) ? binding.wrappedValue : nil },
                set: { binding.wrappedValue = $0 })
    }

    var body: some View {
        @Bindable var state = state

        ZStack {
            if state.welcomeCovers(windowID) {
                // The welcome flow takes the whole window. The sheets below (Arc import) and the
                // palette still work on top of it.
                OnboardingView()
                    .background(VisualEffectBackground())
            } else {
                browser
            }

            if isFront, let mode = state.palette {
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
        // Tells AppState which NSWindow this browser window is: key → front, close, frame, title.
        .background(BrowserWindowReader { [state, windowID] window in
            guard let id = windowID ?? state.frontWindowID else { return }
            WindowLink.attach(window, id: id, state: state)
            // The Window menu lists windows by title: the Space each one shows.
            let title = state.shownSpace(in: id)?.name ?? "Singularity"
            if window.title != title { window.title = title }
        })
        .onChange(of: state.sidebarIsOffScreen(in: windowID)) { state.applyWindowButtons() }
        // Let the sidebar run up under the (invisible) title bar, next to the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: onlyInFront($state.spaceEditor)) { request in
            SpaceEditorSheet(request: request)
        }
        .sheet(item: onlyInFront($state.nameRequest)) { request in
            NameSheet(request: request)
        }
        .sheet(isPresented: Binding(get: { [state, windowID] in state.isFront(windowID) && state.isImportingFromArc },
                                    set: { state.isImportingFromArc = $0 })) {
            ArcImportSheet()
        }
        // A browser extension waiting for Install (Chrome Web Store, Add Extension…, a download).
        .sheet(item: Binding(
            get: { isFront ? state.extensions.pending : nil },
            // Closed some other way than its buttons: same as Cancel (the staged files go).
            set: { if $0 == nil, let pending = state.extensions.pending { state.extensions.cancel(pending) } }
        )) { pending in
            ExtensionApprovalSheet(pending: pending)
        }
        .alert(item: Binding(get: { isFront ? state.extensions.installMessage : nil }, set: { state.extensions.installMessage = $0 })) { message in
            Alert(title: Text(verbatim: message.title), message: Text(verbatim: message.text))
        }
        .onAppear {
            state.openSettingsWindow = { [openSettings] in openSettings() }
            // "browser" is the id of the browser windows' scene (SingularityApp); its value is the
            // window's record. Opening a record already on screen brings that window forward.
            state.openBrowserWindow = { [openWindow] id in openWindow(id: "browser", value: id) }
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
    /// The plugin whose panel this window draws: the panel is in one window at a time.
    private var panelPlugin: String? {
        state.panelIsIn(windowID) ? state.shownPanelPlugin : nil
    }

    private func shownPanelWidth(windowWidth: CGFloat) -> Double? {
        guard panelPlugin != nil else { return nil }
        let sidebar = state.sidebarHidden(in: windowID) ? 8 : Double(state.sidebarWidth)
        return PluginPanelLayout.shownWidth(state.pluginPanelWidth, windowWidth: Double(windowWidth), sidebarWidth: sidebar)
    }

    /// Where the palette goes: over the page, between the sidebar (when it is beside the page, not
    /// hidden or slid out over it) and the panel. The welcome flow has neither.
    fileprivate func paletteFrame(windowWidth: CGFloat) -> PaletteLayout.Frame {
        guard !state.welcomeCovers(windowID) else {
            return PaletteLayout.frame(windowWidth: Double(windowWidth), pageLeading: 0, pageTrailing: 0)
        }
        let leading = state.sidebarHidden(in: windowID) ? 8 : Double(state.sidebarWidth)
        let trailing = 8 + (shownPanelWidth(windowWidth: windowWidth) ?? 0)
        return PaletteLayout.frame(windowWidth: Double(windowWidth), pageLeading: leading, pageTrailing: trailing)
    }

    @ViewBuilder
    private func browser(windowWidth: CGFloat) -> some View {
        let width = CGFloat(state.sidebarWidth)
        let hidden = state.sidebarHidden(in: windowID)
        // Only the front window's hidden sidebar slides out (one slide-out controller).
        let peeking = isFront && state.sidebarPeek.isPeeking
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ContentArea()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .padding([.top, .bottom, .trailing], 8)
                    // Hidden: the page has the whole window, with the same 8 pt margin on the left.
                    .padding(.leading, hidden ? 8 : width)
                // Too narrow a window draws no panel; it stays open and ⌃⌘J still closes it.
                if let pluginID = panelPlugin, let panelWidth = shownPanelWidth(windowWidth: windowWidth) {
                    PluginPanel(pluginID: pluginID, width: panelWidth)
                }
            }

            if hidden && isFront {
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
        .onChange(of: state.welcomeCovers(windowID)) { state.sidebarPeek.close() }
    }

    private var spaceTint: some View {
        Color(hex: state.shownSpace(in: windowID)?.colorHex ?? "#8A8F98").opacity(0.14)
    }
}

/// The selected tab's content: the tab alone, or the whole split it belongs to (Arc-style:
/// a split comes back whenever one of its tabs is selected).
private struct ContentArea: View {
    @Environment(AppState.self) private var state
    @Environment(\.browserWindowID) private var windowID

    var body: some View {
        if let space = state.shownSpace(in: windowID), let tab = space.selectedTab {
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
