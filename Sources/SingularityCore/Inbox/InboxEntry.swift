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

/// The link at the right of an approval card, for a request about a tab. Both buttons do the same
/// (show the tab, answer nothing, restart the clock); only the name differs.
public enum ApprovalTabButton: Equatable, Sendable {
    /// "Show Tab": a page an agent acts on.
    case showTab
    /// "Go to terminal": text the Assistant wants to send to a terminal.
    case goToTerminal
    /// No link: an answer to a held question, which going to the terminal would hand back there.
    case none
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
    /// The link the card shows when the entry has a tab.
    public var tabButton: ApprovalTabButton
    /// A line the card shows on its own under the detail, never cut by the detail's line limit
    /// ("This terminal is showing a prompt; the text goes into it."). Nil: none.
    public var note: String?

    public init(actor: String, action: String, detail: String, url: String? = nil,
                tabTitle: String? = nil, text: String? = nil, siteHost: String? = nil,
                tabButton: ApprovalTabButton = .showTab, note: String? = nil) {
        self.actor = actor
        self.action = action
        self.detail = detail
        self.url = url
        self.tabTitle = tabTitle
        self.text = text
        self.siteHost = siteHost
        self.tabButton = tabButton
        self.note = note
    }
}

public enum InboxWaitingReason: String, Sendable { case question, permission, auth, error, attention }

public enum InboxKind: Equatable, Sendable {
    case question([InboxQuestion])                   // held Claude Code question
    /// Held Claude Code permission request. `isComplete` false: `input` had to be cut, so the
    /// owner cannot see everything Allow would approve; the card then offers only Deny and
    /// Go to terminal, and `InboxCenter` refuses an Allow.
    case permission(tool: String, input: String, isComplete: Bool)
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
    /// The plugin whose program asked (a browser approval from a plugin); nil for everything else.
    public var pluginID: String?

    public init(id: UUID = UUID(), kind: InboxKind, spaceID: UUID, tabID: UUID?, agent: String,
                message: String?, arrived: Date, deadline: Date? = nil, pluginID: String? = nil) {
        self.id = id
        self.kind = kind
        self.spaceID = spaceID
        self.tabID = tabID
        self.agent = agent
        self.message = message
        self.arrived = arrived
        self.deadline = deadline
        self.pluginID = pluginID
    }

    /// Held entries keep an agent's hook call open until the user answers.
    public var isHeld: Bool {
        switch kind {
        case .question, .permission: true
        default: false
        }
    }
}
