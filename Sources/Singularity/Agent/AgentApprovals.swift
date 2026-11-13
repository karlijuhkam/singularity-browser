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
                allowedOrigins[space.id, default: []].insert(siteOrigin)
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
        // Only the owner's answers come back from the inbox, or `.auto` for a request that the
        // rules let through now. Anything else would be a mistake: treat it as "no".
        switch outcome {
        case .denied, .timedOut:
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
