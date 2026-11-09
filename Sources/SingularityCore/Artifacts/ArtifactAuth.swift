import Foundation
import Security

/// Authentication for a Space's artifact server.
///
/// A request is allowed with either:
/// - `Authorization: Bearer <token>`: the app sends this on the first load of every artifact tab
///   (programmatic clients can use it too); or
/// - the cookie `singularity_token=<token>`: the server sets it in reply to a request that
///   carried the header. WebKit cannot add a header to the scripts, styles, images and fetch()
///   calls a page makes, so the cookie is what authorises those. It is HttpOnly (page JavaScript
///   cannot read it) and SameSite=Strict (other websites cannot make the browser send it). It
///   lives in the Space's own WebKit cookie store, so other Spaces never have it. The token is
///   never written into a file.
public enum ArtifactAuth {
    public static let cookieName = "singularity_token"

    /// A fresh random token: 32 bytes from the system's secure random generator, hex-encoded.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isAuthorized(authorization: String?, cookie: String?, token: String) -> Bool {
        if let authorization {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer", constantTimeEquals(String(parts[1]), token) {
                return true
            }
        }
        if let cookie {
            for pair in cookie.split(separator: ";") {
                let keyValue = pair.split(separator: "=", maxSplits: 1)
                guard keyValue.count == 2 else { continue }
                if keyValue[0].trimmingCharacters(in: .whitespaces) == cookieName,
                   constantTimeEquals(keyValue[1].trimmingCharacters(in: .whitespaces), token) {
                    return true
                }
            }
        }
        return false
    }

    /// Only answer requests addressed to the loopback host. This blocks "DNS rebinding", where a
    /// website points its own domain name at 127.0.0.1 to reach local servers.
    public static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }

    /// Compares without returning early, so response timing doesn't reveal how much of a guess was right.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}
