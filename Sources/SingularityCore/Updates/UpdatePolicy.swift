import Foundation

/// What Sparkle needs to know: where the appcast is and which key signs the updates.
public struct UpdateConfig: Equatable, Sendable {
    public let feedURL: String
    public let publicKey: String
}

/// Why this copy of the app does not update itself.
public enum UpdateUnavailable: Equatable, Sendable {
    case notAReleaseBuild, separateDataFolder, translocated

    /// One line for the menu and Settings.
    public var text: String {
        switch self {
        case .notAReleaseBuild: return "This is a development build. It doesn't update itself."
        case .separateDataFolder: return "This copy uses its own data folder, so it doesn't update itself."
        case .translocated: return "Move Singularity to the Applications folder to get updates."
        }
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case available(UpdateConfig), unavailable(UpdateUnavailable)
}

/// The rule for which copies of the app may update themselves. Pure: the caller passes in the
/// Info.plist, the environment and the bundle path.
public enum UpdatePolicy {
    public static func availability(infoPlist: [String: Any], environment: [String: String], bundlePath: String) -> UpdateAvailability {
        // A release build has both Sparkle keys in its Info.plist as non-empty strings.
        guard let feedURL = infoPlist["SUFeedURL"] as? String, !feedURL.isEmpty,
              let publicKey = infoPlist["SUPublicEDKey"] as? String, !publicKey.isEmpty else {
            return .unavailable(.notAReleaseBuild)
        }
        // A copy run from a random read-only path can't replace itself.
        if AgentConnect.isTranslocated(bundlePath) { return .unavailable(.translocated) }
        // A copy with its own data folder is a trial copy, unless it is marked as an update test bundle.
        let ownDataFolder = !(environment["SINGULARITY_HOME"] ?? "").isEmpty
        let isTestBundle = (infoPlist["SGUpdateTestBundle"] as? Bool) == true
        if ownDataFolder && !isTestBundle { return .unavailable(.separateDataFolder) }
        return .available(UpdateConfig(feedURL: feedURL, publicKey: publicKey))
    }
}
