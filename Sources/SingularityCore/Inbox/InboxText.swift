import Foundation

/// Clean-up for text that agents or web pages put into the inbox. All of it is untrusted:
/// it is shown as plain text only, after going through here.
public enum InboxText {
    public static let messageLimit = 600
    public static let notificationLimit = 200
    public static let inputLimit = 4000   // permission input / approval text; keeps newlines and tabs

    /// Removes control characters, direction overrides (U+202A…202E, U+2066…2069) and invisible
    /// formatting (U+200B…200F, U+2060, U+FEFF), collapses runs of whitespace to one space,
    /// trims, and cuts to `limit` characters with a trailing "…".
    public static func clean(_ text: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true            // true at the start, so leading whitespace is dropped
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            } else if !isForbidden(scalar) {
                out.append(scalar); lastWasSpace = false
            }
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return shorten(result, limit: limit)
    }

    /// Like `clean`, but keeps newlines and tabs (and does not collapse whitespace).
    public static func cleanBlock(_ text: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar == "\n" || scalar == "\t" || !isForbidden(scalar) {
            // Other whitespace (e.g. \r, form feed) is a control character and was dropped above;
            // the remaining space characters stay as they are.
            out.append(scalar)
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return shorten(trimmed, limit: limit)
    }

    private static func isForbidden(_ s: Unicode.Scalar) -> Bool {
        if s.properties.generalCategory == .control { return true }
        switch s.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    private static func shorten(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
