import Foundation

/// Plain-language lines for the approval screen.
public enum PermissionDescriptions {
    /// `packages`: what Singularity installs from the npm registry at approval (`PluginPackages.check`).
    public static func lines(for permissions: PluginManifest.Permissions, commandPaths: [String: String],
                             packages: PluginPackages.Summary? = nil) -> [String] {
        func sites(_ list: [String]) -> String {
            list.contains("<all_urls>") ? "on all sites" : "on " + list.joined(separator: ", ")
        }
        var out: [String] = []
        if !permissions.pageAdditions.isEmpty { out.append("Adds buttons to pages " + sites(permissions.pageAdditions)) }
        if !permissions.fillForms.isEmpty { out.append("Fills login forms " + sites(permissions.fillForms)) }
        for (name, subs) in permissions.commands.sorted(by: { $0.key < $1.key }) {
            out.append("Runs \(commandPaths[name] ?? name) (only: \(subs.joined(separator: ", ")))")
        }
        if let packages, !packages.packages.isEmpty {
            let n = packages.packages.count
            var line = "Installs \(n) \(n == 1 ? "package" : "packages") from the npm registry"
            if packages.lockedCount > n { line += " (\(packages.lockedCount) with the packages they use)" }
            out.append(line)
        }
        out.append(permissions.network.isEmpty
                   ? (permissions.commands.isEmpty
                      ? "Never uses the internet"
                      // The plugin's own program has no network, but programs it runs (outside its
                      // sandbox) can use it, so don't promise more than that.
                      : "The plugin itself never uses the internet; the programs it runs can")
                   : "Connects to " + permissions.network.joined(separator: ", "))
        return out
    }
}
