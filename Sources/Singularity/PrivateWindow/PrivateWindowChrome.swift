import AppKit
import Observation
import SingularityCore
import SwiftUI
import WebKit

/// The page area of a private window: the web view with the loading bar and find bar of a tab,
/// and, in a new empty window, a note on what the window keeps.
struct PrivatePageView: View {
    let entry: PrivateWindow

    var body: some View {
        PrivateWebHost(webView: entry.controller.webView)
            .overlay(alignment: .top) { LoadingBar(controller: entry.controller) }
            .overlay(alignment: .topTrailing) {
                if entry.controller.isFindBarVisible { FindBar(controller: entry.controller) }
            }
            .overlay {
                if entry.showsNote, entry.controller.pageURL == nil, !entry.controller.isLoading {
                    PrivateNote()
                }
            }
    }
}

/// What a new private window says before its first page.
private struct PrivateNote: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Private window")
                .font(.title2.weight(.semibold))
            Text("Pages you open here keep no history, and their cookies and site data live only in memory until the last private window is closed. Downloads stay in your Downloads folder. Agents, plugins and extensions can't see this window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Puts the web view into the window once (as `LittleWebHost` does).
private struct PrivateWebHost: NSViewRepresentable {
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

/// The title bar of a private window: Back, Forward and Reload, the address field in the middle,
/// and the "Private" mark at the right. A plain AppKit toolbar, like the little window's: toolbar
/// items take clicks and the bar still drags the window.
@MainActor
final class PrivateWindowChrome: NSObject, NSToolbarDelegate, NSTextFieldDelegate {
    private weak var entry: PrivateWindow?
    private weak var state: AppState?
    private let address = NSTextField(string: "")
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private let mark = NSButton(title: "Private", target: nil, action: nil)

    private static let navigationItem = NSToolbarItem.Identifier("navigation")
    private static let addressItem = NSToolbarItem.Identifier("address")
    private static let markItem = NSToolbarItem.Identifier("private")

    init(entry: PrivateWindow, state: AppState?) {
        self.entry = entry
        self.state = state
        super.init()

        address.placeholderString = "Search or enter address"
        address.font = .systemFont(ofSize: NSFont.systemFontSize)
        address.bezelStyle = .roundedBezel
        address.lineBreakMode = .byTruncatingTail
        address.usesSingleLineMode = true
        address.cell?.isScrollable = true
        address.cell?.wraps = false
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        // Return loads; leaving the field (a click on the page) does not.
        (address.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        address.setAccessibilityLabel("Address")
        address.isBezeled = true
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        address.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
        // As wide as the window allows, up to 560 points.
        let preferred = address.widthAnchor.constraint(equalToConstant: 560)
        preferred.priority = .defaultLow
        preferred.isActive = true

        Self.style(back, symbol: "chevron.left", label: "Back")
        Self.style(forward, symbol: "chevron.right", label: "Forward")
        Self.style(reload, symbol: "arrow.clockwise", label: "Reload")
        back.target = self
        back.action = #selector(goBack)
        forward.target = self
        forward.action = #selector(goForward)
        reload.target = self
        reload.action = #selector(reloadPage)

        // A mark, not a control: it only says which kind of window this is.
        mark.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        mark.imagePosition = .imageLeading
        mark.bezelStyle = .toolbar
        mark.isBordered = false
        mark.contentTintColor = .secondaryLabelColor
        mark.refusesFirstResponder = true
        mark.setButtonType(.momentaryChange)
        mark.toolTip = "Nothing from this window is kept after the last private window is closed"

        let toolbar = NSToolbar(identifier: "private-window")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.addressItem]
        entry.window.toolbar = toolbar
        entry.window.toolbarStyle = .unified

        refresh()
    }

    private static func style(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// Follows the page (address, title, Back/Forward) and re-arms itself.
    private func refresh() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func update() {
        guard let entry else { return }
        let controller = entry.controller
        let shown = controller.failedAddress ?? controller.pageURL
        // Never under the owner's typing.
        if address.currentEditor() == nil {
            address.stringValue = PrivateWindowRules.fieldText(shown)
        }
        back.isEnabled = controller.canGoBack
        forward.isEnabled = controller.canGoForward
        reload.isEnabled = shown != nil
        let title = controller.pageTitle.isEmpty ? (shown?.host() ?? "") : controller.pageTitle
        entry.window.title = title.isEmpty ? "Private Window" : "\(title) — Private"
    }

    /// ⌘L and a new empty window: the cursor in the address field, its text selected.
    func focusAddress() {
        guard let window = entry?.window else { return }
        window.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    /// Loads what was typed: an address, or a search with the owner's search engine.
    func load(typed text: String) {
        guard let entry else { return }
        let template = state?.settings.searchTemplate ?? URLInput.defaultSearchTemplate
        guard let url = PrivateWindowRules.destination(typed: text, searchTemplate: template) else { return }
        entry.controller.load(url)
        entry.window.makeFirstResponder(entry.controller.webView)
        address.stringValue = PrivateWindowRules.fieldText(url)
    }

    @objc private func addressEntered() {
        load(typed: address.stringValue)
    }

    /// Esc in the field puts the page's address back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let entry else { return false }
        let shown = entry.controller.failedAddress ?? entry.controller.pageURL
        address.stringValue = PrivateWindowRules.fieldText(shown)
        address.currentEditor()?.selectAll(nil)
        return true
    }

    @objc private func goBack() { entry?.controller.goBack() }
    @objc private func goForward() { entry?.controller.goForward() }
    @objc private func reloadPage() { entry?.controller.reload() }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigationItem, .flexibleSpace, Self.addressItem, .flexibleSpace, Self.markItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.navigationItem:
            let row = NSStackView(views: [back, forward, reload])
            row.spacing = 2
            item.view = row
            item.label = "Navigation"
        case Self.addressItem:
            item.view = address
            item.label = "Address"
        case Self.markItem:
            item.view = mark
            item.label = "Private"
        default:
            return nil
        }
        return item
    }

    // For tests.
    var addressText: String { address.stringValue }
    var markTitle: String { mark.title }
}
