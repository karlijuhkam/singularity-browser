import Foundation
import SingularityCore

/// Decides whether an agent (or artifact page) action may happen, asking the user (through the
/// inbox) when the Space's policy says so. This runs inside the app on every action, so it holds
/// no matter which client is connected or how.
@MainActor
final class AgentApprovals {
    enum Outcome {
        case auto
        case approved
        case approvedSite
        case denied
        case timedOut
        /// The call that asked was cancelled while it waited (the agent stopped it, or its
        /// connection closed): the request was withdrawn, unanswered.
        case cancelled
        case refused(String)

        var isAllowed: Bool {
            switch self {
            case .auto, .approved, .approvedSite: return true
            case .denied, .timedOut, .cancelled, .refused: return false
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
            case .cancelled: return "cancelled"
            case .refused: return "readonly"
            }
        }

        /// What the agent is told when it may not go ahead.
        var refusal: String? {
            switch self {
            case .auto, .approved, .approvedSite: return nil
            case .denied: return "The user declined this action."
            case .timedOut: return "The user did not answer in time, so the action was not performed."
            case .cancelled: return "The request was withdrawn."
            case .refused(let reason): return reason
            }
        }
    }

    /// What the inbox entry shows. Everything in it comes from an agent or a page: the card
    /// cleans it and shows it as plain text only.
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
        /// Brings the tab the action is about on screen. Nil when there is no such tab yet, e.g.
        /// for "open a page", or for an artifact prompt.
        var showTab: (@MainActor () -> Void)? = nil
        /// The tab the action is about (the entry carries it: closing that tab denies). Set
        /// together with `showTab`; nil when there is none.
        var tabID: UUID? = nil
        /// The plugin whose own connection asked (`AgentCaller.plugin`); nil for an outside agent
        /// or an artifact page.
        var pluginID: String? = nil
        /// For a request that is not asked from the calling task itself (the navigation guard
        /// asks from WebKit's policy callback): cancelling the call cancels this, which withdraws
        /// the request and makes it ask nothing more. Nil: the asking task's own cancellation counts.
        var cancellation: ApprovalCancellation? = nil
        /// The link the card shows for `tabID`: "Show Tab" (pages), "Go to terminal" (text for a
        /// terminal) or none (an answer to a held question).
        var tabButton: ApprovalTabButton = .showTab
        /// Text for a terminal or an answer to a held question (the Assistant's terminal tools):
        /// never offers "Allow on <site>", and is denied when the plugin's Terminals switch goes
        /// off for the Space (`InboxCenter.denyTerminalApprovals`).
        var isTerminalRequest: Bool = false
        /// The held question (its inbox entry) this request answers. When that entry leaves the
        /// inbox in any way (answered on its own card, handed back to the terminal, …) the request
        /// ends `.cancelled`; asked when it is already gone, it ends `.cancelled` at once.
        var heldEntryID: UUID? = nil
    }

    /// A question waiting for the owner, handed to `presenter` (the inbox).
    struct PendingApproval {
        var request: Request
        var spaceID: UUID
        /// What "Allow on <site>" would allow; nil = don't offer it.
        var siteOrigin: String?
        var timeout: Duration
        /// True when the rules would now let it through without asking (after "Allow on site"
        /// was given for another request). Evaluated when asked, never cached.
        var passesNow: @MainActor () -> Bool
    }

    /// Per Space: sites the user chose "Allow on this site" for. Only kept until the app quits.
    private var allowedOrigins: [UUID: Set<String>] = [:]

    /// Seconds a request waits for an answer (Settings → Agents; set by AppState).
    var timeoutSeconds: () -> Int = { 120 }

    /// Shows the question to the owner and returns the answer (or `.timedOut`, `.denied`). Set by
    /// AppState to the inbox's `requestApproval`. Nil (tests without an inbox) = denied.
    var presenter: (@MainActor (PendingApproval) async -> Outcome)?

    /// The Space as it is now, for `passesNow` (the policy may change while a request waits).
    /// Set by AppState; nil = use the Space as it was when the request came. A Space that is
    /// gone (nil) never passes.
    var currentSpace: ((UUID) -> Space?)?

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
            let outcome = await ask(request, context: context, space: space, siteOrigin: siteOrigin)
            if case .approvedSite = outcome, let siteOrigin {
                // The owner's choice for the site holds, even if this call no longer acts.
                allowedOrigins[space.id, default: []].insert(siteOrigin)
            }
            // The call was stopped while the owner answered (a yes handled just before the cancel
            // took effect): it must not act on that yes.
            if outcome.isAllowed, Task.isCancelled || request.cancellation?.isCancelled == true {
                return .cancelled
            }
            return outcome
        }
    }

    /// Hands the question to the inbox and waits for the answer or the timeout.
    private func ask(_ request: Request, context: AgentActionContext, space: Space, siteOrigin: String?) async -> Outcome {
        guard let presenter else { return .denied }
        let pending = PendingApproval(
            request: request, spaceID: space.id, siteOrigin: siteOrigin, timeout: timeout,
            passesNow: { [weak self] in
                switch self?.decideNow(context, space: space) {
                case .allow: return true
                case .deny, .ask, nil: return false
                }
            })
        let outcome = await presenter(pending)
        // Only the owner's answers come back from the inbox, `.cancelled` for a call that was
        // stopped while it waited, or `.auto` for a request that the rules let through now.
        // Anything else would be a mistake: treat it as "no".
        switch outcome {
        case .denied, .timedOut, .cancelled:
            return outcome
        case .approved, .approvedSite:
            if case .approvedSite = outcome, siteOrigin == nil { return .denied }
            // The owner said yes, but the Space may have been made read-only (or deleted) while
            // the request waited: then the yes no longer counts.
            switch decideNow(context, space: space) {
            case .allow, .ask: return outcome
            case .deny, nil: return .denied
            }
        case .auto:
            return pending.passesNow() ? .auto : .denied
        case .refused:
            return .denied
        }
    }

    /// The rules' decision for `context` with the Space's policy and allowed sites as they are
    /// now. Nil when the Space is gone.
    private func decideNow(_ context: AgentActionContext, space: Space) -> AgentDecision? {
        let now: Space?
        if let currentSpace { now = currentSpace(space.id) } else { now = space }
        guard let now else { return nil }
        return AgentApprovalRules.decide(context, policy: now.agentPolicy,
                                         allowedOrigins: allowedOrigins[space.id] ?? [])
    }

    /// "claude-code" → "Claude Code".
    static func displayName(forClient client: String) -> String {
        let words = client.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? "An agent" : name
    }
}

/// Ties approval requests to a tool call that doesn't ask from its own task: during a click or
/// type, the navigation guard asks from WebKit's policy callback. When the call is cancelled,
/// `cancel()` withdraws every request still waiting under it (the inbox registers each one) and
/// every later request under it is answered `.cancelled` without asking.
@MainActor
final class ApprovalCancellation {
    private(set) var isCancelled = false
    private var withdraws: [UUID: () -> Void] = [:]

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let pending = withdraws
        withdraws = [:]
        for withdraw in pending.values { withdraw() }
    }

    /// `withdraw` runs once when the call is cancelled (at once if it already is).
    func onCancel(_ id: UUID, _ withdraw: @escaping () -> Void) {
        if isCancelled { withdraw() } else { withdraws[id] = withdraw }
    }

    /// The request was answered some other way.
    func forget(_ id: UUID) {
        withdraws[id] = nil
    }
}
