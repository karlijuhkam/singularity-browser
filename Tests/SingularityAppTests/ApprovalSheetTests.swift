import AppKit
import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The agent approval sheet, shown on a real (off-screen) window.
@MainActor
@Suite(.serialized) struct ApprovalSheetTests {
    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return view.subviews.flatMap { buttons(in: $0) } + ((view as? NSButton).map { [$0] } ?? [])
    }

    @Test func showTabBringsTheTabUpAndKeepsTheSheetOpen() async throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }

        let approvals = AgentApprovals()
        approvals.presentingWindow = { window }
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        space.agentPolicy = .ask
        var shown = 0
        var request = AgentApprovals.Request(actor: "Claude Code", action: "click", detail: "[2] button \"Buy\"",
                                             url: "https://example.com/", spaceName: "Work", tabTitle: "Shop", text: nil)
        request.showTab = { shown += 1 }

        let answer = Task { @MainActor in
            await approvals.check(AgentActionContext(kind: .click, pageOrigin: "https://example.com"), space: space, request: request)
        }
        // Wait for the sheet to come up.
        let deadline = Date().addingTimeInterval(10)
        while window.attachedSheet == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let sheet = try #require(window.attachedSheet)
        let all = buttons(in: sheet.contentView)

        let showTab = try #require(all.first { $0.title == "Show Tab" })
        showTab.performClick(nil)
        showTab.performClick(nil)
        #expect(shown == 2)
        #expect(window.attachedSheet != nil, "Show Tab must not answer the question")

        try #require(all.first { $0.title == "Deny" }).performClick(nil)
        let outcome = await answer.value
        #expect(outcome.logValue == "denied")
    }

    @Test func noShowTabButtonWithoutATab() async throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }

        let approvals = AgentApprovals()
        approvals.presentingWindow = { window }
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        space.agentPolicy = .ask
        let request = AgentApprovals.Request(actor: "Claude Code", action: "open a page", detail: "https://example.com/",
                                             url: nil, spaceName: "Work", tabTitle: nil, text: "some text")
        let answer = Task { @MainActor in
            await approvals.check(AgentActionContext(kind: .click, pageOrigin: "https://example.com"), space: space, request: request)
        }
        let deadline = Date().addingTimeInterval(10)
        while window.attachedSheet == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let sheet = try #require(window.attachedSheet)
        let all = buttons(in: sheet.contentView)
        #expect(!all.contains { $0.title == "Show Tab" })
        try #require(all.first { $0.title == "Allow" }).performClick(nil)
        #expect(await answer.value.logValue == "approved")
    }
}
}
