import CryptoKit
import Foundation

/// The Chrome Web Store facts Singularity needs: which page is an extension's detail page, what an
/// extension id looks like, and where its `.crx` file comes from.
///
/// Google's store only offers "Add to Chrome" to Chrome. We don't pretend to be Chrome (the store
/// asks Google's server, which reads headers WebKit doesn't send); instead our own script turns the
/// store's disabled button into "Add to Singularity" (`StoreButtonScript`), and the address row has
/// a button of its own. Both end here: the id, then a download from a fixed Google address.
public enum ChromeWebStore {
    /// The store's origin. Its page script and messages are accepted only from here.
    public static let origin = "https://chromewebstore.google.com"
    public static let host = "chromewebstore.google.com"

    /// The Chrome version we tell the update server. It answers with the newest build of the
    /// extension that this version can run; a recent number gets current builds.
    public static let chromeVersion = "146.0.7680.0"

    /// A Chrome extension id: 32 letters a to p (a SHA-256 prefix written with 16 letters).
    public static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    /// The extension id of a store detail page, or nil for any other address.
    /// `https://chromewebstore.google.com/detail/<name>/<id>` (the name part is optional and may be
    /// anything), also with a query or fragment. The old store's addresses are not accepted.
    public static func extensionID(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", url.host()?.lowercased() == host,
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "detail", parts.count == 2 || parts.count == 3, let id = parts.last, isValidID(id) else { return nil }
        return id
    }

    /// Where the `.crx` of an extension is downloaded from. The id is the only part that varies,
    /// and it must be valid (checked here as well as by every caller).
    public static func downloadURL(id: String) -> URL? {
        guard isValidID(id) else { return nil }
        // `x` is itself a query string ("id=<id>&installsource=ondemand&uc"), percent-encoded once.
        return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(chromeVersion)"
                   + "&acceptformat=crx2,crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc")
    }

    /// The hosts a download may be answered from (Google redirects to its content host).
    public static func isDownloadHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "clients2.google.com" || host == "clients2.googleusercontent.com"
    }

    /// The extension id Chrome derives from a developer's public key (DER, as in the CRX header and
    /// a manifest's `key`): the first 16 bytes of its SHA-256, each nibble written as a letter a…p.
    public static func extensionID(publicKey: Data) -> String {
        idFromHashPrefix(Data(SHA256.hash(data: publicKey).prefix(16)))
    }

    /// 16 bytes → 32 letters a…p (CRX3's `crx_id` is those 16 bytes).
    public static func idFromHashPrefix(_ bytes: Data) -> String {
        var out = ""
        for byte in bytes {
            out.append(Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))))
            out.append(Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 0x0f))))
        }
        return out
    }
}
