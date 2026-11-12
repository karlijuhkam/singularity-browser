import Foundation
import SingularityCore

/// Links from other apps on their way into the app.
///
/// A link that *starts* Singularity arrives before the app state exists for the app delegate, so
/// links wait here until `deliver` is set, then each is handed over once, in order. Only web
/// links are kept; anything else macOS might send is dropped.
@MainActor
final class LinkInbox {
    private var waiting: [URL] = []

    var deliver: ((URL) -> Void)? {
        didSet { flush() }
    }

    func receive(_ urls: [URL]) {
        waiting.append(contentsOf: urls.filter(LittleWindowRules.accepts))
        flush()
    }

    private func flush() {
        guard let deliver else { return }
        let links = waiting
        waiting = []
        links.forEach(deliver)
    }
}
