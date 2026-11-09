import Foundation
import SingularityCore
import WebKit

/// Puts plugins' page scripts (`page.ts`) into the web views of the Spaces they are switched on in,
/// and takes them out again when that changes.
///
/// How WebKit does it: every web view has a `WKUserContentController` (its "content controller")
/// holding user scripts, which WebKit runs in every page the web view loads from then on, and
/// message handlers, which page scripts call through `webkit.messageHandlers.<name>.postMessage`.
/// Each plugin gets its own content world (`WKContentWorld` "plugin-<id>"): an isolated JavaScript
/// environment over the same DOM, so the page's scripts and other plugins can't see its code,
/// variables or message handler. Per plugin, a content controller holds:
/// - the prelude (`PluginPrelude.source`) at document start, in every frame;
/// - the plugin's transpiled page.ts (`PluginPrelude.wrap`) at document end, in every frame;
/// - a `PluginPageBridge` as message handler "singularityPlugin" in the plugin's world (kept, with
///   its secret, for as long as the plugin's version doesn't change: open pages depend on it).
///
/// WebKit can't remove a single user script, so any change rebuilds a controller's scripts: all
/// removed, then the app's own scripts (the page agent, and the artifact bridge in artifact tabs)
/// added back, then the current plugins' scripts. Pages already open keep what they had until they
/// load again (reload or navigate).
///
/// Which plugins: those the manager would run in that Space (`PluginSelection.forSpace`) whose
/// page script was prepared from exactly the files the manager last scanned. Preparing
/// (`PluginPageCompiler`) runs Bun in the plugin sandbox; the JavaScript is kept in memory only,
/// per plugin and fingerprint. A problem is shown in Settings → Plugins and that plugin's page
/// script is left out.
@MainActor
final class PluginScripts {
    static let handlerName = "singularityPlugin"

    static func world(_ pluginID: String) -> WKContentWorld {
        .world(name: "plugin-\(pluginID)")
    }

    /// One plugin, ready to go into web views.
    struct Prepared {
        let pluginID: String
        let fingerprint: String
        let access: PluginPageAccess
        let configJSON: String
        let javascript: String
    }

    /// A content controller we manage. Popup tabs share their opener's controller, so this is per
    /// controller, not per tab.
    private final class Attached {
        weak var controller: WKUserContentController?
        let spaceID: UUID
        /// The app's own scripts, re-added on every rebuild.
        let baseScripts: [WKUserScript]
        /// "<id>@<fingerprint>" of the plugins installed now; a different list means rebuild.
        var signature: [String] = []
        /// Plugins whose message handlers are registered (to remove them on the next rebuild).
        var pluginIDs: [String] = []
        /// The plugin scripts we added (so they are never mistaken for the app's own).
        var pluginScripts: [WKUserScript] = []
        /// Per plugin: the secret and bridge made for this fingerprint. Reused on rebuilds caused by
        /// other plugins, so pages already open (whose prelude holds the secret) keep working.
        var bridges: [String: (fingerprint: String, secret: String, bridge: PluginPageBridge)] = [:]

        init(controller: WKUserContentController, spaceID: UUID, baseScripts: [WKUserScript]) {
            self.controller = controller
            self.spaceID = spaceID
            self.baseScripts = baseScripts
        }
    }

    private let manager: PluginManager
    private let runtime: URL
    private let hostFolder: URL
    /// Finds the tab a web view belongs to (set by AppState: `WebViewRegistry.tabID(for:)`).
    var tabID: (WKWebView) -> UUID? = { _ in nil }

    private var attached: [ObjectIdentifier: Attached] = [:]
    /// Plugin id -> the fingerprint it was prepared for, the outcome and when. In memory only.
    /// `.changed` outcomes are never kept (the next scan brings a new fingerprint); `.failed` ones
    /// (Bun couldn't run) are tried again after `retryFailedAfter`.
    private var compiled: [String: (fingerprint: String, result: Result<String, PluginPageCompiler.Failure>, at: Date)] = [:]
    private static let retryFailedAfter: TimeInterval = 10
    /// Plugin id -> fingerprint being prepared right now.
    private var compiling: [String: String] = [:]
    private var refreshPending = false

    /// - Parameters:
    ///   - runtime: the bundled Bun (`Contents/Helpers/bun`).
    ///   - hostFolder: `Contents/Resources/plugin-host` (transpile-page.ts, bunfig.toml).
    init(manager: PluginManager, runtime: URL, hostFolder: URL) {
        self.manager = manager
        self.runtime = runtime
        self.hostFolder = hostFolder
    }

    // MARK: - Web views

    /// Starts managing a new web view's content controller (call it after the app's own scripts are
    /// installed: those become the controller's base scripts). A controller already managed (a
    /// popup sharing its opener's) is left as it is.
    func attach(_ controller: WKUserContentController, spaceID: UUID) {
        let key = ObjectIdentifier(controller)
        if let existing = attached[key], existing.controller === controller { return }
        let ours = attached.values.flatMap(\.pluginScripts)
        let base = controller.userScripts.filter { script in !ours.contains { $0 === script } }
        let entry = Attached(controller: controller, spaceID: spaceID, baseScripts: base)
        attached[key] = entry
        update(entry, with: preparedPlugins(for: spaceID))
    }

    // MARK: - Following the plugins

    /// The manager changed something: look again soon (changes come in bursts).
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    private func refresh() {
        let known = Set(manager.plugins.map(\.id))
        compiled = compiled.filter { known.contains($0.key) }
        compiling = compiling.filter { known.contains($0.key) }

        // Prepare every plugin that applies in some Space.
        for plugin in manager.plugins where !applyingSpaces(plugin).isEmpty {
            prepare(plugin)
        }
        attached = attached.filter { $0.value.controller != nil }
        var bySpace: [UUID: [Prepared]] = [:]
        for entry in attached.values {
            let prepared = bySpace[entry.spaceID] ?? preparedPlugins(for: entry.spaceID)
            bySpace[entry.spaceID] = prepared
            update(entry, with: prepared)
        }
    }

    /// The Spaces a plugin's page script belongs in, by `PluginSelection` (its rules, one plugin).
    private func applyingSpaces(_ plugin: InstalledPlugin) -> [UUID] {
        guard plugin.validManifest?.page != nil, let approval = plugin.approval else { return [] }
        return approval.enabledSpaces.filter { space in
            PluginSelection.forSpace(space, approvals: [plugin.id: approval], statuses: [plugin.id: plugin.status],
                                     decisions: [plugin.id: plugin.decision]) == [plugin.id]
        }
    }

    /// The plugins whose page scripts belong in `spaceID`'s web views right now, ready to install.
    private func preparedPlugins(for spaceID: UUID) -> [Prepared] {
        var approvals: [String: PluginApproval] = [:]
        var statuses: [String: PluginStatus] = [:]
        var decisions: [String: PluginLaunch.Decision] = [:]
        for plugin in manager.plugins {
            approvals[plugin.id] = plugin.approval
            statuses[plugin.id] = plugin.status
            decisions[plugin.id] = plugin.decision
        }
        return PluginSelection.forSpace(spaceID, approvals: approvals, statuses: statuses, decisions: decisions)
            .compactMap { id -> Prepared? in
                guard let plugin = manager.plugin(id), let manifest = plugin.validManifest, manifest.page != nil,
                      let approval = plugin.approval, let fingerprint = plugin.snapshot?.fingerprint,
                      let entry = compiled[id], entry.fingerprint == fingerprint,
                      case .success(let javascript) = entry.result,
                      let config = Self.configJSON(pluginID: id, manifest: manifest) else { return nil }
                return Prepared(pluginID: id, fingerprint: fingerprint,
                                access: PluginPageAccess(manifest: manifest, approved: approval.permissions),
                                configJSON: config, javascript: javascript)
            }
    }

    /// Transpiles the plugin's page.ts for its current fingerprint, unless that is done or under way.
    private func prepare(_ plugin: InstalledPlugin) {
        guard let manifest = plugin.validManifest, let page = manifest.page,
              let snapshot = plugin.snapshot else { return }
        let id = plugin.id, fingerprint = snapshot.fingerprint
        if compiling[id] == fingerprint { return }
        if let done = compiled[id], done.fingerprint == fingerprint {
            // Done, unless Bun itself failed a while ago: then try again (on this refresh).
            guard case .failure(.failed) = done.result,
                  Date().timeIntervalSince(done.at) >= Self.retryFailedAfter else { return }
        }
        compiling[id] = fingerprint
        let folder = plugin.folder, expected = snapshot.fileHashes[page.script]
        let runtime = runtime, hostFolder = hostFolder
        Task { @MainActor [weak self] in
            // Reading every byte and running Bun: off the main thread.
            let result = await Task.detached {
                PluginPageCompiler.readVerified(folder: folder, script: page.script, expectedHash: expected)
                    .flatMap { PluginPageCompiler.transpile(source: $0, runtime: runtime, hostFolder: hostFolder) }
            }.value
            guard let self, self.compiling[id] == fingerprint else { return }   // superseded meanwhile
            self.compiling[id] = nil
            if case .failure(.changed) = result {
                // Edited while we read it: not kept; the file watcher brings a new scan (and
                // fingerprint), and the next refresh tries again.
                return
            }
            self.compiled[id] = (fingerprint, result, Date())
            switch result {
            case .success: self.manager.setPageProblem(id, nil)
            case .failure(let failure): self.manager.setPageProblem(id, failure.userMessage)
            }
            self.scheduleRefresh()
        }
    }

    /// Rebuilds a controller when its plugins (or their versions) changed.
    private func update(_ entry: Attached, with plugins: [Prepared]) {
        guard let controller = entry.controller else { return }
        let signature = plugins.map { "\($0.pluginID)@\($0.fingerprint)" }
        guard signature != entry.signature else { return }
        let spaceID = entry.spaceID
        var bridges: [String: (fingerprint: String, secret: String, bridge: PluginPageBridge)] = [:]
        var kept: Set<String> = []
        for prepared in plugins {
            // Same plugin version as before: same secret and the same, still registered, handler, so
            // pages already open (whose prelude holds both) keep working.
            if let old = entry.bridges[prepared.pluginID], old.fingerprint == prepared.fingerprint {
                bridges[prepared.pluginID] = old
                kept.insert(prepared.pluginID)
                continue
            }
            let secret = PluginPageRequest.makeSecret()
            let bridge = PluginPageBridge(pluginID: prepared.pluginID, spaceID: spaceID, access: prepared.access,
                                          secret: secret, manager: manager,
                                          tabID: { [weak self] in self?.tabID($0) })
            bridges[prepared.pluginID] = (prepared.fingerprint, secret, bridge)
        }
        entry.pluginScripts = Self.rebuild(
            controller,
            plugins: plugins.map { ($0, bridges[$0.pluginID]!.secret, bridges[$0.pluginID]!.bridge) },
            baseScripts: entry.baseScripts, previousPluginIDs: entry.pluginIDs, keepHandlers: kept)
        entry.bridges = bridges
        entry.signature = signature
        entry.pluginIDs = plugins.map(\.pluginID)
    }

    /// Replaces a content controller's scripts: removes all user scripts, re-adds `baseScripts` (the
    /// app's own: page agent, artifact bridge), and adds each plugin's prelude (with its secret) and
    /// page script in the plugin's world. Returns the plugin scripts added.
    ///
    /// Message handlers are separate from user scripts (`removeAllUserScripts` leaves them alone),
    /// and an open page talks to the handler that was registered when it loaded: removing it breaks
    /// that page, even if an identical one is added back. So handlers are only changed where needed:
    /// plugins in `keepHandlers` (same version, same bridge) keep theirs; plugins that are gone get
    /// theirs removed; new or changed plugins get their new bridge. The agent's and the artifact
    /// bridge's handlers are never touched.
    static func rebuild(_ controller: WKUserContentController,
                        plugins: [(prepared: Prepared, secret: String, bridge: PluginPageBridge)],
                        baseScripts: [WKUserScript], previousPluginIDs: [String],
                        keepHandlers: Set<String>) -> [WKUserScript] {
        controller.removeAllUserScripts()
        for script in baseScripts { controller.addUserScript(script) }
        let current = Set(plugins.map(\.prepared.pluginID))
        for id in previousPluginIDs where !current.contains(id) {
            controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world(id))
        }
        var added: [WKUserScript] = []
        for (plugin, secret, bridge) in plugins {
            let world = world(plugin.pluginID)
            // forMainFrameOnly: false: login forms also live in frames (each frame is checked on its own).
            let prelude = WKUserScript(source: PluginPrelude.source(configJSON: plugin.configJSON, secret: secret),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
            let code = WKUserScript(source: PluginPrelude.wrap(pluginID: plugin.pluginID, code: plugin.javascript),
                                    injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)
            controller.addUserScript(prelude)
            controller.addUserScript(code)
            added += [prelude, code]
            if keepHandlers.contains(plugin.pluginID) { continue }
            // A new version: replace the old handler (adding a second one with the same name in the
            // same world raises an exception; removing a missing one does nothing).
            controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
            controller.addScriptMessageHandler(bridge, contentWorld: world, name: handlerName)
        }
        return added
    }

    /// The prelude's configuration: the plugin id, the handler name and its site lists as
    /// `SitePattern.BrowserMatcher`s (JSON, which is also valid JavaScript).
    static func configJSON(pluginID: String, manifest: PluginManifest) -> String? {
        struct Config: Encodable {
            let pluginID: String
            let handlerName: String
            let pageSites: [SitePattern.BrowserMatcher]
            let pageAdditions: [SitePattern.BrowserMatcher]
            let fillForms: [SitePattern.BrowserMatcher]
        }
        func matchers(_ texts: [String]) -> [SitePattern.BrowserMatcher] {
            texts.compactMap { try? SitePattern($0).browserMatcher }
        }
        let config = Config(pluginID: pluginID, handlerName: handlerName,
                            pageSites: matchers(manifest.page?.sites ?? []),
                            pageAdditions: matchers(manifest.permissions.pageAdditions),
                            fillForms: matchers(manifest.permissions.fillForms))
        guard let data = try? JSONEncoder().encode(config) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
