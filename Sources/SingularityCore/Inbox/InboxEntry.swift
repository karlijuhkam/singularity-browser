import Foundation

/// One question of a held Claude Code question (AskUserQuestion).
public struct InboxQuestion: Equatable, Sendable {
    public var question: String
    public var header: String?
    public var options: [String]          // labels, in order
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [String] = [], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// A browser approval (an agent wants to act on a page, or a page-side prompt).
public struct InboxApproval: Equatable, Sendable {
    public var actor: String
    public var action: String
    public var detail: String
    public var url: String?
    public var tabTitle: String?
    public var text: String?
    public var siteHost: String?          // non-nil = offer "Allow on <siteHost>"

    public init(actor: String, action: String, detail: String, url: String? = nil,
                tabTitle: String? = nil, text: String? = nil, siteHost: String? = nil) {
        self.actor = actor
        self.action = action
        self.detail = detail
        self.url = url
        self.tabTitle = tabTitle
        self.text = text
        self.siteHost = siteHost
    }
}

public enum InboxWaitingReason: String, Sendable { case question, permission, auth, error, attention }

public enum InboxKind: Equatable, Sendable {
    case question([InboxQuestion])                   // held Claude Code question
    case permission(tool: String, input: String)     // held Claude Code permission request
    case approval(InboxApproval)                     // browser approval
    case waiting(InboxWaitingReason)                 // level 1
    case done                                        // level 1
}

public struct InboxEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: InboxKind
    public var spaceID: UUID
    public var tabID: UUID?               // nil only for approvals without a tab
    public var agent: String              // "Claude Code"
    public var message: String?           // already cleaned
    public var arrived: Date
    public var deadline: Date?            // approvals only

    public init(id: UUID = UUID(), kind: InboxKind, spaceID: UUID, tabID: UUID?, agent: String,
                message: String?, arrived: Date, deadline: Date? = nil) {
        self.id = id
        self.kind = kind
        self.spaceID = spaceID
        self.tabID = tabID
        self.agent = agent
        self.message = message
        self.arrived = arrived
        self.deadline = deadline
    }

    /// Held entries keep an agent's hook call open until the user answers.
    public var isHeld: Bool {
        switch kind {
        case .question, .permission: true
        default: false
        }
    }
}
