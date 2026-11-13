import Foundation

/// What Settings → General says about the default browser.
public enum DefaultBrowserStatus: Equatable, Sendable {
    /// This copy is what macOS opens web links with.
    case isDefault
    /// A Singularity is the default, but a copy at another path than the running one.
    case otherCopyIsDefault(path: String)
    /// Another browser is the default: offer "Make Default…".
    case notDefault
    /// This copy can't be the default browser; the text says why.
    case unavailable(String)

    public var text: String {
        switch self {
        case .isDefault: return "Singularity is your default browser."
        case .otherCopyIsDefault(let path): return "Another copy of Singularity is your default browser: \(path)"
        case .notDefault: return "Links from other apps open in a small window first."
        case .unavailable(let reason): return reason
        }
    }

    /// Whether the "Make Default…" button is shown.
    public var canMakeDefault: Bool { self == .notDefault }
}

/// Which copies of the app receive links from other apps, and what the Settings row shows.
///
/// Every bundle built from this repository has the same bundle id. If several claimed web links,
/// macOS could hand a link to a copy that is not the running one; that copy finds the data folder
/// in use and exits, and the link is lost. So only release bundles claim them: `release.sh` adds
/// `CFBundleURLTypes` to the bundle's Info.plist, the checked-in file has none.
public enum DefaultBrowserRules {
    /// True when this bundle's own Info.plist declares the http or https scheme.
    public static func claimsLinks(infoPlist: [String: Any]) -> Bool {
        guard let types = infoPlist["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        return types.contains { type in
            let schemes = (type["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() }
            return schemes.contains("http") || schemes.contains("https")
        }
    }

    /// - Parameters:
    ///   - bundlePath: where the running copy is.
    ///   - bundleID: the running copy's bundle id.
    ///   - defaultAppPath / defaultAppBundleID: the app macOS opens https links with now.
    public static func status(infoPlist: [String: Any], bundlePath: String, bundleID: String?,
                              defaultAppPath: String?, defaultAppBundleID: String?) -> DefaultBrowserStatus {
        let sameApp = bundleID != nil && bundleID == defaultAppBundleID
        let samePath = defaultAppPath.map { standardized($0) == standardized(bundlePath) } ?? false
        if sameApp && samePath { return .isDefault }
        // Compared by bundle id, not path: a development copy must not offer to take over while
        // the installed Singularity already is the default.
        if sameApp, let defaultAppPath { return .otherCopyIsDefault(path: defaultAppPath) }
        if AgentConnect.isTranslocated(bundlePath) {
            return .unavailable("Move Singularity to the Applications folder to make it your default browser.")
        }
        if !claimsLinks(infoPlist: infoPlist) {
            return .unavailable("This is a development build. Only the installed release can be the default browser.")
        }
        return .notDefault
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
