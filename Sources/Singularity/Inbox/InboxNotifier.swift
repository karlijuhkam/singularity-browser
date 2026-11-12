import AppKit
import SingularityCore
import UserNotifications

/// Whether Singularity may show banners, as System Settings says right now.
enum InboxNotificationPermission {
    /// Never asked, or the prompt was never answered.
    case notDetermined
    case allowed
    case denied
}

/// The few calls the notifier makes to macOS, so its decisions can be tested without the real
/// notification centre.
@MainActor
protocol InboxNotificationBackend: AnyObject {
    /// Gets clicks and "show while active" questions sent to `delegate`.
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate)
    /// The current setting (the owner can change it in System Settings at any time).
    func authorisationStatus() async -> InboxNotificationPermission
    /// Shows macOS's permission prompt; true when the owner allowed banners.
    func requestAuthorisation() async -> Bool
    func post(id: String, title: String, body: String) async
    func removeDelivered(ids: [String])
    /// The Dock tile's red badge; nil clears it.
    func setBadge(_ label: String?)
}

/// The real thing. Only ever made when the app runs as a bundle with an identifier:
/// `UNUserNotificationCenter.current()` traps without one.
@MainActor
private final class SystemNotificationBackend: InboxNotificationBackend {
    private let center = UNUserNotificationCenter.current()

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func authorisationStatus() async -> InboxNotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        // Provisional: delivered quietly to Notification Centre; still worth posting.
        case .authorized, .provisional: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestAuthorisation() async -> Bool {
        // Alert + badge only: no sound option, so we never ask for one.
        (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
    }

    func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No sound, no actions: answering happens in the inbox.
        // Same identifier as the entry: a repeat replaces the banner, and `removeDelivered` finds it.
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func removeDelivered(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func setBadge(_ label: String?) {
        NSApp.dockTile.badgeLabel = label
    }
}

/// A macOS notification for each new inbox entry, withdrawn when the entry goes away, and the
/// count on the Dock icon.
///
/// Calls to macOS are queued one after another (`enqueue`), so a withdrawal never overtakes the
/// notification it should withdraw. Permission is asked on a `post`, not at launch: the current
/// setting is read before every post, and macOS is asked only while it is undetermined. A "no" is
/// never remembered here, so banners start as soon as the owner allows them in System Settings.
///
/// Only banners this process posted are withdrawn: a second copy of the app (the daily copy and
/// a development copy share the bundle id) shares macOS's list of delivered notifications.
///
/// With no bundle identifier (the bare debug binary, the test process) there is no backend and
/// every method does nothing.
@MainActor
final class InboxNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let backend: (any InboxNotificationBackend)?
    private let onOpen: @MainActor () -> Void
    /// Ids of the banners this process posted (or queued) and has not withdrawn yet, oldest first.
    private var postedIDs: [String] = []
    /// The end of the queue of macOS calls.
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - backend: tests pass a fake. Otherwise the real centre is used, but only when the app
    ///     has a bundle identifier.
    init(onOpen: @escaping @MainActor () -> Void,
         backend: (any InboxNotificationBackend)? = nil,
         bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.onOpen = onOpen
        self.backend = backend ?? (bundleIdentifier == nil ? nil : SystemNotificationBackend())
        super.init()
        self.backend?.setDelegate(self)
    }

    /// `identifier` is the entry's id, so `sync` can match them up.
    func post(_ entry: InboxEntry, spaceName: String) {
        guard let backend else { return }
        let text = InboxNotificationText.make(entry, spaceName: spaceName)
        let id = entry.id.uuidString
        // Noted now, not when macOS has it: a `sync` called after this sees it, and its withdrawal
        // is queued behind the post. Withdrawing one that was never shown does no harm.
        if !postedIDs.contains(id) { postedIDs.append(id) }
        enqueue {
            let allowed: Bool
            switch await backend.authorisationStatus() {
            case .allowed: allowed = true
            case .denied: allowed = false
            case .notDetermined: allowed = await backend.requestAuthorisation()
            }
            guard allowed else { return }
            await backend.post(id: id, title: text.title, body: text.body)
        }
    }

    /// Call after every change of the list: withdraws the banners this process posted whose
    /// entry is gone (then forgets them), and sets the Dock badge to the number of entries (none
    /// at 0).
    func sync(with entries: [InboxEntry]) {
        guard let backend else { return }
        // The badge does not depend on notification permission.
        backend.setBadge(entries.isEmpty ? nil : String(entries.count))
        let live = Set(entries.map { $0.id.uuidString })
        let stale = postedIDs.filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        postedIDs.removeAll { !live.contains($0) }
        enqueue { backend.removeDelivered(ids: stale) }
    }

    /// Tests: waits until every queued call to the backend has finished.
    func settle() async {
        await tail?.value
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even while Singularity is the active app (the owner may be in another Space).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// The owner clicked a notification: bring the app forward and open the inbox.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await open()
    }

    private func open() {
        NSApp.activate()
        onOpen()
    }
}
