import AppKit
import SwiftUI

/// Puts an existing AppKit view (a WKWebView or a terminal view) into the SwiftUI layout.
///
/// `NSViewRepresentable` is SwiftUI's bridge to AppKit views. The web views and terminal views
/// are owned by registries (so they survive tab switches), so this does not create one. It gives
/// SwiftUI a plain container and swaps the current tab's view into it.
struct HostedView: NSViewRepresentable {
    let view: NSView
    /// Give keyboard focus to the view when it is shown (terminals: so you can type immediately).
    var focusOnShow = false

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard view.superview !== container else { return }
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
