import Foundation

/// Errors from the plugin system. Later tasks add more cases.
public enum PluginError: Error, Equatable, Sendable {
    case invalidSitePattern(String)
    // Manifest loading (PluginManifest.load)
    case invalidJSON(String)
    case invalidID(String)
    case idDoesNotMatchFolder(id: String, folder: String)
    case missingFile(String)
    case unknownPermission(String)
    case refusedCommand(String)
    case networkNotAvailable
    /// A name in `programs` that is invalid, refused, repeated, or beyond the fourth.
    case refusedProgram(String)
    case programsNeedBackground
    /// A name in `programEnv` that plugins may not set (or one with no program to receive it).
    case invalidProgramEnv(String)
    case invalidPanelTitle
    case missingLockfile
    case pageSiteNotPermitted(String)
    /// A symlink inside a plugin folder (it could point outside the plugin); the path is relative.
    case symlinkNotAllowed(String)
    /// A FIFO, socket or device inside a plugin folder; the path is relative.
    case unsupportedFile(String)
    /// A regular file with more than one hard link (st_nlink > 1): its content could be changed
    /// through another name, perhaps from outside the folder, without the folder looking edited.
    case hardLinkNotAllowed(String)
    /// The plugin's files couldn't be read (permissions, a file vanished mid-read, …); the text
    /// is the underlying error.
    case unreadable(String)
    /// A package Singularity won't install: not an exact version from the npm registry (a range,
    /// tag, `file:`, `git…`, URL, `npm:` alias…), a dependency group other than `dependencies`,
    /// or a `bun.lock` entry that isn't a registry package or doesn't match package.json. The
    /// text is the package name (or the package.json key / bun.lock entry at fault).
    case unsupportedPackage(String)
    /// A file plugins may not contain (e.g. `.npmrc`, which would configure the package install).
    case forbiddenFile(String)
}

/// Host comparison helpers shared by site patterns and the 1Password fill guard.
public enum HostMatch {
    /// Lowercases and drops a single trailing dot ("GitHub.com." -> "github.com").
    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// False for an empty host or one with an empty label (".a.com", "a..com").
    static func hasOnlyNonEmptyLabels(_ host: String) -> Bool {
        !host.isEmpty && !host.split(separator: ".", omittingEmptySubsequences: false).contains { $0.isEmpty }
    }

    /// True when `host` is `savedHost` itself or a subdomain of it.
    /// "www.github.com" of "github.com" is true; the reverse and "evilgithub.com" are false.
    public static func isSameOrSubdomain(_ host: String, of savedHost: String) -> Bool {
        let h = normalize(host)
        let saved = normalize(savedHost)
        if !hasOnlyNonEmptyLabels(h) || !hasOnlyNonEmptyLabels(saved) { return false }
        return h == saved || h.hasSuffix("." + saved)
    }
}

/// A Chrome-style match pattern (subset): `<all_urls>` or `scheme://host/path`.
/// Scheme is `*` (http or https), `http` or `https`; host is `*`, `*.domain` or an exact name;
/// the path starts with `/` and `*` matches any run of characters. Ports are ignored.
public struct SitePattern: Hashable, Sendable {
    private enum Host: Hashable, Sendable {
        case any
        case domainAndSubdomains(String)
        case exact(String)
    }

    public let text: String
    private let scheme: String   // "*", "http" or "https"
    private let host: Host
    private let path: String     // includes the leading "/"

    public init(_ text: String) throws(PluginError) {
        self.text = text
        if text == "<all_urls>" {
            scheme = "*"
            host = .any
            path = "/*"
            return
        }

        guard let sep = text.range(of: "://") else { throw .invalidSitePattern(text) }
        let scheme = String(text[..<sep.lowerBound]).lowercased()
        guard ["*", "http", "https"].contains(scheme) else { throw .invalidSitePattern(text) }

        let rest = text[sep.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { throw .invalidSitePattern(text) }
        let rawHost = String(rest[..<slash])
        let path = String(rest[slash...])

        let forbidden: Set<Character> = [":", "@", "?", "#"]
        if rawHost.isEmpty || rawHost.contains(where: { forbidden.contains($0) || $0.isWhitespace }) { throw .invalidSitePattern(text) }
        let parsedHost: Host
        if rawHost == "*" {
            parsedHost = .any
        } else if rawHost.hasPrefix("*.") {
            let domain = HostMatch.normalize(String(rawHost.dropFirst(2)))
            if !HostMatch.hasOnlyNonEmptyLabels(domain) || domain.contains("*") { throw .invalidSitePattern(text) }
            parsedHost = .domainAndSubdomains(domain)
        } else {
            if rawHost.contains("*") { throw .invalidSitePattern(text) }
            let name = HostMatch.normalize(rawHost)
            if !HostMatch.hasOnlyNonEmptyLabels(name) { throw .invalidSitePattern(text) }
            parsedHost = .exact(name)
        }

        self.scheme = scheme
        self.host = parsedHost
        self.path = path
    }

    public func matches(_ url: URL) -> Bool {
        // Both "*" and <all_urls> mean http or https only.
        guard let urlScheme = url.scheme?.lowercased(), urlScheme == "http" || urlScheme == "https" else { return false }
        if scheme != "*" && scheme != urlScheme { return false }
        guard let urlHost = url.host(percentEncoded: true), !urlHost.isEmpty else { return false }

        switch host {
        case .any: break
        case .exact(let name):
            if HostMatch.normalize(urlHost) != name { return false }
        case .domainAndSubdomains(let domain):
            if !HostMatch.isSameOrSubdomain(urlHost, of: domain) { return false }
        }

        // Path plus "?query" when present; an empty path counts as "/".
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        return Self.globMatch(pattern: path, target)
    }

    /// Anchored wildcard match where `*` matches any run of characters (including none and "/").
    private static func globMatch(pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0
        var starIndex = -1, resumeText = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                starIndex = pi
                resumeText = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if starIndex >= 0 {
                // Let the last "*" swallow one more character and retry.
                resumeText += 1
                ti = resumeText
                pi = starIndex + 1
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: - The same pattern, for JavaScript

extension SitePattern {
    /// A pattern as data the plugin prelude (JavaScript, in the page) can match with, so the
    /// parsing stays here in Swift. The app re-checks every message natively with `matches`;
    /// this copy only decides whether the plugin's page code starts at all.
    public struct BrowserMatcher: Codable, Equatable, Sendable {
        /// "http" and/or "https".
        public let schemes: [String]
        /// "any", "domainAndSubdomains" or "exact".
        public let hostKind: String
        /// Lowercased, no trailing dot; empty for "any".
        public let host: String
        /// A regular expression for `location.pathname + location.search`, anchored with ^ and $.
        public let pathRegex: String
    }

    public var browserMatcher: BrowserMatcher {
        let schemes = scheme == "*" ? ["http", "https"] : [scheme]
        let (kind, name): (String, String)
        switch host {
        case .any: (kind, name) = ("any", "")
        case .domainAndSubdomains(let domain): (kind, name) = ("domainAndSubdomains", domain)
        case .exact(let exact): (kind, name) = ("exact", exact)
        }
        // "*" becomes ".*"; every other ASCII punctuation character is escaped, so it matches itself.
        let regex = path.split(separator: "*", omittingEmptySubsequences: false)
            .map { part in
                part.map { ch -> String in
                    ch.isASCII && (ch.isPunctuation || ch.isSymbol) ? "\\" + String(ch) : String(ch)
                }.joined()
            }
            .joined(separator: ".*")
        return BrowserMatcher(schemes: schemes, hostKind: kind, host: name, pathRegex: "^" + regex + "$")
    }
}
