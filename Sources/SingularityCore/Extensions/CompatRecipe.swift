import Foundation

/// An extension-specific change `CompatAdapter` makes on top of the general ones, keyed by Chrome id.
///
/// A replacement is a regular expression that must match **exactly** `count` times in its file
/// (after the general rewrite); any other count fails the whole adaptation, so a new release whose
/// code changed shape is never half-adapted. Minified names change every release, so patterns
/// match the code's shape, not its names. `guardPattern` (optional) is a second expression, with
/// `$1`…`$9` replaced by the match's groups (regex-escaped), that must be found somewhere in the
/// same file for a match to count.
public struct CompatRecipe: Sendable {
    public struct Replacement: Sendable {
        /// The file's path in the extension, e.g. `background/background.js`.
        public let file: String
        public let pattern: String
        public let guardPattern: String?
        /// `NSRegularExpression` template (`$1`…).
        public let template: String
        public let count: Int
    }

    public let id: String
    public let name: String
    /// The background must run as a page even without a WebSocket in its code.
    public let backgroundAsPage: Bool
    public let replacements: [Replacement]

    public static let all: [String: CompatRecipe] = [onePassword.id: onePassword]

    /// 1Password (checked against 8.12.46.29, the version Chrome Web Store served on 2026-11-21).
    ///
    /// Its background runs as a page: its notifier WebSocket hangs WebKit's service-worker
    /// background (spike, 2026-11-20). And its "Chrome with manifest version 3, so a service
    /// worker" check, `function X(){return Y()&&Z()}` where `Y` is `function Y(){return E(3)}`,
    /// also requires `ServiceWorkerGlobalScope`, so in the page it takes its Firefox-style page
    /// paths (otherwise it calls `clients.matchAll` and fails).
    public static let onePassword = CompatRecipe(
        id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
        name: "1Password",
        backgroundAsPage: true,
        replacements: [
            Replacement(file: "background/background.js",
                        pattern: #"function ([\w$]+)\(\)\{return ([\w$]+)\(\)&&([\w$]+)\(\)\}"#,
                        guardPattern: #"function $2\(\)\{return [\w$]+\(3\)\}"#,
                        template: #"function $1(){return $2()&&$3()&&typeof ServiceWorkerGlobalScope!=="undefined"}"#,
                        count: 1),
        ])
}
