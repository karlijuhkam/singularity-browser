import Foundation
import Observation
import Sparkle
import SingularityCore

/// The app's updater: the one place that talks to Sparkle.
///
/// Sparkle runs only in a copy that may update itself (`UpdatePolicy`: a release build, not a trial
/// copy with its own data folder, not translocated). Any other copy has no updater at all, so it
/// never reaches the network for updates; "Check for Updates…" then does nothing.
///
/// Sparkle reads the feed URL and the public key from the bundle's Info.plist by itself
/// (`SUFeedURL`, `SUPublicEDKey`, stamped by release.sh); nothing is passed in code. Sparkle keeps
/// its own copy of the "check automatically" choice in the app's user defaults; ours lives in
/// settings.json and is handed to Sparkle at launch and whenever it changes.
@MainActor
@Observable
final class AppUpdates {
    let availability: UpdateAvailability

    /// Sparkle's ready-made controller: it owns the updater and shows Sparkle's standard windows
    /// (update found, download progress, "you're up to date"). nil when this copy doesn't update.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Keeps the key-value observation of `canCheckForUpdates` alive (it stops when released).
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// Whether the user can start a check now: false when this copy doesn't update, or while Sparkle
    /// is busy (e.g. a background check is downloading the feed). The menu item reads this, so it is
    /// a stored, observed property, kept in step with Sparkle's through KVO.
    private(set) var canCheck = false

    var hasUpdater: Bool { controller != nil }

    init(availability: UpdateAvailability, checksAutomatically: Bool) {
        self.availability = availability
        guard case .available = availability else {
            controller = nil
            return
        }
        // Not started yet, so the automatic-check choice is set before Sparkle's first schedule.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = checksAutomatically

        // KVO: Sparkle changes `canCheckForUpdates` on the main thread as checks start and end.
        // The handler is not main-actor code as far as Swift knows, so the value hops over in a Task.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }

        controller.startUpdater()
        canCheck = updater.canCheckForUpdates
        // Sparkle's documented way to check at every launch: once, right after starting, and only
        // when automatic checks are on. Calling it later would confuse Sparkle's own schedule.
        if checksAutomatically {
            updater.checkForUpdatesInBackground()
        }
    }

    /// "Check for Updates…": Sparkle checks and shows what it found (or that you're up to date).
    func checkNow() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /// The Settings switch. Sparkle reschedules its checks by itself shortly after this changes.
    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    /// The rule applied to this running copy.
    static func currentAvailability() -> UpdateAvailability {
        UpdatePolicy.availability(infoPlist: Bundle.main.infoDictionary ?? [:],
                                  environment: ProcessInfo.processInfo.environment,
                                  bundlePath: Bundle.main.bundlePath)
    }
}
