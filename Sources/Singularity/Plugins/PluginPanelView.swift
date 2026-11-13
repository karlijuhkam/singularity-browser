import AppKit
import SingularityCore
import SwiftUI

/// What a plugin's page area shows: the page itself while the plugin's background runs, else a
/// native page that says why not.
enum PluginPageContent {
    case page(PluginPageHost)
    /// No page yet, but it is coming (at launch, or just approved): "<Title> is starting".
    case starting(title: String)
    case notRunning(title: String, reason: String)
}

extension AppState {
    /// Asked every time the page area is drawn, never kept: the manager makes a new page (a new
    /// host with a new web view) after any stop and start of the plugin, and the old one is torn
    /// down. `fallbackTitle`: a tab's stored title, for a plugin that is gone.
    func pluginPageContent(_ id: String, fallbackTitle: String = "") -> PluginPageContent {
        if let host = plugins.pageHost(for: id) { return .page(host) }
        if plugins.pageIsStarting(id) { return .starting(title: "\(pluginTitle(id, fallback: fallbackTitle)) is starting") }
        return .notRunning(title: "\(pluginTitle(id, fallback: fallbackTitle)) isn't running",
                           reason: plugins.notRunningReason(id))
    }
}

/// The right-hand panel of the main window: a column beside the content area (splits included),
/// with a 1 pt line and a width strip on its left edge, a header row, and the plugin's page.
/// It belongs to the window, not to a Space, so it stays through tab and Space switches.
struct PluginPanel: View {
    @Environment(AppState.self) private var state
    let pluginID: String
    /// The width it is drawn at: its own (`pluginPanelWidth`), or less in a narrow window.
    let width: Double

    /// The window's title bar is invisible but still there (the content runs under it), and
    /// macOS starts a window drag on a click in it before asking the view. The header sits below
    /// it, so its menu gets every click.
    static let titleBarHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            VStack(spacing: 0) {
                PluginPanelHeader(pluginID: pluginID)
                Divider()
                PluginPageArea(pluginID: pluginID)
            }
            .padding(.top, Self.titleBarHeight)
        }
        .frame(width: CGFloat(width))
        .overlay(alignment: .leading) {
            // Straddles the line: 3 pt over the page's margin, 3 pt over the panel. Works like the
            // sidebar's strip: live while dragging, saved on mouse-up, double-click resets.
            SidebarResizeHandle(
                width: width,   // a drag starts from what is on screen
                dragged: { [state] in state.pluginPanelLiveWidth = PluginPanelLayout.clamp($0) },
                ended: { [state] in
                    guard let width = state.pluginPanelLiveWidth else { return }
                    state.updateSettings { $0.pluginPanelWidth = width }
                    state.pluginPanelLiveWidth = nil
                },
                reset: { [state] in state.updateSettings { $0.pluginPanelWidth = PluginPanelLayout.defaultWidth } },
                growsLeftward: true)
                .frame(width: 6)
                .offset(x: -3)
        }
    }
}

/// The panel's header: the plugin's title, and a menu with Open as Tab, Close and (with more
/// than one panel plugin) the others to switch to.
private struct PluginPanelHeader: View {
    @Environment(AppState.self) private var state
    let pluginID: String

    var body: some View {
        let panelPlugins = state.plugins.panelPlugins()
        HStack(spacing: 6) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // The title comes from the plugin's manifest: shown as text, never as Markdown.
            Text(verbatim: state.pluginTitle(pluginID))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Menu {
                Button("Open as Tab") { state.openPluginPageAsTab(pluginID) }
                Button("Close") { state.closePluginPanel() }
                if panelPlugins.count > 1 {
                    Divider()
                    ForEach(panelPlugins) { plugin in
                        // A Toggle in a menu is drawn as an item with a checkmark.
                        Toggle(isOn: Binding(
                            get: { plugin.id == pluginID },
                            set: { isOn in if isOn { state.showPluginPanel(plugin.id) } }
                        )) {
                            Text(verbatim: state.pluginTitle(plugin.id))
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Panel menu")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// The plugin's page, in the panel or in a tab (and a tab's split pane): the page's web view
/// while the plugin runs, else the native "isn't running" page. The web view can only be in one
/// place, so it is hosted like a tab's view (`HostedView`: the newest container owns it).
struct PluginPageArea: View {
    @Environment(AppState.self) private var state
    let pluginID: String
    /// A tab's stored title, for a plugin that is gone.
    var fallbackTitle = ""
    /// Set for a tab: drag-and-drop onto the pane and click-to-focus. Nil in the panel.
    var tabID: UUID?
    var onDrop: ((UUID, PaneDropZone) -> Void)?

    var body: some View {
        switch state.pluginPageContent(pluginID, fallbackTitle: fallbackTitle) {
        case .page(let host):
            HostedView(view: host.webView, tabID: tabID, onDrop: onDrop)
                // After the plugin stopped and started again the page is a new web view; `.id`
                // makes SwiftUI build a new container for it, as for a restarted terminal.
                .id(ObjectIdentifier(host))
        case .starting(let title):
            PluginStartingView(title: title)
                .simultaneousGesture(TapGesture().onEnded { if let tabID { state.focusPane(tabID) } })
        case .notRunning(let title, let reason):
            PluginNotRunningView(title: title, reason: reason)
                // In a split, a click here focuses the pane (the click monitor only sees hosted views).
                .simultaneousGesture(TapGesture().onEnded { if let tabID { state.focusPane(tabID) } })
        }
    }
}

/// Shown for the moment before the page comes: at launch, before the plugins were read, and while
/// an approved plugin's background starts. The page replaces it by itself.
private struct PluginStartingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Starting…")
            Text(verbatim: title)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown instead of the page while the plugin's background doesn't run (not approved, changed,
/// stopped after crashes, removed). The page comes back by itself when the plugin does.
private struct PluginNotRunningView: View {
    @Environment(AppState.self) private var state
    let title: String
    let reason: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(verbatim: title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(verbatim: reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Plugin Settings") { state.showPluginSettings() }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
