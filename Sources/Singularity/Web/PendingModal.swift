import Foundation

/// A page's `alert`/`confirm`/`prompt` or file chooser that an agent caused, held for the agent to
/// answer (`handle_dialog`, `file_upload`) instead of being answered at once or shown to the owner.
/// See `WebTabController.holdForAgent`. While it waits, the page's JavaScript is blocked.
@MainActor
final class PendingModal {
    enum Kind: Equatable {
        case alert(message: String)
        case confirm(message: String)
        case prompt(message: String, defaultText: String?)
        case fileChooser(multiple: Bool, directories: Bool)

        var isDialog: Bool {
            if case .fileChooser = self { return false }
            return true
        }
    }

    enum Answer {
        /// OK / Cancel / null, no files: also what a dialog gets when nobody answers in time.
        case dismiss
        case accept(text: String?)
        case files([URL])
    }

    let kind: Kind
    /// The origin of the frame that asked ("https://pay.example"): what the card shows, and what a
    /// plugin's per-site switch is checked against.
    let origin: URL?
    private var finish: ((Answer) -> Void)?

    init(kind: Kind, origin: URL?, finish: @escaping (Answer) -> Void) {
        self.kind = kind
        self.origin = origin
        self.finish = finish
    }

    var isAnswered: Bool { finish == nil }

    /// Answers once; later calls do nothing (WebKit's completion must run exactly once).
    func answer(_ answer: Answer) {
        guard let finish else { return }
        self.finish = nil
        finish(answer)
    }
}
