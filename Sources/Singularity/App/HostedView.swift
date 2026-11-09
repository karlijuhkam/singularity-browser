import AppKit
import SwiftUI

/// Puts an existing AppKit view (a WKWebView or a terminal view) into the SwiftUI layout.
///
/// `NSViewRepresentable` is SwiftUI's bridge to AppKit views. The web views and terminal views
/// are owned by registries (so they survive tab switches and split changes), so this does not
/// create one. It gives SwiftUI a `PaneContainerView` and moves the tab's view into it.
struct HostedView: NSViewRepresentable {
    let view: NSView
    /// The tab shown here; used for drag-and-drop and click-to-focus.
    var tabID: UUID?
    /// Give keyboard focus to the view when it is put on screen (terminals: type immediately).
    var focusOnShow = false
    /// Called when a tab from the sidebar is dropped on this view.
    var onDrop: ((UUID, PaneDropZone) -> Void)?

    /// Which container currently holds each hosted view (weak on both sides).
    @MainActor private static let owners = NSMapTable<NSView, PaneContainerView>.weakToWeakObjects()

    func makeNSView(context: Context) -> PaneContainerView {
        PaneContainerView()
    }

    static func dismantleNSView(_ container: PaneContainerView, coordinator: ()) {
        // A pane going away gives up its claim, so any remaining pane may show the view again.
        for view in container.subviews where owners.object(forKey: view) === container {
            owners.removeObject(forKey: view)
        }
    }

    func updateNSView(_ container: PaneContainerView, context: Context) {
        container.tabID = tabID
        container.onDrop = onDrop
        guard view.superview !== container else { return }
        // When a split changes, SwiftUI can briefly keep the outgoing pane alive next to the new
        // one, and update both. Only the newest container may take the view; otherwise the
        // outgoing pane would pull it back and take it off screen when it goes away.
        if let owner = Self.owners.object(forKey: view), owner !== container, owner.serial > container.serial {
            return
        }
        Self.owners.setObject(container, forKey: view)
        container.subviews.forEach { $0.removeFromSuperview() }
        // addSubview also detaches the view from wherever it was before.
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        if focusOnShow {
            // Wait one run-loop turn: the container is only in the window after this update.
            DispatchQueue.main.async { [view] in
                view.window?.makeFirstResponder(view)
            }
        }
    }
}
