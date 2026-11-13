import Foundation

/// Plain-language lines for the approval screen.
public enum PermissionDescriptions {
    /// - Parameters:
    ///   - packages: what Singularity installs from the npm registry at approval (`PluginPackages.check`).
    ///   - hasPageScript: the manifest has a `page` script.
    ///   - hasBackground: the manifest has a `background` program. The network line is about that
    ///     program only, so a page-only plugin gets none.
    ///   - hasPanel: the manifest has a `panel`.
    public static func lines(for permissions: PluginManifest.Permissions, commandPaths: [String: String],
                             packages: PluginPackages.Summary? = nil, hasPageScript: Bool = false,
                             hasBackground: Bool = true, hasPanel: Bool = false) -> [String] {
        func sites(_ list: [String]) -> String {
            list.contains("<all_urls>") ? "on all sites" : "on " + list.joined(separator: ", ")
        }
        var out: [String] = []
        // A page script can read everything on the pages it runs on, including what the user types
        // into them, and it can make the page load things (see AUTHORING.md, "DOM routes"). Say so.
        if !permissions.pageAdditions.isEmpty {
            out.append("Reads and changes pages " + sites(permissions.pageAdditions) + ", including what you type")
        }
        if hasPageScript || !permissions.pageAdditions.isEmpty {
            out.append("Its page script could pass what it reads to other websites; review it before approving")
        }
        if !permissions.fillForms.isEmpty { out.append("Fills login forms " + sites(permissions.fillForms)) }
        for (name, subs) in permissions.commands.sorted(by: { $0.key < $1.key }) {
            // Only the leading words are checked (CommandPolicy.allows): say that the rest is free.
            out.append("Runs \(commandPaths[name] ?? name) (only: \(subs.joined(separator: ", ")) — plus any further arguments)")
        }
        if hasPanel { out.append("Shows its own panel and tab") }
        for name in permissions.programs.sorted() {
            out.append("Keeps \(commandPaths[name] ?? name) running and talks to it. "
                       + "This program is not sandboxed: it uses the internet and acts as you")
        }
        if !permissions.programEnv.isEmpty {
            out.append("Passes these settings to it: " + permissions.programEnv.sorted().joined(separator: ", "))
        }
        if let packages, !packages.packages.isEmpty {
            let n = packages.packages.count
            var line = "Installs \(n) \(n == 1 ? "package" : "packages") from the npm registry"
            if packages.lockedCount > n { line += " (\(packages.lockedCount) with the packages they use)" }
            out.append(line)
        }
        if hasBackground {
            out.append(permissions.network.isEmpty
                       ? (permissions.commands.isEmpty && permissions.programs.isEmpty
                          ? "Its background program never uses the internet"
                          // The background program has no network, but programs it runs (outside its
                          // sandbox) can use it, so don't promise more than that.
                          : "Its background program never uses the internet; the programs it runs can")
                       : "Connects to " + permissions.network.joined(separator: ", "))
        }
        return out
    }
}
