import SingularityCore
import SwiftUI

/// The button at the right end of the address row. Opens the settings of the current tab's site.
/// Hidden for tabs without an http(s) page (terminals, artifacts, empty tabs).
struct SiteSettingsButton: View {
    @Environment(AppState.self) private var state
    @State private var isOpen = false

    var body: some View {
        if let space = state.selectedSpace, let tab = space.selectedTab, let url = tab.url, let site = SiteInfo.site(of: url) {
            // A tint while agents can see this page's console and network, so it is never forgotten.
            let capturing = InspectionRules.isAllowed(space, site: site)
            Button {
                isOpen.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(capturing ? Color.purple : Color.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(capturing ? "Site settings (agents can see this site's console and network)" : "Site settings")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                SiteSettingsPanel(spaceID: space.id, tabID: tab.id, site: site, url: url)
            }
        }
    }
}

/// The owner's choices for one site in one Space: camera, microphone, agents, plugins.
struct SiteSettingsPanel: View {
    @Environment(AppState.self) private var state
    let spaceID: UUID
    let tabID: UUID
    let site: String
    let url: URL
    /// A switch that only applies from the page's next load was changed.
    @State private var needsReload = false

    var body: some View {
        if let space = state.space(spaceID) {
            let settings = space.settings(forSite: site)
            VStack(alignment: .leading, spacing: 12) {
                header

                Divider()
                permissionRow("Camera", symbol: "video", value: settings.camera) { choice in
                    state.updateSiteSettings(spaceID: spaceID, site: site) { $0.camera = choice }
                }
                permissionRow("Microphone", symbol: "mic", value: settings.microphone) { choice in
                    state.updateSiteSettings(spaceID: spaceID, site: site) { $0.microphone = choice }
                }
                Text("Allow skips the question for this site. macOS still asks once for Singularity as a whole.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                agentsSection(space, settings)

                let plugins = pluginsHere(space)
                if !plugins.isEmpty {
                    Divider()
                    Text("Plugins on this site").font(.subheadline.weight(.semibold))
                    ForEach(plugins, id: \.id) { plugin in
                        Toggle(plugin.name, isOn: Binding(
                            get: { !(state.space(spaceID)?.settings(forSite: site).disabledPlugins.contains(plugin.id) ?? false) },
                            set: { on in
                                state.updateSiteSettings(spaceID: spaceID, site: site) {
                                    if on { $0.disabledPlugins.remove(plugin.id) } else { $0.disabledPlugins.insert(plugin.id) }
                                }
                                needsReload = true
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Text("Off stops the plugin's page script on this site and keeps this site's tab from the plugin. It can't give a plugin anything it doesn't already have.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if needsReload {
                    Divider()
                    HStack {
                        Text("Applies when the page loads again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reload") {
                            state.web.existingController(tabID)?.reload()
                            needsReload = false
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            let connection = SiteInfo.connection(of: url)
            Image(systemName: connection == .secure ? "lock.fill" : (connection == .local ? "desktopcomputer" : "exclamationmark.triangle.fill"))
                .foregroundStyle(connection == .notSecure ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(SiteInfo.displayName(ofSite: site))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(connectionText(connection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectionText(_ connection: SiteInfo.Connection?) -> String {
        switch connection {
        case .secure: return "Secure connection"
        case .local: return "Local (on this Mac)"
        case .notSecure, nil: return "Not secure: others on the network can read and change this page"
        }
    }

    private func permissionRow(_ title: String, symbol: String, value: MediaPermission,
                               set: @escaping (MediaPermission) -> Void) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Picker("", selection: Binding(get: { value }, set: set)) {
                Text("Ask").tag(MediaPermission.ask)
                Text("Allow").tag(MediaPermission.allow)
                Text("Block").tag(MediaPermission.block)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func agentsSection(_ space: Space, _ settings: SiteSettings) -> some View {
        let spaceOn = InspectionRules.isSpaceOn(space)
        Toggle(isOn: Binding(
            get: { settings.agentsCanInspect },
            set: { on in
                state.updateSiteSettings(spaceID: spaceID, site: site) { $0.agentsCanInspect = on }
                // Switching on collects from the next load; switching off stops at once.
                if on { needsReload = true }
            }
        )) {
            Label("Let agents see console and network", systemImage: "sparkles")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!spaceOn)
        Text(spaceOn
             ? "Agents in this Space can read this site's console errors and failed requests, with what was sent and what came back. Those can contain passwords and tokens."
             : "Off for the whole “\(space.name)” Space. Turn on “Let agents see console and network” in Edit Space or Settings → Agents first.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Plugins this Space's switch reaches on this page: a page script that runs here, or a plugin
    /// that reaches Spaces (front tab, browser). Switching one off changes something.
    private func pluginsHere(_ space: Space) -> [(id: String, name: String)] {
        state.plugins.plugins.compactMap { plugin in
            guard plugin.status == .approved, let approval = plugin.approval, let manifest = plugin.validManifest,
                  PluginReach.listedForSite(manifest: manifest, approval: approval, space: space, url: url) else { return nil }
            return (plugin.id, manifest.name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
