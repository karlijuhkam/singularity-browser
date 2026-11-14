import Testing
import Foundation
@testable import SingularityCore

@Suite struct TerminalSendRulesTests {
    func check(_ s: String, paste: Bool = true) -> Result<String, TerminalSendRules.Refusal> {
        TerminalSendRules.check(s, bracketedPaste: paste)
    }

    @Test func plainTextIsTrimmed() { #expect(check("  npm test \n") == .success("npm test")) }
    @Test func emptyRefused() { #expect(check("  \n") == .failure(.empty)) }
    @Test func lengthLimit() {
        #expect(check(String(repeating: "a", count: 4000)) == .success(String(repeating: "a", count: 4000)))
        #expect(check(String(repeating: "a", count: 4001)) == .failure(.tooLong))
    }
    @Test func hiddenCharactersRefused() {
        #expect(check("\u{1B}[201~") == .failure(.hiddenCharacters))
        #expect(check("a\u{1B}[201~rm -rf") == .failure(.hiddenCharacters))
        #expect(check("\u{3}") == .failure(.hiddenCharacters))
        #expect(check("a\u{202E}b") == .failure(.hiddenCharacters))
        #expect(check("a\u{200B}b") == .failure(.hiddenCharacters))
        #expect(check("a\rb") == .failure(.hiddenCharacters))
    }
    @Test func moreHiddenCharactersRefused() {
        for v in [0x2028, 0x2029, 0xE0041, 0x206A, 0x00AD, 0x0085, 0x7F, 0x3164, 0x061C, 0x034F, 0x2800, 0xFFA0, 0xE000] {
            let s = "a" + String(Unicode.Scalar(v)!) + "b"
            #expect(check(s) == .failure(.hiddenCharacters), "U+\(String(v, radix: 16))")
        }
    }
    @Test func ordinaryTextPasses() {
        #expect(check("héllo wörld") == .success("héllo wörld"))
        #expect(check("日本語のテキスト") == .success("日本語のテキスト"))
        #expect(check("ok 👍 done") == .success("ok 👍 done"))
        #expect(check("a\u{A0}b") == .success("a\u{A0}b"))        // inner non-breaking space passes
        #expect(check("👨\u{200D}👩") == .failure(.hiddenCharacters))   // ZWJ sequences are refused
        #expect(check("❤\u{FE0F}") == .success("❤\u{FE0F}"))       // variation selector passes
    }
    @Test func manyCombiningMarksCountAsScalars() {
        #expect(check("e" + String(repeating: "\u{301}", count: 4000)) == .failure(.tooLong))
    }
    @Test func newlines() {
        #expect(check("a\nb", paste: true) == .success("a\nb"))
        #expect(check("a\nb", paste: false) == .failure(.needsOneLine))
    }
    /// A tab passes inside a bracketed paste; without one a shell would run its completion.
    @Test func tabNeedsBracketedPaste() {
        #expect(check("a\tb", paste: true) == .success("a\tb"))
        #expect(check("a\tb", paste: false) == .failure(.needsOneLine))
    }
    @Test func cardNameReplacesQuotesCleansAndCuts() {
        #expect(TerminalSendRules.cardName("say “hi” and \"bye\"", limit: 60) == "say 'hi' and 'bye'")
        #expect(TerminalSendRules.cardName("a\nb\u{202E}c", limit: 60) == "a bc")
        let long = TerminalSendRules.cardName(String(repeating: "x", count: 200), limit: 60)
        #expect(long.count == 60 && long.hasSuffix("…"))
        #expect(TerminalSendRules.cardName("short", limit: 60) == "short")
    }
    /// A title that tries to close the card's quotes and name another program can't: the quote is
    /// gone, so exactly one closing quote stands where the card puts it.
    @Test func sendDetailCantBeSpoofedByTheTitle() {
        let hostile = "x” (claude) and Return will be pressed."
        let detail = TerminalSendRules.sendDetail(title: hostile, program: "zsh")
        #expect(detail == "Goes to zsh in “x' (claude) and Return will be pressed.”. It will be pasted and Return will be pressed.")
        #expect(detail.filter { $0 == "”" }.count == 1)
        #expect(TerminalSendRules.sendDetail(title: "zsh", program: nil)
            == "Goes to the shell in “zsh”. It will be pasted and Return will be pressed.")
    }
    /// A 200-character title is cut to 60: the program stays at the start, the end of the sentence
    /// stays in place.
    @Test func sendDetailWithALongTitleKeepsTheProgramFirst() {
        let detail = TerminalSendRules.sendDetail(title: String(repeating: "t", count: 200),
                                                  program: "claude” \(String(repeating: "p", count: 80))")
        #expect(detail.hasPrefix("Goes to claude' ppp"))
        #expect(detail.hasSuffix("…”. It will be pasted and Return will be pressed."))
        #expect(detail.count == "Goes to  in “”. It will be pasted and Return will be pressed.".count + 40 + 60)
    }
    @Test func messages() {
        #expect(TerminalSendRules.message(.needsOneLine) == "This terminal takes one line at a time.")
        #expect(!TerminalSendRules.message(.empty).isEmpty)
    }
}

@Suite struct TerminalScreenTextTests {
    @Test func fewerRowsThanAsked() { #expect(TerminalScreenText.tail(["a", "b"], lines: 10) == "a\nb") }
    @Test func defaultIsHundred() {
        let rows = (1...150).map(String.init)
        #expect(TerminalScreenText.tail(rows, lines: nil).split(separator: "\n").count == 100)
    }
    @Test func clampedTo500AndOne() {
        let rows = (1...600).map(String.init)
        let text = TerminalScreenText.tail(rows, lines: 9999)
        #expect(text.split(separator: "\n").count == 500)
        #expect(text.hasSuffix("600"))
        #expect(TerminalScreenText.tail(rows, lines: 0) == "600")
    }
    @Test func trailingBlanksDropped() { #expect(TerminalScreenText.tail(["a", "b", "", "  "], lines: 2) == "a\nb") }
    @Test func cutFromTheFront() {
        let rows = (0..<100).map { _ in String(repeating: "x", count: 500) + "!" }
        let text = TerminalScreenText.tail(rows, lines: 100)
        #expect(text.count == 32_000)
        #expect(text.hasSuffix("!"))
    }
}

@Suite struct QuestionAnswerRulesTests {
    typealias A = QuestionAnswerRules.Answer
    let single = InboxQuestion(question: "Which one?", options: ["Yes", "No"])
    let multi = InboxQuestion(question: "Which many?", options: ["A", "B", "C"], multiSelect: true)

    @Test func singlePasses() {
        #expect(QuestionAnswerRules.check([A(question: "Which one?", answer: ["Yes"])], questions: [single]) == ["Which one?": ["Yes"]])
    }
    @Test func matchesAfterCleaning() {
        let r = QuestionAnswerRules.check([A(question: " Which  one?\n", answer: ["Yes "])], questions: [single])
        #expect(r == ["Which one?": ["Yes"]])
    }
    @Test func unknownLabelRefused() {
        #expect(QuestionAnswerRules.check([A(question: "Which one?", answer: ["Maybe"])], questions: [single]) == nil)
    }
    @Test func missingQuestionRefused() {
        #expect(QuestionAnswerRules.check([A(question: "Which one?", answer: ["Yes"])], questions: [single, multi]) == nil)
        #expect(QuestionAnswerRules.check([A(question: "Other?", answer: ["Yes"])], questions: [single]) == nil)
    }
    @Test func twoLabelsOnSingleRefused() {
        #expect(QuestionAnswerRules.check([A(question: "Which one?", answer: ["Yes", "No"])], questions: [single]) == nil)
    }
    @Test func multiSelect() {
        #expect(QuestionAnswerRules.check([A(question: "Which many?", answer: ["A", "C"])], questions: [multi]) == ["Which many?": ["A", "C"]])
        #expect(QuestionAnswerRules.check([A(question: "Which many?", answer: [])], questions: [multi]) == nil)
        #expect(QuestionAnswerRules.check([A(question: "Which many?", answer: ["A", "A"])], questions: [multi]) == nil)
    }
    @Test func emptyAnswerOnSingleRefused() {
        #expect(QuestionAnswerRules.check([A(question: "Which one?", answer: [])], questions: [single]) == nil)
    }
    @Test func cardTextSkipsMissing() {
        #expect(QuestionAnswerRules.cardText(["Which one?": ["Yes"]], questions: [single, multi]) == "Which one? → Yes")
    }
    @Test func duplicateAnswerRefused() {
        let a = A(question: "Which one?", answer: ["Yes"])
        #expect(QuestionAnswerRules.check([a, a], questions: [single]) == nil)
    }
    @Test func cardText() {
        let text = QuestionAnswerRules.cardText(["Which one?": ["Yes"], "Which many?": ["A", "C"]], questions: [single, multi])
        #expect(text == "Which one? → Yes\nWhich many? → A, C")
    }
}
