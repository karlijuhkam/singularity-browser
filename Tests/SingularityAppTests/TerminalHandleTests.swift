import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import Singularity

extension AppTests {
/// Reading a terminal's screen through SwiftTerm's public snapshot API (`TerminalScreen`), on a
/// terminal view that is only fed text: no process is ever started, so no shell runs.
@MainActor
@Suite(.serialized) struct TerminalHandleTests {
    /// A terminal view with a frame (80 × 25 or so), never shown in a window, with no process.
    private func makeView() -> LocalProcessTerminalView {
        MainRunLoopGuard.start
        return LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    }

    private func feedNumberedLines(_ view: TerminalView, count: Int) {
        for n in 1...count {
            view.feed(text: "line \(n)\r\n")
        }
    }

    @Test func rowsIncludeScrollbackAndEndWithTheLastLine() throws {
        let view = makeView()
        feedNumberedLines(view, count: 300)
        let rows = TerminalScreen.rows(of: view, last: 100)
        #expect(rows.count == 100)
        #expect(rows.last == "line 300")
        #expect(rows.first == "line 201")
        // The screen shows far fewer than 100 rows: the first ones came from the scrollback.
        let screenRows = try #require(view.terminalInputStateSnapshot()).dimensions.rows
        #expect(screenRows < 100)
        let visible = view.visibleRowsText(0..<screenRows)
        #expect(!visible.contains("line 201"))
        #expect(rows.contains("line 201"))
    }

    @Test func fewerRowsThanAskedForGivesWhatThereIs() {
        let view = makeView()
        feedNumberedLines(view, count: 3)
        // The blank rows under the last line are not counted as lines.
        #expect(TerminalScreen.rows(of: view, last: 100) == ["line 1", "line 2", "line 3"])
        #expect(TerminalScreen.rows(of: view, last: 2) == ["line 2", "line 3"])
        #expect(TerminalScreen.rows(of: view, last: 0).isEmpty)
    }

    /// The order of a paste (`TerminalPaste.run`, what `TerminalSession.paste` runs): wait for the
    /// shell, check, paste, pause, check, Return. Without a check (an artifact page's `prompt()`)
    /// it always presses Return; a failed check before the paste pastes nothing, one before Return
    /// presses no Return.
    @Test func aPasteChecksBeforeThePasteAndBeforeReturn() async {
        var steps: [String] = []
        func run(_ stillSame: (@MainActor () -> Bool)?) async -> Bool {
            await TerminalPaste.run("hi", onlyIf: stillSame,
                                    ready: { steps.append("ready") }, paste: { steps.append("paste \($0)") },
                                    pause: { steps.append("pause") }, pressReturn: { steps.append("return") })
        }
        #expect(await run(nil))
        #expect(steps == ["ready", "paste hi", "pause", "return"])

        steps = []
        #expect(await run({ steps.append("check"); return true }))
        #expect(steps == ["ready", "check", "paste hi", "pause", "check", "return"])

        steps = []
        #expect(await run({ steps.append("check"); return false }) == false)
        #expect(steps == ["ready", "check"])

        steps = []
        #expect(await run({ steps.append("check"); return !steps.contains("pause") }) == false)
        #expect(steps == ["ready", "check", "paste hi", "pause", "check"])
    }

    @Test func bracketedPasteFollowsTheProgram() {
        let view = makeView()
        #expect(!TerminalScreen.bracketedPaste(of: view))
        view.feed(text: "\u{1B}[?2004h")
        #expect(TerminalScreen.bracketedPaste(of: view))
        view.feed(text: "\u{1B}[?2004l")
        #expect(!TerminalScreen.bracketedPaste(of: view))
    }

    @Test func aFullScreenProgramsScreenIsWhatIsRead() {
        let view = makeView()
        feedNumberedLines(view, count: 300)
        // A full-screen program switches to the alternate screen and draws there.
        view.feed(text: "\u{1B}[?1049h\u{1B}[H\u{1B}[2Jfull screen\r\n")
        let rows = TerminalScreen.rows(of: view, last: 100)
        #expect(rows == ["full screen"])
        // Back on the normal screen, the shell's lines are there again.
        view.feed(text: "\u{1B}[?1049l")
        #expect(TerminalScreen.rows(of: view, last: 100).contains("line 300"))
    }
}
}
