import AppKit
import SingularityCore
import SwiftUI
import WebKit

// MARK: - The approval sheet

/// What the owner sees before an extension is installed or updated: where it came from, what it
/// asks for in plain words, what WebKit can't do for it, and the Spaces it runs in. Install is not
/// a default button (Return must not install). Text from the extension is shown with
/// `Text(verbatim:)`: no Markdown, no links.
struct ExtensionApprovalSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let pending: ExtensionCenter.PendingExtension
    @State private var spaces: Set<UUID> = []
    @State private var choicesSet = false
    @State private var installing = false

    private var ext: WKWebExtension { pending.webExtension }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let old = pending.replaces {
                        Text(verbatim: "Replaces version \(old.version) that is installed now. Its Spaces and settings stay.")
                            .foregroundStyle(.secondary)
                    }
                    permissions
                    problems
                    spaceSwitches
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                if installing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    state.extensions.cancel(pending)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(pending.replaces == nil ? "Install" : "Update") {
                    installing = true
                    Task {
                        await state.extensions.approve(pending, spaces: spaces)
                        dismiss()
                    }
                }
                .disabled(installing)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .onAppear {
            guard !choicesSet else { return }
            choicesSet = true
            if let old = pending.replaces {
                spaces = old.enabledSpaces
            } else if let space = pending.fromSpace ?? state.selectedSpaceID {
                spaces = [space]
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let icon = ext.icon(for: CGSize(width: 48, height: 48)) {
                Image(nsImage: icon).resizable().frame(width: 48, height: 48)
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 36)).frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: PluginText.line(ext.displayName ?? pending.extensionID, max: 80)).font(.title2.bold())
                Text(verbatim: "Version " + PluginText.line(ext.displayVersion ?? ext.version ?? "?", max: 40)
                     + " · " + (pending.source == .store ? "Chrome Web Store" : "a file you chose"))
                    .foregroundStyle(.secondary)
                if let text = ext.displayDescription, !text.isEmpty {
                    Text(verbatim: PluginText.block(text, max: 400)).font(.callout)
                }
            }
        }
    }

    private var siteLines: [String] {
        let patterns = ext.allRequestedMatchPatterns.map(\.string)
        return Array(Set(patterns.map(ExtensionWording.sites))).sorted()
    }

    @ViewBuilder
    private var permissions: some View {
        let names = ext.requestedPermissions.map(\.rawValue).map(ExtensionWording.permission).sorted()
        let patterns = ext.allRequestedMatchPatterns.map(\.string)
        VStack(alignment: .leading, spacing: 6) {
            Text("It will be able to").font(.headline)
            if ExtensionWording.reachesEverySite(patterns) {
                Label("Read and change everything on every site you open in the Spaces below, passwords you type included.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if !patterns.isEmpty {
                Label("Read and change these sites: " + siteLines.joined(separator: ", "), systemImage: "globe")
            }
            ForEach(names, id: \.self) { line in
                Label { Text(verbatim: line) } icon: { Image(systemName: "checkmark.circle") }
            }
            if names.isEmpty && patterns.isEmpty {
                Text("Nothing beyond its own pages.").foregroundStyle(.secondary)
            }
            if !ext.optionalPermissions.isEmpty || !ext.optionalPermissionMatchPatterns.isEmpty {
                Text("It may ask for more later; Singularity will ask you each time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        let errors = ext.errors.map(\.localizedDescription)
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Parts of it may not work in Singularity", systemImage: "exclamationmark.circle")
                    .font(.headline)
                ForEach(Array(errors.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: PluginText.line(line, max: 300)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var spaceSwitches: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs in").font(.headline)
            ForEach(state.spaces) { space in
                Toggle(isOn: Binding(
                    get: { spaces.contains(space.id) },
                    set: { on in if on { spaces.insert(space.id) } else { spaces.remove(space.id) } }
                )) {
                    Text(verbatim: space.name)
                }
                .toggleStyle(.checkbox)
            }
            Text("Each Space has its own copy: its settings and data stay in that Space, and it never sees another Space's tabs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Address row

/// The extensions' buttons for the web page on screen (icon, badge), and on a Chrome Web Store
/// detail page our own "Add to Singularity" button. Up to three buttons, the rest in a menu.
struct ExtensionToolbar: View {
    @Environment(AppState.self) private var state
    static let maxButtons = 3

    var body: some View {
        if let space = state.selectedSpace, let tab = space.selectedTab, ExtensionCenter.isWebTab(tab) {
            let items = state.extensions.toolbarItems(spaceID: space.id, tabID: tab.id)
            HStack(spacing: 0) {
                if let storeID = ChromeWebStore.extensionID(from: tab.url) {
                    StoreAddButton(id: storeID, spaceID: space.id)
                }
                ForEach(items.prefix(Self.maxButtons)) { item in
                    ExtensionActionButton(item: item, spaceID: space.id, tabID: tab.id)
                        .frame(width: 24, height: 30)
                }
                if items.count > Self.maxButtons {
                    Menu {
                        ForEach(items.dropFirst(Self.maxButtons)) { item in
                            Button(item.name) {
                                // From a menu there is no button to hang a popup on: the address row's
                                // last button is used.
                                state.extensions.performActionFromMenu(item.id, spaceID: space.id, tabID: tab.id)
                            }
                        }
                    } label: {
                        Image(systemName: "puzzlepiece.extension")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 30)
                    .help("More extensions")
                }
            }
        }
    }
}

private struct StoreAddButton: View {
    @Environment(AppState.self) private var state
    let id: String
    let spaceID: UUID

    var body: some View {
        let installed = state.extensions.records[id] != nil
        Button {
            state.extensions.addFromStore(id, fromSpace: spaceID, isUpdateCheck: installed)
        } label: {
            if state.extensions.downloading.contains(id) {
                ProgressView().controlSize(.small).frame(width: 26, height: 30)
            } else {
                Image(systemName: installed ? "checkmark.seal" : "plus.app")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(installed ? "Installed in Singularity (click to check for an update)" : "Add to Singularity")
        .accessibilityLabel("Add to Singularity")
    }
}

/// An extension's button: an AppKit button, because the popup is an `NSPopover` that needs a view
/// to hang from.
private struct ExtensionActionButton: NSViewRepresentable {
    @Environment(AppState.self) private var state
    let item: ExtensionCenter.ToolbarItem
    let spaceID: UUID
    let tabID: UUID

    func makeNSView(context: Context) -> NSButton {
        let button = BadgeButton(frame: NSRect(x: 0, y: 0, width: 24, height: 30))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.image = item.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        button.image?.size = NSSize(width: 16, height: 16)
        button.toolTip = item.name
        button.setAccessibilityLabel(item.name)
        button.isEnabled = item.isEnabled
        (button as? BadgeButton)?.badge = item.badge
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ExtensionActionButton
        init(parent: ExtensionActionButton) { self.parent = parent }

        @objc func clicked(_ sender: NSButton) {
            parent.state.extensions.performAction(parent.item.id, spaceID: parent.spaceID, tabID: parent.tabID, anchor: sender)
        }
    }
}

/// A button that draws a small badge (an extension's badge text) over its top-right corner.
private final class BadgeButton: NSButton {
    var badge: String = "" { didSet { if badge != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !badge.isEmpty else { return }
        let text = String(badge.prefix(4)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(x: bounds.maxX - size.width - 5, y: bounds.midY - 13, width: size.width + 4, height: size.height + 1)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: rect.minX + 2, y: rect.minY + 0.5), withAttributes: attributes)
    }
}

// MARK: - Site settings

/// "Extensions on this site": a switch per extension that runs in this Space.
struct ExtensionSiteSection: View {
    @Environment(AppState.self) private var state
    let spaceID: UUID
    let site: String
    @Binding var needsReload: Bool

    var body: some View {
        let ids = state.extensions.loadedIDs(in: spaceID)
        if !ids.isEmpty {
            Divider()
            Text("Extensions on this site").font(.subheadline.weight(.semibold))
            ForEach(ids, id: \.self) { id in
                Toggle(isOn: Binding(
                    get: { !(state.space(spaceID)?.settings(forSite: site).disabledExtensions.contains(id) ?? false) },
                    set: { on in
                        state.updateSiteSettings(spaceID: spaceID, site: site) {
                            if on { $0.disabledExtensions.remove(id) } else { $0.disabledExtensions.insert(id) }
                        }
                        needsReload = true
                    }
                )) {
                    Text(verbatim: state.extensions.records[id]?.name ?? id)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }
}
