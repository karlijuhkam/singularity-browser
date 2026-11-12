import Foundation
import SingularityCore

/// One row in the command palette.
struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case favicon(host: String)
    }

    enum Action {
        case openURL(URL)
        case selectTab(UUID)
        case run(@MainActor () -> Void)
    }

    let id: String
    let title: String
    let subtitle: String
    let hint: String
    let icon: Icon
    let action: Action
}

/// Builds the palette's result list for a query: open tabs, this Space's history and commands,
/// ranked by fuzzy score, with a "open URL" or "search" row derived from the text itself.
@MainActor
enum PaletteResults {
    static func items(for query: String, mode: PaletteMode, state: AppState) -> [PaletteItem] {
        guard let space = state.selectedSpace else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Split with…": only things that can go into a pane (other tabs, a new terminal, a URL).
        var splitTarget: UUID?
        if case .splitWith(_, let beside) = mode { splitTarget = beside }

        let tabs = tabItems(space).filter { $0.id != "tab-\(splitTarget?.uuidString ?? "")" }
        let openURLs = Set(space.tabs.compactMap(\.url))
        let history = state.history(for: space.id)
            .filter { !openURLs.contains($0.url) }
            .prefix(500)
            .map(historyItem)
        let commands: [PaletteItem]
        if case .splitWith(let edge, let beside) = mode {
            commands = [PaletteItem(id: "cmd-split-terminal", title: "New Terminal", subtitle: "", hint: "Command",
                                    icon: .symbol("terminal"), action: .run { state.openTerminalInSplit(edge: edge, beside: beside) })]
        } else {
            commands = commandItems(state: state, space: space)
        }
        let openArtifacts = Set(space.tabs.compactMap(\.artifactPath))
        let artifacts = (splitTarget != nil ? [] : state.artifacts.host(space.id)?.pages ?? [])
            .filter { !openArtifacts.contains($0) }
            .map { path in
                PaletteItem(id: "artifact-\(path)", title: (path as NSString).lastPathComponent, subtitle: "artifacts/\(path)",
                            hint: "Artifact", icon: .symbol("doc.richtext"), action: .run { state.openArtifact(path) })
            }

        if trimmed.isEmpty {
            return Array(tabs.prefix(8)) + commands
        }

        // Fuzzy subsequence matching accepts almost anything against a long URL, so require
        // roughly two points per typed character (see FuzzyMatcher's scoring).
        let threshold = trimmed.count * 200 - 100
        func ranked(_ items: [PaletteItem], bonus: Int) -> [(PaletteItem, Int)] {
            items.compactMap { item in
                guard let score = FuzzyMatcher.bestScore(trimmed, in: [item.title, item.subtitle]), score >= threshold else { return nil }
                return (item, score + bonus)
            }
        }
        let matches = (ranked(tabs, bonus: 300) + ranked(commands, bonus: 200) + ranked(artifacts, bonus: 100) + ranked(Array(history), bonus: 0))
            .sorted { $0.1 > $1.1 }
            .prefix(30)
            .map(\.0)

        switch URLInput.classify(trimmed, searchTemplate: state.settings.searchTemplate) {
        case .url(let url):
            let open = PaletteItem(id: "open-url", title: url.absoluteString, subtitle: "", hint: "Open",
                                   icon: .symbol("arrow.up.forward.square"), action: .openURL(url))
            return [open] + matches
        case .search(let url):
            let search = PaletteItem(id: "search", title: trimmed, subtitle: "Search \(state.settings.searchEngineName)", hint: "Search",
                                     icon: .symbol("magnifyingglass"), action: .openURL(url))
            return matches + [search]
        case nil:
            return matches
        }
    }

    /// The user chose `item` (Return or a click): closes the palette, then does it.
    static func perform(_ item: PaletteItem, mode: PaletteMode, state: AppState) {
        state.palette = nil
        // The user chose something: the welcome flow must not stay over it. (`showPalette` closed
        // the flow already; this keeps it true for the URL actions, which `openInNewTab` no longer does.)
        state.closeWelcome()
        switch item.action {
        case .openURL(let url):
            switch mode {
            case .newTab: state.openInNewTab(url)
            case .navigateCurrent: state.navigateSelectedTab(to: url)
            case .splitWith(let edge, let beside): state.openInSplit(url, edge: edge, beside: beside)
            }
        case .selectTab(let id):
            if case .splitWith(let edge, let beside) = mode {
                state.splitTab(id, beside: beside, edge: edge)
            } else {
                state.selectTab(id)
            }
        case .run(let action):
            action()
        }
    }

    private static func tabItems(_ space: Space) -> [PaletteItem] {
        space.tabsInSidebarOrder.map { tab in
            let icon: PaletteItem.Icon = if tab.isTerminal {
                .symbol("terminal")
            } else if tab.isArtifact {
                .symbol("doc.richtext")
            } else {
                tab.url?.host().map { .favicon(host: $0) } ?? .symbol("globe")
            }
            return PaletteItem(
                id: "tab-\(tab.id)",
                title: tab.displayTitle,
                subtitle: tab.url?.absoluteString ?? tab.workingDirectory ?? tab.artifactPath.map { "artifacts/\($0)" } ?? "",
                hint: tab.id == space.selectedTabID ? "Current Tab" : "Switch to Tab",
                icon: icon,
                action: .selectTab(tab.id)
            )
        }
    }

    private static func historyItem(_ entry: HistoryEntry) -> PaletteItem {
        PaletteItem(
            id: "history-\(entry.url.absoluteString)",
            title: entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
            subtitle: entry.url.absoluteString,
            hint: "History",
            icon: entry.url.host().map { .favicon(host: $0) } ?? .symbol("clock"),
            action: .openURL(entry.url)
        )
    }

    private static func commandItems(state: AppState, space: Space) -> [PaletteItem] {
        func command(_ id: String, _ title: String, _ symbol: String, _ run: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd-\(id)", title: title, subtitle: "", hint: "Command", icon: .symbol(symbol), action: .run(run))
        }

        var items: [PaletteItem] = []
        // A quiet notice instead of a sheet: new, changed or broken plugins wait here until the
        // user chooses to look (an automatic approval sheet would invite reflex approval).
        let needReview = state.plugins.plugins.filter(\.needsReview).count
        if let title = PluginStatusText.reviewTitle(count: needReview) {
            items.append(command("plugins-review", title, "puzzlepiece.extension") { state.showPluginSettings() })
        }
        for other in state.spaces where other.id != space.id {
            items.append(command("space-\(other.id)", "Switch to Space: \(other.name)", "square.stack") {
                state.userSelectSpace(other.id)
            })
        }
        items.append(command("new-terminal", "New Terminal", "terminal") { state.openTerminal() })
        items.append(command("show-inbox", "Show Inbox", "tray") { state.inbox.showPanel(takingFocus: true) })
        if let tab = space.selectedTab {
            if tab.folderID == nil {
                items.append(command("pin", tab.isPinned ? "Unpin Current Tab" : "Pin Current Tab", "pin") {
                    state.togglePin(tab.id)
                })
            }
            if !tab.isTerminal {
                items.append(command("reload", "Reload Page", "arrow.clockwise") {
                    state.web.existingController(tab.id)?.reload()
                })
            }
            items.append(command("close", "Close Current Tab", "xmark") {
                state.closeTab(tab.id)
            })
        }
        if let tab = space.selectedTab {
            items.append(command("split-right", "Split Right with…", "rectangle.split.2x1") {
                state.showSplitPalette(.right, beside: tab.id)
            })
            items.append(command("split-down", "Split Down with…", "rectangle.split.1x2") {
                state.showSplitPalette(.bottom, beside: tab.id)
            })
            if space.splitGroup(containing: tab.id) != nil {
                items.append(command("split-remove", "Remove Current Tab from Split", "rectangle") {
                    state.removeFromSplit(tab.id)
                })
            }
        }
        items.append(command("new-folder", "New Folder…", "folder.badge.plus") { state.promptNewFolder() })
        items.append(command("artifacts-folder", "Show Artifacts Folder in Finder", "folder") { state.revealArtifactsFolder() })
        items.append(command("agent-log", "Show Agent Log File", "sparkles") { state.revealAgentLog() })
        items.append(command("new-space", "New Space…", "plus.square.on.square") {
            state.showSpaceEditor(spaceID: nil)
        })
        items.append(command("edit-space", "Edit Space “\(space.name)”…", "slider.horizontal.3") {
            state.showSpaceEditor(spaceID: space.id)
        })
        items.append(command("welcome", "Welcome to Singularity…", "sparkle") { state.showWelcome() })
        #if DEBUG
        items.append(command("plugins-test-op", "Plugins: Test 1Password CLI", "key") { PluginDebugCommands.testOnePasswordCLI() })
        #endif
        return items
    }
}
