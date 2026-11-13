import AppKit
import SingularityCore
import SwiftUI

/// A field that holds one emoji or nothing: a Space's icon (Edit Space, the welcome flow) and a
/// launcher's icon. Typing or picking another emoji replaces the one that is there; anything that
/// is not an emoji is dropped (`Emoji.single`).
struct EmojiField: View {
    /// The emoji, or "" for none.
    @Binding var emoji: String
    @FocusState private var isFocused: Bool

    /// A few to pick from where a full picker would be too much (the launcher icon menu).
    static let suggestions = ["🤖", "🧠", "🔥", "⚡️", "🛠️", "🧪", "🚀", "🐙", "🦀", "📦"]

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: Binding(get: { emoji }, set: { emoji = Self.newest(in: $0) }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 40)
                .focused($isFocused)
            Button("Choose…") {
                // The system emoji picker types into whatever field has the keyboard, so give it
                // to ours first, then open the picker on the next turn of the run loop.
                isFocused = true
                DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
            }
            if !emoji.isEmpty {
                Button("Remove") { emoji = "" }
            }
        }
    }

    /// The last emoji in what the field now holds: with "🎧" there, typing 🎸 gives "🎧🎸" and
    /// the new one wins.
    static func newest(in text: String) -> String {
        for character in text.reversed() {
            if let emoji = Emoji.single(String(character)) { return emoji }
        }
        return ""
    }
}
