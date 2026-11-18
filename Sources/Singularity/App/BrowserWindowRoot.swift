import AppKit
import SingularityCore
import SwiftUI

extension EnvironmentValues {
    /// The browser window a view is in (its `BrowserWindowState` id). nil outside a window scene
    /// (tests host `MainView` on their own): such a view counts as the front window.
    @Entry var browserWindowID: UUID?
}

/// One browser window's scene (`WindowGroup(id: "browser", for: UUID.self)`). SwiftUI hands each
/// window a value; the window shows the record with that id (`AppState.claimWindow`).
///
/// At launch SwiftUI opens one window with no value (or, on some systems, windows it restored by
/// itself). The first window to appear takes a record and opens one window for every other record
/// in `state.json`. A window whose value no free record has closes again: making a record for it
/// would add one more window at every launch.
struct BrowserWindowRoot: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Binding var requested: UUID?
    @State private var windowID: UUID?
    @State private var rejected = false

    var body: some View {
        Group {
            if let windowID {
                MainView()
                    .environment(\.browserWindowID, windowID)
            } else {
                Color.clear
            }
        }
        .background(BrowserWindowReader { window in
            if rejected { DispatchQueue.main.async { window.close() } }
        })
        .onAppear(perform: claim)
    }

    private func claim() {
        guard windowID == nil, !rejected else { return }
        WindowActivationMonitor.install(state)
        // Every window opens records by value from now on, also after the first one is closed.
        state.openBrowserWindow = { [openWindow] id in openWindow(id: "browser", value: id) }
        guard let id = state.claimWindow(requested) else {
            rejected = true
            return
        }
        windowID = id
        if requested != id { requested = id }
        for other in state.unclaimedWindowIDs() {
            openWindow(id: "browser", value: other)
        }
    }
}

/// Finds the NSWindow this SwiftUI view is shown in. SwiftUI has no API for that, so an invisible
/// AppKit view reports its `window` once it has been put into one (and on every update after).
struct BrowserWindowReader: NSViewRepresentable {
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

/// Ties one NSWindow to its record: key → front window, close → record gone, moves and resizes →
/// its frame. Made once per window (`WindowLink.attach`), kept alive by the window's delegate-free
/// observers' owner below.
@MainActor
final class WindowLink {
    private static var links: [ObjectIdentifier: WindowLink] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Links `window` to record `id` once; later calls for the same window do nothing.
    static func attach(_ window: NSWindow, id: UUID, state: AppState) {
        let key = ObjectIdentifier(window)
        guard links[key] == nil else { return }
        let link = WindowLink()
        links[key] = link
        state.registerWindow(window, for: id)
        // Our own state.json restores windows; AppKit's restoration would add windows of its own.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        if let frame = state.windows.first(where: { $0.id == id })?.frame {
            let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            // A frame on a screen that is gone (an unplugged display) is dropped: macOS places it.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                window.setFrame(rect, display: false)
            }
        }
        let center = NotificationCenter.default
        link.observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak state] _ in
                MainActor.assumeIsolated { state?.activateWindow(id) }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak state, weak window] _ in
                MainActor.assumeIsolated {
                    if let window { state?.windowFrameChanged(id, frame: window.frame) }
                }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak state, weak window] _ in
                MainActor.assumeIsolated {
                    if let window { state?.windowFrameChanged(id, frame: window.frame) }
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak state] _ in
                MainActor.assumeIsolated {
                    state?.windowClosed(id)
                    if let link = links.removeValue(forKey: key) {
                        link.observers.forEach(center.removeObserver)
                    }
                }
            },
        ]
        if window.isKeyWindow { state.activateWindow(id) }
    }
}

/// A click in a browser window that isn't the front one makes it the front one *before* anything
/// else sees the click (the pane's focus monitor, a sidebar button), so the click acts in the window
/// it landed in and never pulls a tab into the window that was in front. AppKit makes the window
/// key only after local event monitors ran, too late for them.
@MainActor
enum WindowActivationMonitor {
    private static var monitor: Any?

    static func install(_ state: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak state] event in
            guard let state, let window = event.window,
                  let id = state.nsWindows.first(where: { $0.value.window === window })?.key,
                  id != state.frontWindowID else { return event }
            state.activateWindow(id)
            return event
        }
    }
}
