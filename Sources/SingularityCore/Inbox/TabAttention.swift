import Foundation

/// The mark a sidebar row gets while the inbox has something for its tab, so the owner can see
/// where they are needed without opening the inbox.
public enum TabAttention: Equatable, Sendable {
    /// A question, a permission, a browser approval or a waiting agent.
    case needsYou
    /// An agent in the tab reports that it is working (status records only, e.g. Claude Code).
    case working
    /// Only a "done" entry: the agent finished and the owner hasn't looked yet.
    case done

    /// needsYou > working > done, like `InboxRules.summarise` (a busy tab doesn't look done).
    var rank: Int {
        switch self {
        case .needsYou: 2
        case .working: 1
        case .done: 0
        }
    }
}

extension Inbox {
    /// Each tab with a visible entry or a working agent, and its mark (the strongest wins).
    /// Follows `visible`, so the mark leaves exactly when the entry does (going to the tab,
    /// answering, closing), and `workingTabs`, so "working" leaves with the agent's next status.
    public var tabAttention: [UUID: TabAttention] {
        var result: [UUID: TabAttention] = [:]
        func note(_ tabID: UUID, _ mark: TabAttention) {
            if (result[tabID]?.rank ?? -1) < mark.rank { result[tabID] = mark }
        }
        for tabID in workingTabs { note(tabID, .working) }
        for entry in visible {
            guard let tabID = entry.tabID else { continue }
            if case .done = entry.kind { note(tabID, .done) } else { note(tabID, .needsYou) }
        }
        return result
    }
}

extension Space {
    /// The mark a folder's header shows while it is collapsed: the strongest mark of any tab in
    /// it or in a folder inside it (those are hidden too).
    public func attention(ofFolder folderID: UUID, marks: [UUID: TabAttention]) -> TabAttention? {
        var found: TabAttention?
        for tab in tabs {
            guard let mark = marks[tab.id], let tabFolder = tab.folderID,
                  isFolder(tabFolder, inside: folderID) else { continue }
            if mark.rank > (found?.rank ?? -1) { found = mark }
        }
        return found
    }

}
