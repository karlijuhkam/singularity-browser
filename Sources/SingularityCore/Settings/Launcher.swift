import Foundation

/// A button in the sidebar's bottom row that opens a new terminal tab and types one command into
/// it (Settings → Terminal → Launchers), e.g. "Claude Code" → `claude`.
///
/// A launcher starts, assigns and watches nothing: it is the owner's own command, typed for them.
/// The list lives in `settings.json`; only the owner's click runs one.
public struct Launcher: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// One line, typed into the new tab's login shell and followed by Return.
    public var command: String
    /// "claude" or "codex" (the two logos the app ships), one emoji, or empty (then the button
    /// shows the first letter of the name).
    public var icon: String

    public init(id: UUID = UUID(), name: String, command: String, icon: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
    }

    /// The logos shipped with the app, by the name stored in `icon`.
    public static let logoNames = ["claude", "codex"]

    /// What a settings file without a `launchers` key gets. The ids are fixed, so the defaults are
    /// the same two launchers at every launch until the owner changes the list.
    public static let defaults: [Launcher] = [
        Launcher(id: UUID(uuidString: "5D0F7A0E-0C1A-4B7E-9A51-000000000001")!, name: "Claude Code", command: "claude", icon: "claude"),
        Launcher(id: UUID(uuidString: "5D0F7A0E-0C1A-4B7E-9A51-000000000002")!, name: "Codex", command: "codex", icon: "codex"),
    ]

    /// What the button shows.
    public enum Glyph: Equatable, Sendable {
        case logo(String)
        case emoji(String)
        case letter(String)
    }

    public var glyph: Glyph {
        if Self.logoNames.contains(icon) { return .logo(icon) }
        if let emoji = Emoji.single(icon) { return .emoji(emoji) }
        let letter = displayName.first.map { String($0).uppercased() } ?? "?"
        return .letter(letter)
    }

    /// The name, or the command when the name was left empty.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? command : trimmed
    }

    /// A command as it is stored and typed: one line (line breaks become spaces), no spaces around it.
    public static func cleanCommand(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The list as it is used: commands on one line, entries without a command dropped, an icon
    /// that is neither a logo nor an emoji cleared, a repeated id kept only once.
    public static func clean(_ launchers: [Launcher]) -> [Launcher] {
        var seen = Set<UUID>()
        return launchers.compactMap { launcher in
            var launcher = launcher
            launcher.command = cleanCommand(launcher.command)
            guard !launcher.command.isEmpty, seen.insert(launcher.id).inserted else { return nil }
            if !logoNames.contains(launcher.icon) { launcher.icon = Emoji.single(launcher.icon) ?? "" }
            return launcher
        }
    }

    /// Reads the `launchers` value of a settings file: an entry of the wrong shape is skipped
    /// instead of failing the list (or the whole file).
    static func decodeList<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> [Launcher]? {
        guard container.contains(key) else { return nil }
        guard let entries = try? container.decode([Lossy].self, forKey: key) else { return nil }
        return clean(entries.compactMap(\.launcher))
    }

    /// One list entry that decodes to nil instead of throwing.
    private struct Lossy: Decodable {
        let launcher: Launcher?

        private enum Keys: String, CodingKey { case id, name, command, icon }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Keys.self),
                  let command = try? container.decode(String.self, forKey: .command) else {
                launcher = nil
                return
            }
            launcher = Launcher(
                id: (try? container.decode(UUID.self, forKey: .id)) ?? UUID(),
                name: (try? container.decode(String.self, forKey: .name)) ?? "",
                command: command,
                icon: (try? container.decode(String.self, forKey: .icon)) ?? "")
        }
    }
}

/// The one-emoji rule shared by Space icons and launcher icons.
public enum Emoji {
    /// The first character of `text` when it is an emoji (flags, skin tones and joined emoji such
    /// as 👨‍👩‍👧 count as one character), else nil. Digits, `#` and `*` are not emoji here, although
    /// Unicode gives them an emoji form.
    public static func single(_ text: String) -> String? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let scalars = first.unicodeScalars
        guard let lead = scalars.first else { return nil }
        // Shown as an emoji by default, or made one by the variation selector U+FE0F (e.g. ❤️),
        // or a keycap/flag sequence (several scalars starting with an emoji scalar).
        let isEmoji = lead.properties.isEmojiPresentation
            || (lead.properties.isEmoji && scalars.count > 1 && !lead.isASCII)
        return isEmoji ? String(first) : nil
    }
}
