import AppKit
import SingularityCore
import SwiftUI

/// What the bottom of a plugin's page area shows, worked out from the app's state (the view draws
/// exactly this, so tests read it here).
struct PluginPageCardsContent: Equatable {
    /// At most this many approval cards are drawn; the rest are only in the inbox.
    static let maxCards = 3

    /// The plugin's waiting approvals, oldest first, at most `maxCards`.
    var cards: [InboxEntry] = []
    /// How many more of its approvals wait (in the inbox only).
    var moreInInbox = 0
    /// The line for a Space the plugin can't see; only when no card is drawn.
    var strip: PluginSpaceStrip?

    /// "and 2 more in the inbox"; nil when there are no more.
    var moreText: String? {
        moreInInbox > 0 ? "and \(moreInInbox) more in the inbox" : nil
    }
}

/// "<Title> can't see <Space>" with "Let it use <Space>": the Space in front is not switched on
/// for a plugin that reaches Spaces. Drawn by the app, so the plugin never learns the Space's name.
struct PluginSpaceStrip: Equatable {
    let pluginID: String
    let spaceID: UUID
    let title: String
    let spaceName: String

    var text: String { "\(title) can't see \(spaceName)" }
    var buttonTitle: String { "Let it use \(spaceName)" }
}

extension AppState {
    /// The bottom of plugin `pluginID`'s page area. `showsStrip`: the plugin's page itself is
    /// shown (not "is starting" or "isn't running"); the strip is about what that page can see.
    func pluginPageCards(_ pluginID: String, showsStrip: Bool = true) -> PluginPageCardsContent {
        var content = PluginPageCardsContent()
        let waiting = inbox.approvals(forPlugin: pluginID)
        content.cards = Array(waiting.prefix(PluginPageCardsContent.maxCards))
        content.moreInInbox = waiting.count - content.cards.count
        guard content.cards.isEmpty, showsStrip,
              plugins.plugin(pluginID)?.validManifest?.reachesSpaces == true,
              pluginFront(pluginID) == .hidden(.spaceOff),
              let space = selectedSpace else { return content }
        content.strip = PluginSpaceStrip(pluginID: pluginID, spaceID: space.id, title: pluginTitle(pluginID),
                                         spaceName: space.name)
        return content
    }

    /// The strip's button: switches that Space on for the plugin (the owner's click, as in the
    /// approval sheet and Settings → Plugins).
    func letPluginUseSpace(_ strip: PluginSpaceStrip) {
        plugins.setEnabled(strip.pluginID, space: strip.spaceID, true)
    }

    /// Plugin `id`'s page is where the owner looks: the app is active, the main window is visible
    /// and key or main (not a little window in front), and the page is shown in it
    /// (`pluginPageIsShown`), with the panel wide enough to be drawn. Its approvals are then
    /// answered in the page instead of opening the inbox panel.
    func pluginPageOnScreen(_ id: String) -> Bool {
        guard NSApp.isActive, let window = mainWindow, window.isVisible,
              window.isKeyWindow || window.isMainWindow else { return false }
        return pluginPageIsShown(id, windowWidth: Double(window.contentView?.bounds.width ?? window.frame.width))
    }

    /// The page is in the main window's content: the welcome flow doesn't cover it, and the panel
    /// shows that plugin (drawn: the window is wide enough, see `MainView`) or a tab of it is among
    /// the selected Space's visible tabs (alone or in its split).
    func pluginPageIsShown(_ id: String, windowWidth: Double) -> Bool {
        guard !welcomeCoversWindow else { return false }
        if shownPanelPlugin == id {
            let sidebar = settings.sidebarHidden ? 8 : sidebarWidth
            if PluginPanelLayout.shownWidth(pluginPanelWidth, windowWidth: windowWidth, sidebarWidth: sidebar) != nil {
                return true
            }
        }
        guard let space = selectedSpace else { return false }
        return space.visibleTabIDs.contains { space.tab($0)?.pluginID == id }
    }
}

/// The page area's layout: the page on top, made shorter (never covered) by the cards or the strip
/// below it. The page keeps its place in the stack whatever is below, so SwiftUI never rebuilds
/// its container when a card comes or goes: the web view, and the chat input in it, keep the
/// keyboard.
struct PluginPageAreaLayout<Page: View>: View {
    let pluginID: String
    /// The plugin's page itself is shown (see `AppState.pluginPageCards`).
    let showsStrip: Bool
    @ViewBuilder let page: () -> Page

    var body: some View {
        VStack(spacing: 0) {
            page()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PluginPageCards(pluginID: pluginID, showsStrip: showsStrip)
        }
    }
}

/// The bottom of a plugin's page area: its waiting approvals as inbox cards (the inbox's own card
/// view, the same buttons and the same 0.5 s click lock, `InboxCenter.answerFromCard`), then
/// "and N more in the inbox"; or, with none, the strip for a Space the plugin can't see.
///
/// Nothing here takes the keyboard: every button is `.focusable(false)` and none has a key
/// equivalent, so Return or Space typed in the chat can never press one. The plugin's page and
/// background are told nothing about these cards and cannot answer them.
struct PluginPageCards: View {
    @Environment(AppState.self) private var state
    let pluginID: String
    let showsStrip: Bool

    var body: some View {
        let content = state.pluginPageCards(pluginID, showsStrip: showsStrip)
        if !content.cards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.cards) { entry in
                    InboxCard(entry: entry, place: InboxPlace(entry, state: state),
                              onAction: { [weak inbox = state.inbox] in inbox?.perform($0) })
                }
                if let more = content.moreText {
                    Text(verbatim: more)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .environment(\.inboxCardButtonsTakeFocus, false)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            // Shown with cards already waiting (the panel opened, the tab selected): the buttons
            // wait a moment, as in the inbox panel.
            .onAppear { state.inbox.pageCardsAppeared() }
        } else if let strip = content.strip {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // The title is the manifest's, the Space name the owner's: shown as written.
                Text(verbatim: strip.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button { state.letPluginUseSpace(strip) } label: { Text(verbatim: strip.buttonTitle) }
                    .controlSize(.small)
                    .lineLimit(1)
                    .focusable(false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
        }
    }
}
