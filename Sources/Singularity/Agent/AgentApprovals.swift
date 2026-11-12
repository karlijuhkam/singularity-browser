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
                guard let self else { return false }
                // The Space as it is now; one that is gone never passes.
                let now: Space?
                if let currentSpace = self.currentSpace { now = currentSpace(space.id) } else { now = space }
                guard let now else { return false }
                let decision = AgentApprovalRules.decide(context, policy: now.agentPolicy,
                                                         allowedOrigins: self.allowedOrigins[space.id] ?? [])
                switch decision {
                case .allow: return true
                case .deny, .ask: return false
                }
            })
        let outcome = await presenter(pending)
        // Only the owner's answers come back from the inbox, or `.auto` for a request that the
        // rules let through now. Anything else would be a mistake: treat it as "no".
        switch outcome {
        case .approved, .denied, .timedOut: return outcome
        case .approvedSite: return siteOrigin == nil ? .denied : outcome
        case .auto: return pending.passesNow() ? .auto : .denied
        case .refused: return .denied
        }
    }

    /// "claude-code" → "Claude Code".
    static func displayName(forClient client: String) -> String {
        let words = client.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? "An agent" : name
    }
}
