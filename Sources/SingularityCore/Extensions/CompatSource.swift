import Foundation

/// The Chrome API members WebKit's `WKWebExtension` lacks (found in the 1Password spike, 2026-11-20).
///
/// WebKit gives an extension a `chrome` object whose existing namespaces can't be extended at run time
/// (a member added to `chrome.webNavigation` is silently ignored), so a *use* of one of these members
/// is rewritten to look it up in `__sg` (`sg-compat.js`), which answers with the real member when
/// WebKit has it and a stand-in otherwise. A member WebKit gains later does no harm: the real one wins.
public enum CompatMembers {
    public static let missing: [(ns: String, member: String)] = [
        ("webNavigation", "onCreatedNavigationTarget"), ("webNavigation", "onHistoryStateUpdated"),
        ("webNavigation", "onReferenceFragmentUpdated"), ("webNavigation", "onTabReplaced"),
        ("webRequest", "onAuthRequired"), ("webRequest", "onBeforeRedirect"),
        ("webRequest", "onSendHeaders"), ("webRequest", "onResponseStarted"),
        ("runtime", "requestUpdateCheck"), ("runtime", "onSuspend"), ("runtime", "onMessageExternal"),
        ("runtime", "onConnectExternal"), ("runtime", "onUpdateAvailable"), ("runtime", "onRestartRequired"),
        ("permissions", "addHostAccessRequest"), ("permissions", "removeHostAccessRequest"),
        ("action", "getUserSettings"),
        ("storage", "managed"),
        ("windows", "onFocusChanged"), ("windows", "onCreated"),
    ]

    /// Whole namespaces WebKit lacks. These *can* be assigned onto `chrome` at run time, so their uses
    /// aren't rewritten; a use only means the extension needs the stand-ins file.
    public static let missingNamespaces: [String] = ["idle", "management", "privacy", "downloads", "notifications"]

    static let memberSet: Set<String> = Set(missing.map { "\($0.ns).\($0.member)" })
}

/// Reads JavaScript source just well enough to tell code from strings, comments and regular
/// expressions, and finds the uses that matter to `CompatAdapter`. Works on UTF-8 bytes; it is not a
/// parser, and its one guess (is this `/` a division or a regular expression?) follows the usual
/// rule: after a value (a name, number, `)` of an ordinary group, `]`) it divides; after anything
/// else (an operator, `(`, `}`, `)` of `if (…)`, a keyword like `return`) it starts a regex.
public enum CompatSource {
    // MARK: Code mask

    /// For each byte: true when it is code, false inside a string, template text (`${…}` is code
    /// again), a comment or a regular expression literal.
    public static func codeMask(_ b: [UInt8]) -> [Bool] {
        var mask = [Bool](repeating: true, count: b.count)
        let n = b.count
        var i = 0
        var valueBefore = false          // the last significant token was a value: `/` divides
        var lastWord = ""                // the last name read (for `if (…)` and keywords)
        var parens: [Bool] = []          // per open `(`: opened right after if/while/for/with
        var depth = 0                    // `{` nesting in code
        var templates: [Int] = []        // depths at which a `}` returns into template text
        var dotBefore = false            // the last token was `.`: the next name is a property

        func skipString(_ quote: UInt8) {
            mask[i] = false
            i += 1
            while i < n {
                let c = b[i]
                mask[i] = false
                if c == UInt8(ascii: "\\") { if i + 1 < n { mask[i + 1] = false }; i += 2; continue }
                i += 1
                if c == quote || c == UInt8(ascii: "\n") { return }
            }
        }

        /// Template text from `i` (just after a backtick or a `}` that closed a `${`), up to the
        /// closing backtick (returns false) or a `${` (returns true, code follows).
        func templateText() -> Bool {
            while i < n {
                let c = b[i]
                mask[i] = false
                if c == UInt8(ascii: "\\") { if i + 1 < n { mask[i + 1] = false }; i += 2; continue }
                if c == UInt8(ascii: "`") { i += 1; return false }
                if c == UInt8(ascii: "$"), i + 1 < n, b[i + 1] == UInt8(ascii: "{") {
                    mask[i + 1] = false
                    i += 2
                    return true
                }
                i += 1
            }
            return false
        }

        func enterTemplate() {
            if templateText() {
                depth += 1
                templates.append(depth)
                valueBefore = false
            } else {
                valueBefore = true
            }
        }

        while i < n {
            let c = b[i]
            if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") {
                i += 1
                continue
            }
            if isIdentifier(c) {
                let start = i
                while i < n, isIdentifier(b[i]) { i += 1 }
                if dotBefore {
                    // `a.return`, `a.if(…)`: a property, never a keyword.
                    lastWord = ""
                    valueBefore = true
                } else {
                    lastWord = String(decoding: b[start..<i], as: UTF8.self)
                    valueBefore = !regexKeywords.contains(lastWord)
                }
                dotBefore = false
                continue
            }
            dotBefore = c == UInt8(ascii: ".")
            switch c {
            case UInt8(ascii: "'"), UInt8(ascii: "\""):
                skipString(c)
                valueBefore = true
                lastWord = ""
            case UInt8(ascii: "`"):
                mask[i] = false
                i += 1
                enterTemplate()
                lastWord = ""
            case UInt8(ascii: "/"):
                if i + 1 < n, b[i + 1] == UInt8(ascii: "/") {
                    while i < n, b[i] != UInt8(ascii: "\n") { mask[i] = false; i += 1 }
                } else if i + 1 < n, b[i + 1] == UInt8(ascii: "*") {
                    mask[i] = false; mask[i + 1] = false
                    i += 2
                    while i < n {
                        mask[i] = false
                        if b[i] == UInt8(ascii: "*"), i + 1 < n, b[i + 1] == UInt8(ascii: "/") { mask[i + 1] = false; i += 2; break }
                        i += 1
                    }
                } else if valueBefore {
                    i += 1
                    valueBefore = false
                } else {
                    // A regular expression literal, with its flags.
                    var inClass = false
                    mask[i] = false
                    i += 1
                    while i < n {
                        let r = b[i]
                        mask[i] = false
                        if r == UInt8(ascii: "\\") { if i + 1 < n { mask[i + 1] = false }; i += 2; continue }
                        i += 1
                        if r == UInt8(ascii: "\n") { break }
                        if inClass { if r == UInt8(ascii: "]") { inClass = false }; continue }
                        if r == UInt8(ascii: "[") { inClass = true; continue }
                        if r == UInt8(ascii: "/") { break }
                    }
                    while i < n, isIdentifier(b[i]) { mask[i] = false; i += 1 }
                    valueBefore = true
                }
                lastWord = ""
            case UInt8(ascii: "("):
                parens.append(["if", "while", "for", "with"].contains(lastWord))
                i += 1
                valueBefore = false
                lastWord = ""
            case UInt8(ascii: ")"):
                let wasStatement = parens.popLast() ?? false
                i += 1
                valueBefore = !wasStatement
                lastWord = ""
            case UInt8(ascii: "]"):
                i += 1
                valueBefore = true
                lastWord = ""
            case UInt8(ascii: "{"):
                depth += 1
                i += 1
                valueBefore = false
                lastWord = ""
            case UInt8(ascii: "}"):
                if let top = templates.last, top == depth {
                    templates.removeLast()
                    depth -= 1
                    mask[i] = false
                    i += 1
                    enterTemplate()
                } else {
                    depth = max(0, depth - 1)
                    i += 1
                    // A block's end (`}/re/`) far more often than an object literal divided by something.
                    valueBefore = false
                }
                lastWord = ""
            case UInt8(ascii: "."):
                i += 1
                valueBefore = false
                lastWord = ""
            default:
                i += 1
                valueBefore = false
                lastWord = ""
            }
        }
        return mask
    }

    /// Keywords after which a `/` starts a regular expression.
    static let regexKeywords: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await",
    ]

    static func isIdentifier(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c >= 0x80
    }

    // MARK: Uses

    /// A use of `chrome.<ns>…` / `browser.<ns>…` found in code.
    struct Use {
        /// Where the root word (`chrome`/`browser`) starts, and its text.
        let start: Int
        let root: String
        let ns: String
        /// The member after the namespace, when there is one.
        let member: String?
    }

    /// Every `chrome.<ns>` / `browser.<ns>` (with `.` or `?.`, spaces allowed) in code, with the
    /// member after it when present. The root must be a whole name not after a dot.
    static func uses(_ b: [UInt8], mask: [Bool]) -> [Use] {
        var out: [Use] = []
        let n = b.count
        var i = 0
        while i < n {
            guard mask[i], isIdentifier(b[i]) else { i += 1; continue }
            let start = i
            while i < n, isIdentifier(b[i]) { i += 1 }
            let word = String(decoding: b[start..<i], as: UTF8.self)
            guard word == "chrome" || word == "browser", !afterDot(b, start) else { continue }
            var j = i
            guard let nsStart = access(b, mask, &j) else { continue }
            let ns = String(decoding: b[nsStart..<j], as: UTF8.self)
            var k = j
            var member: String?
            if let memberStart = access(b, mask, &k) {
                member = String(decoding: b[memberStart..<k], as: UTF8.self)
            }
            out.append(Use(start: start, root: word, ns: ns, member: member))
        }
        return out
    }

    /// From `j` (after a name): spaces, `.` or `?.`, spaces, a name. Returns the name's start and
    /// leaves `j` after it; nil (and `j` unspecified) when that isn't what follows.
    private static func access(_ b: [UInt8], _ mask: [Bool], _ j: inout Int) -> Int? {
        let n = b.count
        skipSpaces(b, &j)
        guard j < n, mask[j] else { return nil }
        if b[j] == UInt8(ascii: "?"), j + 1 < n, b[j + 1] == UInt8(ascii: ".") { j += 2 } else if b[j] == UInt8(ascii: ".") { j += 1 } else { return nil }
        skipSpaces(b, &j)
        guard j < n, mask[j], isIdentifier(b[j]), !(b[j] >= UInt8(ascii: "0") && b[j] <= UInt8(ascii: "9")) else { return nil }
        let start = j
        while j < n, isIdentifier(b[j]) { j += 1 }
        return start
    }

    private static func skipSpaces(_ b: [UInt8], _ j: inout Int) {
        while j < b.count, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(b[j]) { j += 1 }
    }

    /// Whether the name at `start` follows a `.` (a property such as `x.chrome`).
    private static func afterDot(_ b: [UInt8], _ start: Int) -> Bool {
        var p = start - 1
        while p >= 0, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(b[p]) { p -= 1 }
        return p >= 0 && b[p] == UInt8(ascii: ".")
    }

    /// The replacement for a root word: identifier-led (never joins the previous line through ASI)
    /// and quote-free (still valid if it ever landed inside a string). Without `sg-compat.js` loaded
    /// it is the original object, so an injected file behaves as it did.
    static func replacement(root: String) -> String { "Object(globalThis.__sg||\(root))" }

    /// Replaces the `length` bytes at `atWord` with the replacement for `root` (used by `rewrite`;
    /// open for tests).
    static func splice(_ text: String, atWord: Int, length: Int, root: String) -> String {
        var b = Array(text.utf8)
        b.replaceSubrange(atWord..<(atWord + length), with: Array(replacement(root: root).utf8))
        return String(decoding: b, as: UTF8.self)
    }

    /// Rewrites every real use of a listed member (`CompatMembers.missing`) so it reads from `__sg`.
    /// Returns the new text and the members used (`"ns.member"`).
    public static func rewrite(_ text: String) -> (text: String, members: Set<String>) {
        let b = Array(text.utf8)
        let mask = codeMask(b)
        var members: Set<String> = []
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var copied = 0
        for use in uses(b, mask: mask) {
            guard let member = use.member, CompatMembers.memberSet.contains("\(use.ns).\(member)") else { continue }
            members.insert("\(use.ns).\(member)")
            out.append(contentsOf: b[copied..<use.start])
            out.append(contentsOf: Array(replacement(root: use.root).utf8))
            copied = use.start + use.root.utf8.count
        }
        guard !members.isEmpty else { return (text, []) }
        out.append(contentsOf: b[copied...])
        return (String(decoding: out, as: UTF8.self), members)
    }

    /// The whole missing namespaces (`CompatMembers.missingNamespaces`) the code uses.
    public static func usedNamespaces(_ text: String) -> Set<String> {
        let b = Array(text.utf8)
        return Set(uses(b, mask: codeMask(b)).map(\.ns).filter { CompatMembers.missingNamespaces.contains($0) })
    }

    // MARK: WebSocket, imports

    /// Whether the code constructs a WebSocket (`new WebSocket`, `new self.WebSocket`,
    /// `new globalThis.WebSocket`); a mention in a string or comment doesn't count.
    public static func constructsWebSocket(_ text: String) -> Bool {
        let b = Array(text.utf8)
        let mask = codeMask(b)
        let words = codeWords(b, mask)
        for (index, word) in words.enumerated() where word.text == "new" {
            var k = index + 1
            if k < words.count, ["self", "globalThis", "window"].contains(words[k].text), words[k].dotAfter { k += 1 }
            if k < words.count, words[k].text == "WebSocket", adjacent(b, from: words[k - 1], to: words[k]) { return true }
        }
        return false
    }

    private struct Word { let text: String; let start: Int; let end: Int; let dotAfter: Bool }

    private static func codeWords(_ b: [UInt8], _ mask: [Bool]) -> [Word] {
        var out: [Word] = []
        var i = 0
        let n = b.count
        while i < n {
            guard mask[i], isIdentifier(b[i]) else { i += 1; continue }
            let start = i
            while i < n, isIdentifier(b[i]) { i += 1 }
            var j = i
            skipSpaces(b, &j)
            out.append(Word(text: String(decoding: b[start..<i], as: UTF8.self), start: start, end: i,
                            dotAfter: j < n && b[j] == UInt8(ascii: ".")))
        }
        return out
    }

    /// Only spaces (and one dot, for `self.WebSocket`) between two words.
    private static func adjacent(_ b: [UInt8], from a: Word, to c: Word) -> Bool {
        var dots = 0
        for p in a.end..<c.start {
            if b[p] == UInt8(ascii: ".") { dots += 1; continue }
            if ![UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(b[p]) { return false }
        }
        return dots <= (a.text == "new" ? 0 : 1)
    }

    /// The specifiers of static `import … from "x"`, `import "x"` and `export … from "x"`, in order
    /// (dynamic `import(…)` is not followed).
    public static func staticImports(_ text: String) -> [String] {
        let b = Array(text.utf8)
        let mask = codeMask(b)
        let n = b.count
        var out: [String] = []
        for word in codeWords(b, mask) where word.text == "import" || word.text == "export" {
            guard !afterDot(b, word.start) else { continue }
            var j = word.end
            skipSpaces(b, &j)
            guard j < n else { continue }
            if word.text == "import" {
                if b[j] == UInt8(ascii: "(") || b[j] == UInt8(ascii: ".") { continue }
                if let literal = stringLiteral(b, mask, at: j) { out.append(literal); continue }
            } else if b[j] != UInt8(ascii: "*") && b[j] != UInt8(ascii: "{") {
                continue
            }
            // Up to `from "x"`, stopping at the statement's end.
            var k = j
            let limit = min(n, j + 20_000)
            while k < limit {
                if mask[k], b[k] == UInt8(ascii: ";") { break }
                if mask[k], isIdentifier(b[k]) {
                    let s = k
                    while k < n, isIdentifier(b[k]) { k += 1 }
                    if String(decoding: b[s..<k], as: UTF8.self) == "from" {
                        var q = k
                        skipSpaces(b, &q)
                        if let literal = stringLiteral(b, mask, at: q) { out.append(literal); break }
                    }
                    continue
                }
                k += 1
            }
        }
        return out
    }

    /// The string-literal arguments of `importScripts(…)` calls in code.
    public static func importScriptsArguments(_ text: String) -> [String] {
        let b = Array(text.utf8)
        let mask = codeMask(b)
        let n = b.count
        var out: [String] = []
        for word in codeWords(b, mask) where word.text == "importScripts" {
            var j = word.end
            skipSpaces(b, &j)
            guard j < n, b[j] == UInt8(ascii: "(") else { continue }
            j += 1
            while j < n {
                skipSpaces(b, &j)
                guard j < n else { break }
                if b[j] == UInt8(ascii: ")") { break }
                if b[j] == UInt8(ascii: ",") { j += 1; continue }
                if let literal = stringLiteral(b, mask, at: j) {
                    out.append(literal)
                    j += 1
                    while j < n, mask[j] == false { j += 1 }
                } else {
                    // Not a literal: skip to the next comma or the end of the call.
                    while j < n, b[j] != UInt8(ascii: ","), b[j] != UInt8(ascii: ")") { j += 1 }
                }
            }
        }
        return out
    }

    /// The contents of a `'…'` or `"…"` literal starting at `j` (simple escapes only).
    private static func stringLiteral(_ b: [UInt8], _ mask: [Bool], at j: Int) -> String? {
        guard j < b.count, b[j] == UInt8(ascii: "'") || b[j] == UInt8(ascii: "\"") else { return nil }
        let quote = b[j]
        var k = j + 1
        var bytes: [UInt8] = []
        while k < b.count, b[k] != quote, b[k] != UInt8(ascii: "\n") {
            if b[k] == UInt8(ascii: "\\"), k + 1 < b.count { bytes.append(b[k + 1]); k += 2; continue }
            bytes.append(b[k])
            k += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
