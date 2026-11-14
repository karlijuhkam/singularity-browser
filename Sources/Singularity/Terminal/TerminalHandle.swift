import Darwin
import Foundation
import SwiftTerm

/// What the Assistant's terminal tools need from a terminal tab: is it running, what is in front,
/// what does it show, and paste text into it. The app's `TerminalSession` is the real one; tests
/// pass fakes, so no test ever starts a shell.
@MainActor
protocol TerminalHandle: AnyObject {
    var isRunning: Bool { get }
    /// The program in front, nil while the shell sits at its prompt.
    var foregroundProgram: String? { get }
    /// The terminal's foreground process group, read fresh: a different value later means a
    /// different program has the keyboard (the agent exited, another one started).
    var foregroundGroupID: pid_t? { get }
    /// Whether the program in front switched bracketed paste on (then pasted newlines stay text).
    var bracketedPaste: Bool { get }
    /// The last `count` rows of what the terminal shows now, newest last: scrollback included, from
    /// the buffer in view (a full-screen program's own screen while it runs).
    func lastRows(_ count: Int) -> [String]
    /// Pastes `text` (as a bracketed paste when the program asked for it), waits a moment and
    /// presses Return. `stillSame`, when given, is asked right before the paste and again right
    /// before Return: false before the paste pastes nothing, false before Return leaves the text
    /// pasted but presses no Return. Returns whether Return was pressed.
    func paste(_ text: String, onlyIf stillSame: (@MainActor () -> Bool)?) async -> Bool
}

extension TerminalSession: TerminalHandle {
    var bracketedPaste: Bool { TerminalScreen.bracketedPaste(of: view) }

    func lastRows(_ count: Int) -> [String] { TerminalScreen.rows(of: view, last: count) }

    func paste(_ text: String, onlyIf stillSame: (@MainActor () -> Bool)?) async -> Bool {
        await TerminalPaste.run(
            text, onlyIf: stillSame,
            // A shell started just now may still be reading ~/.zshrc.
            ready: { await self.waitUntilReady() },
            // Bracketed paste keeps multi-line text together as one message in programs such as
            // Claude Code.
            paste: { self.view.pasteText($0) },
            // The short pause lets the program finish handling the paste before Return.
            pause: { try? await Task.sleep(for: .milliseconds(150)) },
            pressReturn: { self.view.send(txt: "\r") })
    }
}

/// The steps of a paste, in order, with the "still the same terminal?" check right before the
/// paste and right before Return. Separate from `TerminalSession` so tests can run the real order
/// with stand-ins, never a shell.
enum TerminalPaste {
    @MainActor static func run(_ text: String, onlyIf stillSame: (@MainActor () -> Bool)?,
                               ready: @MainActor () async -> Void, paste: @MainActor (String) -> Void,
                               pause: @MainActor () async -> Void, pressReturn: @MainActor () -> Void) async -> Bool {
        await ready()
        if let stillSame, !stillSame() { return false }
        paste(text)
        await pause()
        // The program may have exited during the pause: Return would then run the text as a shell
        // command. The text stays at the prompt instead.
        if let stillSame, !stillSame() { return false }
        pressReturn()
        return true
    }
}

/// Reading a terminal view through SwiftTerm's public snapshot API. These copy the rows under the
/// terminal's own lock, so they are safe on the main actor; they must not be called from inside a
/// SwiftTerm delegate callback (which already holds that lock).
enum TerminalScreen {
    /// The last `count` rows the view's active buffer holds, newest last, as plain text (no
    /// colours, trailing spaces trimmed). Blank rows below the last written one (the empty part of
    /// the screen under the prompt) are not counted. On the normal screen this reaches back into
    /// the scrollback; a full-screen program's alternate screen has none, so it is that screen.
    @MainActor static func rows(of view: TerminalView, last count: Int) -> [String] {
        guard count > 0,
              // `.history`: the live screen plus up to `count` rows of scrollback before it, so
              // there are `count` rows to give even when the bottom of the screen is still empty.
              let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: count),
                                                          buffer: .active) else { return [] }
        var rows = snapshot.rows.map(\.text)
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return Array(rows.suffix(count))
    }

    /// Whether the program in front switched bracketed paste on (DEC private mode 2004).
    @MainActor static func bracketedPaste(of view: TerminalView) -> Bool {
        view.terminalInputStateSnapshot()?.bracketedPasteMode ?? false
    }
}
