import Foundation
import SingularityCore
import WebKit

/// Makes Chrome Web Store's own "Add to Chrome" button add the extension to Singularity.
///
/// The store shows that button disabled in any browser but Chrome, and pretending to be Chrome
/// doesn't help (it asks Google's server, which reads headers WebKit doesn't send). So this script,
/// in a content world of our own that the page can't see, finds the disabled button that names
/// Chrome, relabels it "Add to Singularity", enables it (again after every re-render) and takes its
/// click. All it can do is tell the app "the owner clicked Add for extension <id>": the app checks
/// the sender and the id, downloads the file from Google itself and shows the approval sheet. The
/// page keeps its "Switch to Chrome" banner; the address row has a button of its own as well, for
/// when Google changes this page.
@MainActor
enum StoreButtonScript {
    static let world = WKContentWorld.world(name: "singularity-store")
    nonisolated static let handlerName = "singularityStore"

    /// The store is a single-page app: it moves from a category page to a detail page with
    /// `pushState`, so the script runs on every store page and reads the id from the address each
    /// time (when a button is relabelled and again at the click), never once at load.
    nonisolated static let source = """
    (() => {
      if (location.origin !== '\(ChromeWebStore.origin)') return;
      const currentID = () => {
        const match = location.pathname.match(/^\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})(?:\\/)?$/);
        return match ? match[1] : null;
      };
      const fix = () => {
        if (!currentID()) return;
        for (const button of document.querySelectorAll('button')) {
          if (button.dataset.singularityStore) {
            if (button.disabled) { button.disabled = false; button.removeAttribute('disabled'); }
            continue;
          }
          const label = button.querySelector('[jsname="V67aGc"]') || button;
          if (!button.disabled || !/Chrome/.test(label.textContent || '')) continue;
          button.dataset.singularityStore = '1';
          label.textContent = 'Add to Singularity';
          button.disabled = false;
          button.removeAttribute('disabled');
        }
      };
      new MutationObserver(fix).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['disabled'] });
      document.addEventListener('click', (event) => {
        const button = event.target && event.target.closest && event.target.closest('button[data-singularity-store]');
        if (!button) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        // Only the owner's own click: a page script's synthetic click does nothing.
        const id = currentID();
        if (!event.isTrusted || !id) return;
        window.webkit.messageHandlers.\(handlerName).postMessage({ id });
      }, true);
      fix();
    })();
    """

    /// Adds the script and its message handler to a Space's web view configuration. The handler
    /// is held weakly by a small proxy (a content controller keeps its handlers alive).
    static func install(in configuration: WKWebViewConfiguration, spaceID: UUID, onAdd: @escaping @MainActor (String, UUID) -> Void) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.add(Handler(spaceID: spaceID, onAdd: onAdd), contentWorld: world, name: handlerName)
    }

    /// The id to install, or nil when the message must be ignored: it must come from the store's
    /// main frame, over https, while the web view's current address (after any `pushState`) is the
    /// detail page of that same id.
    static func acceptedID(body: Any, isMainFrame: Bool, securityOrigin: WKSecurityOrigin, frameURL: URL?) -> String? {
        guard isMainFrame, securityOrigin.protocol == "https", securityOrigin.host == ChromeWebStore.host,
              securityOrigin.port == 0 || securityOrigin.port == 443,
              let dictionary = body as? [String: Any], let id = dictionary["id"] as? String,
              ChromeWebStore.isValidID(id), ChromeWebStore.extensionID(from: frameURL) == id else { return nil }
        return id
    }

    private final class Handler: NSObject, WKScriptMessageHandler {
        let spaceID: UUID
        let onAdd: @MainActor (String, UUID) -> Void
        init(spaceID: UUID, onAdd: @escaping @MainActor (String, UUID) -> Void) {
            self.spaceID = spaceID
            self.onAdd = onAdd
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let id = StoreButtonScript.acceptedID(body: message.body, isMainFrame: message.frameInfo.isMainFrame,
                                                            securityOrigin: message.frameInfo.securityOrigin,
                                                            frameURL: message.webView?.url) else { return }
                onAdd(id, spaceID)
            }
        }
    }
}
