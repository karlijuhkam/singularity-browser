import SingularityCore
import SwiftUI

/// The whole window: sidebar on the left, the selected tab's content on the right,
/// and the command palette floating on top when open.
struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        ZStack {
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

            if let mode = state.palette {
                CommandPaletteView(mode: mode)
            }
        }
        // Let the sidebar run up under the (invisible) title bar, next to the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $state.spaceEditor) { request in
            SpaceEditorSheet(request: request)
        }
        .sheet(item: $state.nameRequest) { request in
            NameSheet(request: request)
        }
        .onAppear { state.loadSelectedTab() }
    }
}

/// The selected tab's content (web page or terminal), or an empty state.
private struct ContentArea: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let tab = state.selectedTab, let controller = state.web.existingController(tab.id) {
            HostedView(view: controller.webView)
                .overlay(alignment: .top) { LoadingBar(controller: controller) }
        } else if let tab = state.selectedTab, let session = state.terminals.existingSession(tab.id) {
            HostedView(view: session.view, focusOnShow: true)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                // A new session (after a restart) gets a new view; `.id` makes SwiftUI rebuild the host.
                .id(ObjectIdentifier(session))
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                VStack(spacing: 8) {
                    Text(state.selectedSpace?.name ?? "")
                        .font(.title2.weight(.semibold))
                    Text("Press ⌘T to open a tab, or ⌥⌘T for a terminal")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A thin progress bar at the top of the page while it loads.
private struct LoadingBar: View {
    let controller: WebTabController

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * controller.estimatedProgress, height: 2)
                .opacity(controller.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: controller.estimatedProgress)
        }
        .frame(height: 2)
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
