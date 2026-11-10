import AppKit
import SingularityCore

/// Decides whether an agent (or artifact page) action may happen, asking the user when the
/// Space's policy says so. This runs inside the app on every action, so it holds no matter which
/// client is connected or how.
@MainActor
final class AgentApprovals {
    enum Outcome {
        case auto
        case approved
        case approvedSite
        case denied
        case timedOut
        case refused(String)

        var isAllowed: Bool {
            switch self {
            case .auto, .approved, .approvedSite: return true
            case .denied, .timedOut, .refused: return false
            }
        }

        /// The `decision` value written to the agent log.
        var logValue: String {
            switch self {
            case .auto: return "auto"
            case .approved: return "approved"
            case .approvedSite: return "approved_site"
            case .denied: return "denied"
            case .timedOut: return "timeout"
            case .refused: return "readonly"
            }
        }

        /// What the agent is told when it may not go ahead.
        var refusal: String? {
            switch self {
            case .auto, .approved, .approvedSite: return nil
            case .denied: return "The user declined this action."
            case .timedOut: return "The user did not answer in time, so the action was not performed."
            case .refused(let reason): return reason
            }
        }
    }

    /// What the confirmation sheet shows.
    struct Request {
        /// "Claude Code", "An artifact page".
        var actor: String
        /// Verb phrase: "click", "open a page", "type into a field".
        var action: String
        /// The element or URL, e.g. `[12] button "Add to cart"`.
        var detail: String
        var url: String?
        var spaceName: String
        var tabTitle: String?
        /// Text being typed or sent (already masked for password fields).
        var text: String?
        /// Brings the tab the action is about on screen (behind the sheet). Nil when there is
        /// no such tab yet, e.g. for "open a page".
        var showTab: (@MainActor () -> Void)? = nil
    }

    /// Target of the sheet's "Show Tab" button, and the sheet's deadline. AppKit buttons call an
    /// Objective-C selector on a target object, so the closure needs this small wrapper.
    private final class SheetControls: NSObject {
        var deadline: ContinuousClock.Instant
        let timeout: Duration
        let showTab: (@MainActor () -> Void)?

        init(timeout: Duration, showTab: (@MainActor () -> Void)?) {
            self.timeout = timeout
            self.deadline = .now + timeout
            self.showTab = showTab
        }

        @MainActor @objc func showTabClicked(_ sender: Any?) {
            showTab?()
            // The user is looking at the page now: give them the full time again.
            deadline = .now + timeout
        }
    }

    /// Per Space: sites the user chose "Allow on this site" for. Only kept until the app quits.
    private var allowedOrigins: [UUID: Set<String>] = [:]
    private var isPresenting = false

    /// Seconds a sheet waits for an answer (Settings → Agents; set by AppState).
    var timeoutSeconds: () -> Int = { 120 }

    /// The window the sheet attaches to (tests put their own here).
    var presentingWindow: () -> NSWindow? = {
        NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
    }

    private var timeout: Duration {
        .seconds(max(5, timeoutSeconds()))
    }

    func check(_ context: AgentActionContext, space: Space, request: Request) async -> Outcome {
        let decision = AgentApprovalRules.decide(context, policy: space.agentPolicy,
                                                 allowedOrigins: allowedOrigins[space.id] ?? [])
        switch decision {
        case .allow:
            return .auto
        case .deny(let reason):
            return .refused(reason)
        case .ask(let siteOrigin):
            let outcome = await ask(request, siteOrigin: siteOrigin)
            if case .approvedSite = outcome, let siteOrigin {
                allowedOrigins[space.id, default: []].insert(siteOrigin)
            }
            return outcome
        }
    }

    /// Shows the sheet (one at a time) and waits for the answer or the timeout.
    private func ask(_ request: Request, siteOrigin: String?) async -> Outcome {
        while isPresenting {
            try? await Task.sleep(for: .milliseconds(100))
        }
        isPresenting = true
        defer { isPresenting = false }

        guard let window = presentingWindow() else { return .denied }
        NSApp.requestUserAttention(.informationalRequest) // bounces the Dock icon if we're in the background

        let alert = NSAlert()
        alert.messageText = "\(request.actor) wants to \(request.action)"
        var lines = [request.detail]
        if let url = request.url { lines.append(url) }
        lines.append("Space “\(request.spaceName)”" + (request.tabTitle.map { " · tab “\($0)”" } ?? ""))
        alert.informativeText = lines.joined(separator: "\n")
        // Below the message: the text being sent (if any) and a "Show Tab" button. The button
        // sits here, not among the alert's own buttons, because those always close the sheet.
        let controls = SheetControls(timeout: timeout, showTab: request.showTab)
        var accessories: [NSView] = []
        if let text = request.text {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.widthAnchor.constraint(equalToConstant: 420).isActive = true
            scrollView.heightAnchor.constraint(equalToConstant: 90).isActive = true
            if let textView = scrollView.documentView as? NSTextView {
                textView.string = text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
                textView.isEditable = false
                textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }
            accessories.append(scrollView)
        }
        if request.showTab != nil {
            let button = NSButton(title: "Show Tab", target: controls, action: #selector(SheetControls.showTabClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            accessories.append(button)
        }
        if !accessories.isEmpty {
            let stack = NSStackView(views: accessories)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            // NSAlert sizes the accessory from its frame, so give the stack its fitted size.
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            alert.accessoryView = stack
        }

        alert.addButton(withTitle: "Allow")
        var siteButton: NSApplication.ModalResponse?
        if let siteOrigin {
            let host = URL(string: siteOrigin)?.host() ?? siteOrigin
            alert.addButton(withTitle: "Allow on \(host)")
            siteButton = .alertSecondButtonReturn
        }
        let deny = alert.addButton(withTitle: "Deny")
        deny.keyEquivalent = "\u{1b}" // Esc

        // Close the sheet after the timeout; an unanswered request is treated as "no".
        // ("Show Tab" moves the deadline, hence the loop.)
        let timer = Task {
            while !Task.isCancelled, ContinuousClock.now < controls.deadline {
                try? await Task.sleep(until: controls.deadline, clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
        let response = await alert.beginSheetModal(for: window)
        timer.cancel()

        if response == .abort { return .timedOut }
        if response == .alertFirstButtonReturn { return .approved }
        if let siteButton, response == siteButton { return .approvedSite }
        return .denied
    }

    /// "claude-code" → "Claude Code".
    static func displayName(forClient client: String) -> String {
        let words = client.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? "An agent" : name
    }
}
