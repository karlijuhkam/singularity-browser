import Foundation

/// Where the palette's "Search <engine>" row goes among the matches.
///
/// The fuzzy matcher accepts letters scattered across a long address, so typing a search
/// ("swift concurrency") still matches a few history entries by accident. Those loose matches
/// must not push the search row down: it goes right after the *concrete* matches (the typed
/// words really are in the title or address), and before the loose ones. With no concrete
/// match, the search row is first, so Return searches.
public enum PaletteRanking {
    /// True when every typed word is in one of the fields: as a piece of text ("hub" in "GitHub"),
    /// or as the initials of its words ("ns" for "New Space", "gh" for "GitHub"). Ignores case.
    public static func isConcrete(_ query: String, in fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        if words.isEmpty { return false }
        return words.allSatisfy { word in
            fields.contains { field in field.lowercased().contains(word) || matchesInitials(word, in: field) }
        }
    }

    /// Concrete matches first (in the order given), then `search`, then the rest (in the order given).
    public static func placingSearch<Item>(_ search: Item, among matches: [Item], isConcrete: (Item) -> Bool) -> [Item] {
        let concrete = matches.filter(isConcrete)
        let loose = matches.filter { !isConcrete($0) }
        return concrete + [search] + loose
    }

    /// Every character of `word`, in order, at the start of a word of `field`: the very start,
    /// after a character that is not a letter or digit, or a capital after a small letter.
    static func matchesInitials(_ word: String, in field: String) -> Bool {
        let wanted = Array(word)
        let original = Array(field)
        let lower = Array(field.lowercased())
        // Lowercasing can change the character count for a few scripts; no initials then.
        guard !wanted.isEmpty, lower.count == original.count else { return false }
        var next = 0
        for index in original.indices where next < wanted.count {
            let startsWord: Bool
            if index == 0 {
                startsWord = true
            } else {
                let before = original[index - 1]
                startsWord = (!before.isLetter && !before.isNumber) || (before.isLowercase && original[index].isUppercase)
            }
            if startsWord && lower[index] == wanted[next] { next += 1 }
        }
        return next == wanted.count
    }
}
