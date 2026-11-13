import Foundation

/// Who is on the other end of an agent-door connection. Decided once, when the connection is
/// accepted, and never changed after.
///
/// - `outside`: any agent (Claude Code or Codex in a terminal, anything else that runs
///   `singularity-mcp`). It sees the Spaces with "agents" switched on, exactly as before plugins
///   could connect.
/// - `plugin`: the connection's process descends from the running program of an approved plugin
///   with the `browser` permission (checked by process ancestry from the program the app itself
///   started at its pinned path; what a client calls itself counts for nothing). It sees only the
///   Spaces switched on for that plugin, whatever their "agents" switch says, and nothing on sites
///   the owner switched the plugin off for.
public enum AgentCaller: Equatable, Sendable {
    case outside
    /// `title`: the manifest's panel title, else its name (`title(of:)`).
    case plugin(id: String, title: String)

    /// Which Spaces this caller gets tools for, in the order given.
    /// - Parameter isOpenForPlugin: for a plugin caller, whether the Space is switched on for it
    ///   (`PluginReach.spaceIsOpen` with its current approval and status). Unused for `outside`.
    public static func spaces(_ all: [Space], caller: AgentCaller, isOpenForPlugin: (Space) -> Bool) -> [Space] {
        switch caller {
        case .outside: return all.filter(\.agentsEnabled)
        case .plugin: return all.filter(isOpenForPlugin)
        }
    }

    /// The client name written to the agent log and shown on approval cards: the plugin's title,
    /// or for an outside agent the name it introduced itself with.
    public func clientName(introducedAs: String) -> String {
        switch self {
        case .outside: return introducedAs
        case .plugin(_, let title): return title
        }
    }

    public var pluginID: String? {
        if case .plugin(let id, _) = self { return id }
        return nil
    }

    /// How a plugin is named to the owner and in the log: its panel's title, else its name.
    public static func title(of manifest: PluginManifest) -> String {
        manifest.panel?.title ?? manifest.name
    }

    // MARK: What a plugin's connection is told

    /// A call in a Space that isn't (or is no longer) switched on for the plugin.
    public static func spaceOff(title: String, space: String) -> String {
        "\(title) is switched off in the “\(space)” Space."
    }

    /// A call about a tab, or an address, on a site the owner switched the plugin off for.
    public static func siteOff(title: String) -> String {
        "\(title) is switched off for this site."
    }

    /// `list_spaces` when no Space is switched on for the plugin.
    public static func noSpaces(title: String) -> String {
        "No Spaces are open to \(title). The user can switch it on for a Space with the button under the chat, or in Settings → Plugins."
    }
}
