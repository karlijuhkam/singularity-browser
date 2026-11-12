import Foundation
import Testing
import UserNotifications
@testable import Singularity
import SingularityCore

extension AppTests {
/// The notifier's decisions, against a fake that stands in for macOS. The real banner, a click
/// on it and macOS's permission prompt are for the owner to check by hand.
@MainActor
@Suite(.serialized) struct InboxNotifierTests {
    @MainActor final class FakeBackend: InboxNotificationBackend {
        var allow = true
        var authorisationRequests = 0
        var posted: [(id: String, title: String, body: String)] = []
        var delivered: [String] = []
        var removed: [String] = []
        var badges: [String?] = []
        var delegateSet = false

        func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { delegateSet = true }
        func requestAuthorisation() async -> Bool { authorisationRequests += 1; return allow }
        func post(id: String, title: String, body: String) async { posted.append((id, title, body)) }
        func removeDelivered(ids: [String]) { removed += ids }
        func deliveredIDs() async -> [String] { delivered }
        func setBadge(_ label: String?) { badges.append(label) }
    }

    private func entry(_ message: String? = nil) -> InboxEntry {
        InboxEntry(kind: .done, spaceID: UUID(), tabID: UUID(), agent: "Claude Code", message: message, arrived: Date())
    }

    private func make(allow: Bool = true) -> (InboxNotifier, FakeBackend) {
        MainRunLoopGuard.start
        let backend = FakeBackend()
        backend.allow = allow
        return (InboxNotifier(onOpen: {}, backend: backend), backend)
    }

    @Test func postUsesTheEntryIDAndTheNotificationText() async {
        let (notifier, backend) = make()
        let item = entry("All green")
        notifier.post(item, spaceName: "Work")
        await notifier.settle()
        let expected = InboxNotificationText.make(item, spaceName: "Work")
        #expect(backend.posted.count == 1)
        #expect(backend.posted.first?.id == item.id.uuidString)
        #expect(backend.posted.first?.title == expected.title)
        #expect(backend.posted.first?.body == expected.body)
    }

    @Test func permissionIsAskedOnTheFirstPostOnly() async {
        let (notifier, backend) = make()
        #expect(backend.authorisationRequests == 0)   // not at init
        #expect(backend.delegateSet)
        notifier.post(entry(), spaceName: "Work")
        notifier.post(entry(), spaceName: "Work")
        await notifier.settle()
        notifier.post(entry(), spaceName: "Work")
        await notifier.settle()
        #expect(backend.authorisationRequests == 1)
        #expect(backend.posted.count == 3)
    }

    @Test func refusedPermissionPostsNothingButTheBadgeFollowsTheCount() async {
        let (notifier, backend) = make(allow: false)
        let item = entry()
        notifier.post(item, spaceName: "Work")
        notifier.sync(with: [item])
        await notifier.settle()
        #expect(backend.posted.isEmpty)
        #expect(backend.authorisationRequests == 1)
        #expect(backend.badges == ["1"])
        notifier.post(entry(), spaceName: "Work")
        await notifier.settle()
        #expect(backend.authorisationRequests == 1)   // never asks again
        #expect(backend.posted.isEmpty)
    }

    @Test func syncWithdrawsExactlyTheNotificationsWhoseEntryIsGone() async {
        let (notifier, backend) = make()
        let kept = entry()
        let gone1 = UUID().uuidString, gone2 = UUID().uuidString
        backend.delivered = [gone1, kept.id.uuidString, gone2]
        notifier.sync(with: [kept])
        await notifier.settle()
        #expect(backend.removed == [gone1, gone2])
        #expect(backend.badges == ["1"])
    }

    @Test func badgeIsTheCountAndNilAtZero() async {
        let (notifier, backend) = make()
        notifier.sync(with: [entry(), entry(), entry()])
        notifier.sync(with: [])
        await notifier.settle()
        #expect(backend.badges == ["3", nil])
        #expect(backend.removed.isEmpty)
    }

    @Test func withoutABundleIdentifierEverythingIsANoOp() async {
        MainRunLoopGuard.start
        // The way the app builds it, with the bundle id a bare binary has: none, so no backend
        // and `UNUserNotificationCenter.current()` is never reached.
        let notifier = InboxNotifier(onOpen: {}, bundleIdentifier: nil)
        let item = entry()
        notifier.post(item, spaceName: "Work")
        notifier.sync(with: [item])
        notifier.sync(with: [])
        await notifier.settle()
    }

    @Test func appStateWiresArrivalsAndChanges() async throws {
        MainRunLoopGuard.start
        // The test process is not a bundle with an identifier, so AppState's notifier has no
        // backend: the wiring runs and touches nothing.
        #expect(Bundle.main.bundleIdentifier == nil)
        let root = TestAppState.makeRoot()
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state); try? FileManager.default.removeItem(at: root) }
        #expect(state.inboxNotifier != nil)
        let item = entry()
        state.inbox.onArrival(item)
        state.inbox.onChange()
        await state.inboxNotifier?.settle()
    }
}
}
