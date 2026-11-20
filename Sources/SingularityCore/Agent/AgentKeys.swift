import Foundation

/// A key an agent asks to press (`press_key`), in Playwright's spelling: a key name or one
/// character, optionally after modifiers joined with "+" ("Escape", "a", "Control+k", "Shift+Tab",
/// "Meta+ArrowLeft"). The app turns it into a real key event (`AgentInput`), so it carries the
/// macOS virtual key code and the characters AppKit would report.
public struct KeyChord: Equatable, Sendable {
    public let key: String
    public let characters: String
    public let keyCode: UInt16
    public let shift: Bool
    public let control: Bool
    public let option: Bool
    public let command: Bool

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Chords that would read or replace the owner's clipboard: refused by `press_key`.
    public var isClipboard: Bool {
        let k = key.lowercased()
        if command && !control && !option && ["v", "c", "x"].contains(k) { return true }
        return shift && key == "Insert"
    }

    /// Named keys: virtual key code (kVK_*) and the characters AppKit reports (function keys use
    /// the private-use values of NSUpArrowFunctionKey and friends; Core can't import AppKit).
    private static let named: [String: (UInt16, String)] = [
        "Enter": (36, "\r"), "Tab": (48, "\t"), "Space": (49, " "), "Backspace": (51, "\u{7F}"),
        "Escape": (53, "\u{1B}"), "Delete": (117, "\u{F728}"),
        "ArrowUp": (126, "\u{F700}"), "ArrowDown": (125, "\u{F701}"), "ArrowLeft": (123, "\u{F702}"), "ArrowRight": (124, "\u{F703}"),
        "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"), "PageUp": (116, "\u{F72C}"), "PageDown": (121, "\u{F72D}"),
        "Insert": (114, "\u{F727}"),
        "F1": (122, "\u{F704}"), "F2": (120, "\u{F705}"), "F3": (99, "\u{F706}"), "F4": (118, "\u{F707}"),
        "F5": (96, "\u{F708}"), "F6": (97, "\u{F709}"), "F7": (98, "\u{F70A}"), "F8": (100, "\u{F70B}"),
        "F9": (101, "\u{F70C}"), "F10": (109, "\u{F70D}"), "F11": (103, "\u{F70E}"), "F12": (111, "\u{F70F}"),
    ]

    /// US-layout key codes for letters, digits and common punctuation; any other character is
    /// sent with key code 0 and its own characters.
    private static let characterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

    /// The key code for one character (key code 0 when it has none on a US keyboard).
    public static func keyCode(for character: Character) -> UInt16 {
        characterCodes[Character(character.lowercased())] ?? 0
    }

    public static func parse(_ text: String) throws -> KeyChord {
        // "Control++" is Control and the plus key.
        var parts = text.components(separatedBy: "+")
        if text.count > 1 && text.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.last, !last.isEmpty else {
            throw ParseError(description: "No key in “\(text)”. Use a key name such as Enter, Escape or ArrowDown, or one character, with modifiers like Control+k.")
        }
        var shift = false, control = false, option = false, command = false
        for modifier in parts.dropLast() {
            switch modifier {
            case "Shift": shift = true
            case "Control": control = true
            case "Alt", "Option": option = true
            case "Meta", "Command", "ControlOrMeta": command = true
            default:
                throw ParseError(description: "Unknown modifier “\(modifier)” in “\(text)”. Use Shift, Control, Alt or Meta.")
            }
        }
        if let (code, characters) = named[last] {
            return KeyChord(key: last, characters: characters, keyCode: code, shift: shift, control: control, option: option, command: command)
        }
        guard last.count == 1, let character = last.first else {
            throw ParseError(description: "Unknown key “\(last)”. Use a key name such as Enter, Escape, Tab, ArrowDown, Backspace, F5, or one character.")
        }
        return KeyChord(key: last, characters: last, keyCode: keyCode(for: character),
                        shift: shift, control: control, option: option, command: command)
    }
}
