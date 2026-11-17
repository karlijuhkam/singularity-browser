import AppKit
import SingularityCore
import SwiftUI

/// The home row's results: the command palette's own (`PaletteResults`), so ⌘T → type → Return
/// lands where the palette's would. An empty field lists nothing (the sections show instead).
@MainActor
enum HomeSearch {
    /// The home tab's own mode; the empty Space's home (no tab) opens things as new tabs.
    static func mode(tabID: UUID?) -> PaletteMode {
        tabID.map { .home(tabID: $0) } ?? .newTab
    }

    static func items(for query: String, tabID: UUID?, state: AppState) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return PaletteResults.items(for: query, mode: mode(tabID: tabID), state: state)
    }

    /// What the row offers after the results: "Ask <Title>" (the plugin with `ask`, see
    /// `AppState.askTarget`), or a line saying the text is too long to hand over. nil for an
    /// empty field or when no plugin may receive asks.
    enum AskOffer: Equatable {
        case ask(title: String)
        case tooLong
    }

    static let askTooLongText = "Too long to send (max 20 000 characters)."
    static let askItemID = "home.ask"

    static func askOffer(for query: String, state: AppState) -> AskOffer? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let id = state.askTarget else { return nil }
        if query.count > AskRules.maxLength { return .tooLong }
        return .ask(title: "Ask \(state.pluginTitle(id))")
    }
}

/// The home's one row: a text field with the palette's results under it, keyboard driven like
/// `CommandPaletteView` (↑/↓, Return picks the selected row), and "Ask <Title>" last (⌘Return
/// picks it directly). Esc does nothing: there is nowhere to dismiss to.
struct HomeSearchField: View {
    @Environment(AppState.self) private var state
    let tabID: UUID?
    /// Whether this home has the keyboard's attention (the selected tab, or the focused pane of a
    /// split). Only then does the field take the focus, so a home pane never takes it from a terminal.
    let takesFocus: Bool
    @Binding var query: String

    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let offer = HomeSearch.askOffer(for: query, state: state)
        let items = rows(offer)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search or enter an address", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    // ⌘Return can arrive here instead of (or as well as) the key handler below:
                    // then it asks too, never runs the first row. A second ask finds the field empty.
                    .onSubmit {
                        if offer != nil, NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                            ask()
                        } else {
                            run(items)
                        }
                    }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(selectedIndex + 1, max(items.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(selectedIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) { .handled }
                    // ⌘Return: Ask, whatever row is selected.
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        if offer == nil { return .ignored }
                        ask()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            if !items.isEmpty || offer == .tooLong {
                Divider()
                if !items.isEmpty { results(items) }
            }
            if offer == .tooLong {
                Text(HomeSearch.askTooLongText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        .onAppear { if takesFocus { focusSoon() } }
        .onChange(of: takesFocus) { if takesFocus { focusSoon() } }
        // The palette (⌘K, the project picker) closed over the home: the row has the keyboard again.
        .onChange(of: state.palette == nil) { if state.palette == nil, takesFocus { focusSoon() } }
        .onChange(of: query) { selectedIndex = 0 }
    }

    /// One turn of the run loop later: the field must be in the window before it can take the focus.
    private func focusSoon() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func results(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                run(items)
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) { proxy.scrollTo(selectedIndex) }
        }
    }

    /// The palette's results, then the Ask row when there is one.
    private func rows(_ offer: HomeSearch.AskOffer?) -> [PaletteItem] {
        var items = HomeSearch.items(for: query, tabID: tabID, state: state)
        if case .ask(let title) = offer {
            items.append(PaletteItem(id: HomeSearch.askItemID, title: title, subtitle: "", hint: "⌘↩",
                                     icon: .symbol("sparkles"), action: .run({})))
        }
        return items
    }

    /// Hands the text to the plugin and clears the field; on a refusal (not running, too long) the
    /// text stays where it is.
    private func ask() {
        if state.askAssistant(query) { query = "" }
    }

    private func run(_ items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        let item = items[min(selectedIndex, items.count - 1)]
        if item.id == HomeSearch.askItemID {
            ask()
            return
        }
        query = ""
        PaletteResults.perform(item, mode: HomeSearch.mode(tabID: tabID), state: state)
    }
}
