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
    }

    /// Per Space: sites the user chose "Allow on this site" for. Only kept until the app quits.
    private var allowedOrigins: [UUID: Set<String>] = [:]
    private var isPresenting = false

    /// Seconds a sheet waits for an answer (Settings → Agents; set by AppState).
    var timeoutSeconds: () -> Int = { 120 }

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

        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            return .denied
        }
        NSApp.requestUserAttention(.informationalRequest) // bounces the Dock icon if we're in the background

        let alert = NSAlert()
        alert.messageText = "\(request.actor) wants to \(request.action)"
        var lines = [request.detail]
        if let url = request.url { lines.append(url) }
        lines.append("Space “\(request.spaceName)”" + (request.tabTitle.map { " · tab “\($0)”" } ?? ""))
        alert.informativeText = lines.joined(separator: "\n")
        if let text = request.text {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 90)
            if let textView = scrollView.documentView as? NSTextView {
                textView.string = text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
                textView.isEditable = false
                textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }
            alert.accessoryView = scrollView
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
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
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
