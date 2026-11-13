import AppKit
import Observation
import SingularityCore

/// What the "Default browser" row needs from macOS. A protocol so tests pass a fake: the real
/// "make default" changes the owner's Mac and must never run in a test or a trial copy.
@MainActor
protocol DefaultBrowserSystem {
    /// The app macOS opens https links with now: where it is, and its bundle id.
    func currentDefault() -> (path: String, bundleID: String?)?
    /// Asks macOS to make the app at `bundleURL` the default browser. macOS shows its own
    /// confirmation; `done` is called once the user has answered (with an error if they said no).
    func makeDefault(bundleURL: URL, done: @escaping @MainActor (Error?) -> Void)
}

struct MacDefaultBrowserSystem: DefaultBrowserSystem {
    func currentDefault() -> (path: String, bundleID: String?)? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return (app.path, Bundle(url: app)?.bundleIdentifier)
    }

    func makeDefault(bundleURL: URL, done: @escaping @MainActor (Error?) -> Void) {
        // http and https go together: macOS treats the pair as "the default web browser" and asks
        // the user once ("Do you want to change your default web browser…?").
        NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in done(error) }
        }
    }
}

/// The state behind Settings → General → Default browser. The rules are in Core (`DefaultBrowserRules`).
@MainActor
@Observable
final class DefaultBrowser {
    private(set) var status: DefaultBrowserStatus
    @ObservationIgnored private let system: DefaultBrowserSystem
    @ObservationIgnored private let infoPlist: [String: Any]
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let bundleID: String?

    init(system: DefaultBrowserSystem = MacDefaultBrowserSystem(),
         infoPlist: [String: Any] = Bundle.main.infoDictionary ?? [:],
         bundleURL: URL = Bundle.main.bundleURL,
         bundleID: String? = Bundle.main.bundleIdentifier) {
        self.system = system
        self.infoPlist = infoPlist
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.status = .notDefault
        refresh()
    }

    /// Reads the state again. The user answers a system dialog, or changes the default in System
    /// Settings, so the row asks whenever it appears and whenever the app becomes active.
    func refresh() {
        let current = system.currentDefault()
        status = DefaultBrowserRules.status(infoPlist: infoPlist, bundlePath: bundleURL.path, bundleID: bundleID,
                                            defaultAppPath: current?.path, defaultAppBundleID: current?.bundleID)
    }

    func makeDefault() {
        guard status.canMakeDefault else { return }
        system.makeDefault(bundleURL: bundleURL) { [weak self] _ in self?.refresh() }
    }
}
