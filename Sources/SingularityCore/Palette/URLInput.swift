import Foundation

/// Decides whether text typed into the palette is a URL to open or a phrase to search for.
public enum URLInput: Equatable, Sendable {
    case url(URL)
    case search(URL)

    /// v1 hard-codes the search engine. See IDEAS.md.
    public static let searchURLPrefix = "https://duckduckgo.com/?q="

    public var url: URL {
        switch self {
        case .url(let url), .search(let url): return url
        }
    }

    /// Returns nil for empty input.
    public static func classify(_ input: String) -> URLInput? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. Has an explicit scheme we can open: "https://…", "http://…", "about:blank".
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), url.host() != nil { return .url(url) }
            if scheme == "about" { return .url(url) }
        }

        // 2. Looks like a host with no spaces: "example.com", "localhost:3000", "192.168.1.1/admin".
        if !text.contains(where: \.isWhitespace), looksLikeHost(text) {
            let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasPrefix("[::1]")
            if let url = URL(string: (isLocal ? "http://" : "https://") + text), url.host() != nil {
                return .url(url)
            }
        }

        // 3. Everything else is a search.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let query = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        return .search(URL(string: searchURLPrefix + query)!)
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        // Take the part before any path, query or fragment, and drop a port.
        let hostAndPort = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? text
        let host = hostAndPort.split(separator: ":").first.map(String.init) ?? hostAndPort
        if host == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard labels.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return false }
        // The last label must be a TLD-ish word ("com", "dev") or the host is an IPv4 address.
        let last = labels.last!
        let isIPv4 = labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
        return isIPv4 || (last.count >= 2 && last.allSatisfy(\.isLetter))
    }
}
