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
        /// What the owner answers when asked.
        var allow = true
        /// The current setting, as macOS reports it. Asking sets it to the answer, as macOS does,
        /// unless `staysUndetermined` (the prompt was missed or closed without an answer).
        var status: InboxNotificationPermission = .notDetermined
        var staysUndetermined = false
        var authorisationRequests = 0
        var posted: [(id: String, title: String, body: String)] = []
        var delivered: [String] = []
        var removed: [String] = []
        var badges: [String?] = []
        var delegateSet = false

        func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { delegateSet = true }
        func authorisationStatus() async -> InboxNotificationPermission { status }
        func requestAuthorisation() async -> Bool {
            authorisationRequests += 1
            if staysUndetermined { return false }
            status = allow ? .allowed : .denied
            return allow
        }
        /// As macOS does: a posted notification is delivered (a repeat replaces it) until removed.
        func post(id: String, title: String, body: String) async {
            posted.append((id, title, body))
            if !delivered.contains(id) { delivered.append(id) }
        }
        func removeDelivered(ids: [String]) {
            removed += ids
            delivered.removeAll { ids.contains($0) }
        }
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
        // macOS does not ask again once refused: we don't either.
        #expect(backend.authorisationRequests == 1)
        #expect(backend.posted.isEmpty)
    }

    /// A refusal is not remembered: once the owner allows banners in System Settings, the next
    /// one goes out, without a relaunch.
    @Test func bannersStartOnceAllowedLater() async {
        let (notifier, backend) = make(allow: false)
        notifier.post(entry(), spaceName: "Work")
        await notifier.settle()
        #expect(backend.posted.isEmpty)
        backend.status = .allowed
        let item = entry()
        notifier.post(item, spaceName: "Work")
        await notifier.settle()
        #expect(backend.posted.map(\.id) == [item.id.uuidString])
        #expect(backend.authorisationRequests == 1)
    }

    /// The first prompt was missed (the owner was away) and the setting is still undetermined:
    /// each post asks again, once, and posts as soon as the answer is yes.
    @Test func undeterminedAsksAgainOnTheNextPost() async {
        let (notifier, backend) = make()
        backend.staysUndetermined = true
        notifier.post(entry(), spaceName: "Work")
        notifier.post(entry(), spaceName: "Work")
        await notifier.settle()
        #expect(backend.authorisationRequests == 2)
        #expect(backend.posted.isEmpty)
        backend.staysUndetermined = false
        notifier.post(entry(), spaceName: "Work")
        await notifier.settle()
        #expect(backend.authorisationRequests == 3)
        #expect(backend.posted.count == 1)
    }

    @Test func syncWithdrawsExactlyTheNotificationsWhoseEntryIsGone() async {
        let (notifier, backend) = make()
        let kept = entry(), gone1 = entry(), gone2 = entry()
        for item in [gone1, kept, gone2] { notifier.post(item, spaceName: "Work") }
        notifier.sync(with: [kept])
        await notifier.settle()
        #expect(backend.removed == [gone1.id.uuidString, gone2.id.uuidString])
        #expect(backend.delivered == [kept.id.uuidString])
        #expect(backend.badges == ["1"])
        // Withdrawn once, then forgotten: nothing is withdrawn twice.
        notifier.sync(with: [kept])
        await notifier.settle()
        #expect(backend.removed == [gone1.id.uuidString, gone2.id.uuidString])
    }

    /// Banners this process did not post (another copy of the app shares the bundle id, and so
    /// the delivered list) are left alone.
    @Test func syncLeavesOtherCopiesBannersAlone() async {
        let (notifier, backend) = make()
        let foreign = UUID().uuidString
        backend.delivered = [foreign]
        let gone = entry()
        notifier.post(gone, spaceName: "Work")
        notifier.sync(with: [])
        await notifier.settle()
        #expect(backend.removed == [gone.id.uuidString])
        #expect(backend.delivered == [foreign])
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
