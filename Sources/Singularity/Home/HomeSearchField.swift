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
}

/// The home's one row: a text field with the palette's results under it, keyboard driven like
/// `CommandPaletteView` (↑/↓, Return picks the selected row). Esc does nothing: there is nowhere
/// to dismiss to.
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
        let items = HomeSearch.items(for: query, tabID: tabID, state: state)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search or enter an address", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(selectedIndex + 1, max(items.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(selectedIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) { .handled }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            if !items.isEmpty {
                Divider()
                results(items)
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

    private func run(_ items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        let item = items[min(selectedIndex, items.count - 1)]
        query = ""
        PaletteResults.perform(item, mode: HomeSearch.mode(tabID: tabID), state: state)
    }
}
