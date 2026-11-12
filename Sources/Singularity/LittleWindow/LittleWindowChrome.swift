import AppKit
import Observation
import SingularityCore
import SwiftUI
import WebKit

/// The page area of a little window: the web view, with the loading bar and find bar of a tab.
struct LittlePageView: View {
    let little: LittleWindow

    var body: some View {
        LittleWebHost(webView: little.controller.webView)
            .overlay(alignment: .top) { LoadingBar(controller: little.controller) }
            .overlay(alignment: .topTrailing) {
                if little.controller.isFindBarVisible { FindBar(controller: little.controller) }
            }
    }
}

/// Puts the web view into the little window. It is added once, when the window is built, and
/// never taken back: when the page is opened in its Space, the main window's pane takes the view
/// (`HostedView`), and a later SwiftUI update here must not pull it out of that pane.
private struct LittleWebHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}
}

/// The title bar of a little window: the address in the middle, then the Space menu and the
/// "Open in <Space>" button on the right.
///
/// It is a plain AppKit toolbar. Toolbar items are proper title-bar citizens: the bar still drags
/// the window and the controls still take clicks, which hand-made views in the title-bar strip
/// don't get for free (see the split-view notes in CLAUDE.md).
@MainActor
final class LittleWindowChrome: NSObject, NSToolbarDelegate {
    private weak var little: LittleWindow?
    private weak var state: AppState?
    private let address = NSTextField(labelWithString: "")
    private let spaceMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)

    private static let addressItem = NSToolbarItem.Identifier("address")
    private static let spaceItem = NSToolbarItem.Identifier("space")
    private static let openItem = NSToolbarItem.Identifier("open")

    init(little: LittleWindow, state: AppState) {
        self.little = little
        self.state = state
        super.init()

        address.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        address.textColor = .secondaryLabelColor
        address.alignment = .center
        address.lineBreakMode = .byTruncatingMiddle
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true

        spaceMenu.bezelStyle = .toolbar
        spaceMenu.target = self
        spaceMenu.action = #selector(spaceChosen)
        spaceMenu.setAccessibilityLabel("Space to open the page in")

        openButton.bezelStyle = .toolbar
        openButton.target = self
        openButton.action = #selector(openInSpace)
        openButton.toolTip = "⌘O"
        // The window's main action: drawn in the accent colour, like a default button.
        openButton.bezelColor = .controlAccentColor

        let toolbar = NSToolbar(identifier: "little-window")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // The address stays in the middle of the window whatever stands left and right of it.
        toolbar.centeredItemIdentifiers = [Self.addressItem]
        little.window.toolbar = toolbar
        little.window.toolbarStyle = .unifiedCompact

        refresh()
    }

    /// Fills the controls from the page and the Spaces, and asks to be called again when any of
    /// what it read changes. (`withObservationTracking` fires once per registration, so it re-arms.)
    private func refresh() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func update() {
        guard let little, let state else { return }
        let controller = little.controller
        let shown = controller.failedAddress ?? controller.pageURL ?? little.firstURL
        address.stringValue = LittleWindowRules.addressText(shown)
        little.window.title = controller.pageTitle.isEmpty ? address.stringValue : controller.pageTitle

        let chosen = state.space(little.chosenSpaceID) ?? state.space(little.homeSpaceID)
        spaceMenu.removeAllItems()
        for space in state.spaces {
            let item = NSMenuItem(title: space.name, action: nil, keyEquivalent: "")
            item.image = Self.dot(hex: space.colorHex)
            item.representedObject = space.id
            // The Space the page is logged in as. Any other Space loads the page again.
            if space.id == little.homeSpaceID { item.badge = NSMenuItemBadge(string: "current") }
            spaceMenu.menu?.addItem(item)
            if space.id == chosen?.id { spaceMenu.select(item) }
        }
        openButton.title = "Open in \(chosen?.name ?? "Space")"
    }

    /// The Space's colour as a small filled circle, as in the Space rail.
    private static func dot(hex: String) -> NSImage {
        let color = NSColor(Color(hex: hex))
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    @objc private func spaceChosen() {
        guard let little, let id = spaceMenu.selectedItem?.representedObject as? UUID else { return }
        little.chosenSpaceID = id // nothing reloads until the button is pressed
    }

    @objc private func openInSpace() {
        guard let little else { return }
        little.owner?.openInSpace(little)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.addressItem, .flexibleSpace, Self.spaceItem, Self.openItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.addressItem:
            item.view = address
            item.label = "Address"
        case Self.spaceItem:
            item.view = spaceMenu
            item.label = "Space"
        case Self.openItem:
            item.view = openButton
            item.label = "Open in Space"
        default:
            return nil
        }
        return item
    }

    // For tests.
    var addressText: String { address.stringValue }
    var openButtonTitle: String { openButton.title }
    var spaceTitles: [String] { spaceMenu.itemTitles }
    func chooseSpace(_ id: UUID) {
        guard let index = spaceMenu.itemArray.firstIndex(where: { $0.representedObject as? UUID == id }) else { return }
        spaceMenu.selectItem(at: index)
        spaceChosen()
    }
}
