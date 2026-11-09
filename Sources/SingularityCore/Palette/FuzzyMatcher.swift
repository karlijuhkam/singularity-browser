import Foundation

/// A small subsequence fuzzy matcher, like the one in most editors' "Go to file":
/// every query character must appear in order in the candidate.
/// Higher scores are better; `nil` means no match.
public enum FuzzyMatcher {
    public static func score(_ query: String, in candidate: String) -> Int? {
        let query = Array(query.lowercased().filter { !$0.isWhitespace })
        if query.isEmpty { return 0 }
        let original = Array(candidate)
        let text = Array(candidate.lowercased())
        // Lowercasing can change the character count for a few scripts; fall back to plain search then.
        guard text.count == original.count else {
            return candidate.lowercased().contains(String(query)) ? 1 : nil
        }

        var score = 0
        var queryIndex = 0
        var previousMatch: Int? = nil

        for (index, character) in text.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            score += 1
            if let previousMatch, previousMatch == index - 1 {
                score += 5 // consecutive characters
            }
            if index == 0 {
                score += 10 // start of the string
            } else {
                let before = original[index - 1]
                if !before.isLetter && !before.isNumber {
                    score += 8 // start of a word ("hub" in "git-hub")
                } else if before.isLowercase && original[index].isUppercase {
                    score += 6 // camelCase boundary
                }
            }
            previousMatch = index
            queryIndex += 1
        }

        guard queryIndex == query.count else { return nil }
        // Prefer shorter candidates when everything else is equal.
        return score * 100 - min(text.count, 99)
    }

    /// Best score across several fields (e.g. a tab's title and its URL).
    public static func bestScore(_ query: String, in candidates: [String]) -> Int? {
        candidates.compactMap { score(query, in: $0) }.max()
    }
}
