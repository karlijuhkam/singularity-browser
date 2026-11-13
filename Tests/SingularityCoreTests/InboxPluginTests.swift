import Foundation
import Testing
@testable import SingularityCore

/// A browser approval caused by a plugin's own connection carries the plugin's id, and is answered
/// in that plugin's page (instead of opening the inbox panel) while the page is on screen.
@Suite struct InboxPluginTests {
    private func approval() -> InboxApproval {
        InboxApproval(actor: "Assistant", action: "click", detail: "[2] button \"Buy\"", url: "https://example.com/",
                      tabTitle: "Shop", siteHost: "example.com")
    }

    @Test func shownInPluginPageTruthTable() {
        // No plugin: never, whatever is on screen.
        #expect(!InboxRules.shownInPluginPage(entryPluginID: nil, pageOnScreen: { _ in true }))
        #expect(!InboxRules.shownInPluginPage(entryPluginID: nil, pageOnScreen: { _ in false }))
        // A plugin: only while that plugin's own page is on screen.
        #expect(InboxRules.shownInPluginPage(entryPluginID: "assistant", pageOnScreen: { $0 == "assistant" }))
        #expect(!InboxRules.shownInPluginPage(entryPluginID: "assistant", pageOnScreen: { _ in false }))
        #expect(!InboxRules.shownInPluginPage(entryPluginID: "assistant", pageOnScreen: { $0 == "other" }))
    }

    @Test func anApprovalKeepsItsPluginID() {
        var inbox = Inbox()
        let now = Date()
        let space = UUID()
        let fromPlugin = inbox.addApproval(approval(), spaceID: space, tabID: UUID(), deadline: now.addingTimeInterval(60),
                                           now: now, pluginID: "assistant")
        let fromAgent = inbox.addApproval(approval(), spaceID: space, tabID: nil, deadline: now.addingTimeInterval(60),
                                          now: now.addingTimeInterval(1))
        #expect(fromPlugin.pluginID == "assistant")
        #expect(fromAgent.pluginID == nil)
        #expect(inbox.entries.map(\.pluginID) == ["assistant", nil])
        #expect(inbox.visible.map(\.id) == [fromPlugin.id, fromAgent.id])
    }

    /// The app chooses the entry's id before the entry exists, so a cancelled call can name it.
    @Test func anApprovalCanBeGivenItsID() {
        var inbox = Inbox()
        let id = UUID()
        let entry = inbox.addApproval(approval(), id: id, spaceID: UUID(), tabID: nil, deadline: Date(), now: Date())
        #expect(entry.id == id)
        #expect(inbox.entries.first?.id == id)
    }
}
