import Foundation

/// How much agents may do in a Space without asking. Checked inside the app on every tool call,
/// whatever client is connected.
public enum AgentPolicy: String, Codable, CaseIterable, Sendable {
    /// Agents may look (list, read, find, screenshot) but never act.
    case readOnly
    /// Agents may look; acting asks the user first (default).
    case ask
    /// Agents may do everything without asking (still logged).
    case allowAll

    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .ask: return "Ask before acting"
        case .allowAll: return "Allow everything"
        }
    }
}

/// What an agent (or an artifact page) is trying to do.
public enum AgentActionKind: String, Sendable {
    case listTabs, readPage, find, screenshot
    case open, navigate, close, click, type
    /// `window.singularity.prompt(text)` from an artifact page: typing into a terminal.
    case artifactPrompt
    /// Text pasted into a terminal, or an answer to a held question (the Assistant's terminal tools).
    case terminalSend

    public var isRead: Bool {
        switch self {
        case .listTabs, .readPage, .find, .screenshot: return true
        default: return false
        }
    }
}

/// The facts the rules need about one action.
public struct AgentActionContext: Sendable, Equatable {
    public var kind: AgentActionKind
    /// Origin of the page being acted on ("https://shop.example.com"); nil if there is none.
    public var pageOrigin: String?
    /// Origin being navigated to (open, navigate, or a link a click will follow).
    public var targetOrigin: String?
    /// The action submits a form (type with submit, or clicking a form's submit button).
    public var isFormSubmission: Bool

    public init(kind: AgentActionKind, pageOrigin: String? = nil, targetOrigin: String? = nil, isFormSubmission: Bool = false) {
        self.kind = kind
        self.pageOrigin = pageOrigin
        self.targetOrigin = targetOrigin
        self.isFormSubmission = isFormSubmission
    }
}

public enum AgentDecision: Equatable, Sendable {
    case allow
    case deny(String)
    /// Ask the user. `siteOrigin` is what "Allow on this site" would allow; nil when that option
    /// must not be offered (form submissions, artifact prompts).
    case ask(siteOrigin: String?)
}

public enum AgentApprovalRules {
    public static let readOnlyReason = "This Space is read-only for agents. The user can change that in the Space's settings."

    /// "https://example.com" or "http://127.0.0.1:54321": scheme, host and a non-default port.
    public static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// The approval table from the brief. `allowedOrigins` are the sites the user chose
    /// "Allow on this site" for, in this Space, since the app started.
    public static func decide(_ context: AgentActionContext, policy: AgentPolicy, allowedOrigins: Set<String>) -> AgentDecision {
        if context.kind.isRead { return .allow }
        // Typing into a terminal always asks the owner (never remembered per site), unless read-only.
        if context.kind == .terminalSend {
            return policy == .readOnly ? .deny(readOnlyReason) : .ask(siteOrigin: nil)
        }
        switch policy {
        case .allowAll:
            return .allow
        case .readOnly:
            return .deny(readOnlyReason)
        case .ask:
            // Never covered by "Allow on this site": the brief wants these to always ask.
            if context.kind == .artifactPrompt || context.isFormSubmission {
                return .ask(siteOrigin: nil)
            }
            // Going somewhere: allowed only if that site was allowed.
            if let target = context.targetOrigin, target != context.pageOrigin || context.kind == .open || context.kind == .navigate {
                return allowedOrigins.contains(target) ? .allow : .ask(siteOrigin: target)
            }
            // Acting on the current page.
            if let page = context.pageOrigin {
                return allowedOrigins.contains(page) ? .allow : .ask(siteOrigin: page)
            }
            return .ask(siteOrigin: nil)
        }
    }
}
