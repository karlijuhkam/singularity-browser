import SwiftUI
import WebKit

/// Puts an existing WKWebView into the SwiftUI layout.
///
/// `NSViewRepresentable` is SwiftUI's bridge to AppKit views. Since the web views are owned by
/// `WebViewRegistry` (so they survive tab switches), this view does not create one. It gives
/// SwiftUI a plain container and swaps the current tab's web view into it.
struct WebContentView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        // addSubview also detaches the web view from wherever it was before.
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
