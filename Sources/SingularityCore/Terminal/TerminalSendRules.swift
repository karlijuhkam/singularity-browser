import Foundation

/// What text the Assistant may ask to have pasted into a terminal. The card shows exactly the
/// text this returns, and that same text is what gets sent.
public enum TerminalSendRules {
    public static let maxLength = 4000

    public enum Refusal: Error, Equatable { case empty, tooLong, hiddenCharacters, needsOneLine }

    /// Trims, then refuses: empty; > 4000 characters; any control character except "\n" and "\t"
    /// (this also catches ESC, so the paste-end sequence can't be smuggled in); anything
    /// `InboxText.cleanBlock(_, limit: .max)` would change (invisible and direction characters), so
    /// the card shows exactly this; a newline when `bracketedPaste` is false (without bracketed
    /// paste a newline would press Return in the middle of the text).
    public static func check(_ text: String, bracketedPaste: Bool) -> Result<String, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.count > maxLength { return .failure(.tooLong) }
        for scalar in trimmed.unicodeScalars
        where scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" {
            return .failure(.hiddenCharacters)
        }
        if InboxText.cleanBlock(trimmed, limit: .max) != trimmed { return .failure(.hiddenCharacters) }
        if !bracketedPaste && trimmed.unicodeScalars.contains("\n") { return .failure(.needsOneLine) }
        return .success(trimmed)
    }

    public static func message(_ refusal: Refusal) -> String {
        switch refusal {
        case .empty: "There is no text to send."
        case .tooLong: "The text is longer than \(maxLength) characters."
        case .hiddenCharacters: "The text has control or invisible characters, which can't be sent."
        case .needsOneLine: "This terminal takes one line at a time."
        }
    }
}

/// The part of a terminal's screen an agent may read.
public enum TerminalScreenText {
    public static let defaultLines = 100, maxLines = 500, maxCharacters = 32_000

    /// The last `lines` rows (clamped 1…500, default 100), trailing blank rows dropped, joined with
    /// "\n", cut from the front to 32 000 characters (the newest text stays).
    public static func tail(_ rows: [String], lines: Int?) -> String {
        let wanted = min(max(lines ?? defaultLines, 1), maxLines)
        var kept = rows[...]
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept = kept.dropLast() }
        let text = kept.suffix(wanted).joined(separator: "\n")
        return text.count > maxCharacters ? String(text.suffix(maxCharacters)) : text
    }
}

/// Answers to a held question (Claude Code's AskUserQuestion), as a model gives them.
public enum QuestionAnswerRules {
    public struct Answer: Equatable, Sendable {
        public var question: String
        public var answer: [String]
        public init(question: String, answer: [String]) {
            self.question = question
            self.answer = answer
        }
    }

    private static func key(_ text: String) -> String {
        // The same cleaning `ClaudeHook.answerReply` uses to find a question or label again.
        InboxText.clean(text, limit: InboxText.messageLimit)
    }

    /// Every held question answered exactly once, every label one of its options, one label unless
    /// multiSelect (then at least one, none twice). Returns what `InboxCenter.answerQuestion`
    /// takes (cleaned question → cleaned labels), or nil.
    public static func check(_ answers: [Answer], questions: [InboxQuestion]) -> [String: [String]]? {
        guard !questions.isEmpty, answers.count == questions.count else { return nil }
        var given: [String: [String]] = [:]
        for item in answers {
            let k = key(item.question)
            if given[k] != nil { return nil }
            given[k] = item.answer.map(key)
        }
        var result: [String: [String]] = [:]
        for question in questions {
            let k = key(question.question)
            guard result[k] == nil, let labels = given[k] else { return nil }
            let options = Set(question.options.map(key))
            guard labels.allSatisfy(options.contains), Set(labels).count == labels.count else { return nil }
            if question.multiSelect ? labels.isEmpty : labels.count != 1 { return nil }
            result[k] = labels
        }
        return result.count == given.count ? result : nil
    }

    /// One line per question for the card: "<question> → <label>, <label>".
    public static func cardText(_ answers: [String: [String]], questions: [InboxQuestion]) -> String {
        questions.map { q in
            let k = key(q.question)
            return "\(k) → \((answers[k] ?? []).joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}
