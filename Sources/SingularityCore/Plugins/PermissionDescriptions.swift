import Foundation

/// Plain-language lines for the approval screen.
public enum PermissionDescriptions {
    public static func lines(for permissions: PluginManifest.Permissions, commandPaths: [String: String]) -> [String] {
        func sites(_ list: [String]) -> String {
            list == ["<all_urls>"] ? "on all sites" : "on " + list.joined(separator: ", ")
        }
        var out: [String] = []
        if !permissions.pageAdditions.isEmpty { out.append("Adds buttons to pages " + sites(permissions.pageAdditions)) }
        if !permissions.fillForms.isEmpty { out.append("Fills login forms " + sites(permissions.fillForms)) }
        for (name, subs) in permissions.commands.sorted(by: { $0.key < $1.key }) {
            out.append("Runs \(commandPaths[name] ?? name) (only: \(subs.joined(separator: ", ")))")
        }
        out.append(permissions.network.isEmpty
                   ? "Never uses the internet"
                   : "Connects to " + permissions.network.joined(separator: ", "))
        return out
    }
}
