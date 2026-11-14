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
    @Test func newlines() {
        #expect(check("a\nb", paste: true) == .success("a\nb"))
        #expect(check("a\nb", paste: false) == .failure(.needsOneLine))
    }
    @Test func tabPasses() { #expect(check("a\tb", paste: false) == .success("a\tb")) }
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
    @Test func duplicateAnswerRefused() {
        let a = A(question: "Which one?", answer: ["Yes"])
        #expect(QuestionAnswerRules.check([a, a], questions: [single]) == nil)
    }
    @Test func cardText() {
        let text = QuestionAnswerRules.cardText(["Which one?": ["Yes"], "Which many?": ["A", "C"]], questions: [single, multi])
        #expect(text == "Which one? → Yes\nWhich many? → A, C")
    }
}
