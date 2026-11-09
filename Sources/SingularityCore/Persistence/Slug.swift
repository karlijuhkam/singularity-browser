import Foundation

public enum Slug {
    /// Turns a display name into a lowercase, ASCII, hyphen-separated slug:
    /// "Client Work (2026)" → "client-work-2026". Never returns an empty string.
    public static func make(from name: String) -> String {
        // Fold accents ("Ülemiste" → "Ulemiste") before dropping non-ASCII characters.
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var lastWasHyphen = true // avoids a leading hyphen
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.count > 40 {
            result = String(result.prefix(40))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? "space" : result
    }

    /// Like `make(from:)`, but appends "-2", "-3", … until it does not clash with `existing`.
    public static func unique(from name: String, existing: Set<String>) -> String {
        let base = make(from: name)
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}
