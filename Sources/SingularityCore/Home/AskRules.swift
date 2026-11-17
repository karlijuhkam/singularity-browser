import Foundation

/// The home's "Ask Assistant": text the owner typed, handed to one plugin with the `ask`
/// permission (spec `docs/superpowers/specs/2026-11-17-space-home-design.md`, "Ask Assistant").
/// Pure rules; the app applies them. The text is the owner's own words to their own plugin: the
/// app never logs it.
public enum AskRules {
    /// The most the Ask row hands over, in characters; the row refuses more.
    public static let maxLength = 20_000

    /// Which plugin gets the text: the panel plugin the ⌃⌘J toggle would open (`toggle`) when it
    /// has `ask` and is approved, else the first approved candidate with `ask`, else none (then
    /// there is no Ask row).
    public static func target(toggle: String?, candidates: [(id: String, hasAsk: Bool, approved: Bool)]) -> String? {
        if let toggle, candidates.contains(where: { $0.id == toggle && $0.hasAsk && $0.approved }) { return toggle }
        return candidates.first(where: { $0.hasAsk && $0.approved })?.id
    }

    /// The Space as the plugin may know it: named only when it is switched on for the plugin (the
    /// same test as `front`'s). Anywhere else nil, so the message says nothing about where it came
    /// from: a Space not open to a plugin is unknown to it.
    public static func spaceRef(_ space: Space, enabledSpaces: Set<UUID>) -> FrontTab.SpaceRef? {
        guard enabledSpaces.contains(space.id) else { return nil }
        return .init(slug: space.slug, name: space.name)
    }

    /// The message for the plugin's background, or nil when there is nothing to send (only
    /// whitespace) or the text is longer than `maxLength`. The text goes as typed.
    public static func wireMessage(text: String, space: FrontTab.SpaceRef?) -> PluginWire? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxLength else { return nil }
        let spaceValue: JSONValue = space.map { .object(["slug": .string($0.slug), "name": .string($0.name)]) } ?? .null
        return .ask(text: text, space: spaceValue)
    }
}
