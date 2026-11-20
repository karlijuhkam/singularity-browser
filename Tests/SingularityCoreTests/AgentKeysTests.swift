import Foundation
import Testing
@testable import SingularityCore

@Suite struct AgentKeysTests {
    @Test func namedKeys() throws {
        #expect(try KeyChord.parse("Escape").keyCode == 53)
        let enter = try KeyChord.parse("Enter")
        #expect(enter.keyCode == 36)
        #expect(enter.characters == "\r")
        let down = try KeyChord.parse("ArrowDown")
        #expect(down.keyCode == 125)
        #expect(down.characters == "\u{F701}")
        #expect(try KeyChord.parse("F5").keyCode == 96)
        #expect(try KeyChord.parse("Tab").keyCode == 48)
    }

    @Test func modifiers() throws {
        let k = try KeyChord.parse("Control+k")
        #expect(k.control && !k.command && !k.shift && !k.option)
        #expect(k.key == "k")
        #expect(k.keyCode == 40)
        let backTab = try KeyChord.parse("Shift+Tab")
        #expect(backTab.shift)
        #expect(backTab.keyCode == 48)
        #expect(try KeyChord.parse("Meta+a").command)
        #expect(try KeyChord.parse("Alt+ArrowLeft").option)
    }

    @Test func characters() throws {
        let a = try KeyChord.parse("a")
        #expect(a.keyCode == 0)
        #expect(a.characters == "a")
        let e = try KeyChord.parse("é")
        #expect(e.keyCode == 0)
        #expect(e.characters == "é")
    }

    @Test func clipboardChords() throws {
        for text in ["Meta+v", "Meta+c", "Meta+x", "Shift+Insert", "Meta+V"] {
            #expect(try KeyChord.parse(text).isClipboard, "\(text)")
        }
        #expect(try !KeyChord.parse("Control+v").isClipboard)
        #expect(try !KeyChord.parse("v").isClipboard)
    }

    @Test func badNamesThrow() {
        for text in ["", "Control+", "Hyper+a", "NoSuchKey", "+"] {
            #expect(throws: KeyChord.ParseError.self, "\(text)") { try KeyChord.parse(text) }
        }
    }
}
