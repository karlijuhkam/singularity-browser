import AppKit
import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The address row's copy button and "Copy Link" (⇧⌘C): the selected web tab's full address
/// goes to the pasteboard. Always a private named pasteboard, never the user's.
@MainActor
@Suite(.serialized) struct AddressCopyTests {
    private func makeState(tabs: [BrowserTab]) throws -> (AppState, URL) {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~")
        for tab in tabs { space.append(tab) }
        space.selectedTabID = tabs.last?.id
        try SpaceStore(paths: Paths(root: root)).save(space)
        return (TestAppState.make(root: root), root)
    }

    private func finish(_ state: AppState, _ root: URL) {
        TestAppState.shutDown(state)
        try? FileManager.default.removeItem(at: root)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.roosa.singularity.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        return pasteboard
    }

    /// The whole address is copied (path and query too), not the host the row shows.
    @Test func copiesTheSelectedWebTabsFullAddress() throws {
        let address = "https://www.example.com/a/b?q=1#part"
        let (state, root) = try makeState(tabs: [.web(URL(string: address)!)])
        defer { finish(state, root) }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        #expect(state.selectedAddress == address)
        #expect(state.copySelectedAddress(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == address)
    }

    /// No web tab selected: nothing is copied and the pasteboard keeps what it had.
    @Test func withoutAWebTabNothingIsCopied() throws {
        let (state, root) = try makeState(tabs: [])
        defer { finish(state, root) }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        #expect(state.selectedAddress == nil)
        #expect(!state.copySelectedAddress(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "old")
    }
}
}
