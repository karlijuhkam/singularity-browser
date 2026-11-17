import SingularityCore
import SwiftUI

/// The Cmd+T / Cmd+K overlay: one text field, a ranked result list, keyboard driven.
struct CommandPaletteView: View {
    @Environment(AppState.self) private var state
    let mode: PaletteMode
    /// Where it sits in the window (`PaletteLayout`: centred over the page).
    let frame: PaletteLayout.Frame

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = PaletteResults.items(for: query, mode: mode, state: state)

        ZStack(alignment: .topLeading) {
            // Dim the window; clicking outside the palette closes it.
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(placeholder, text: $query)
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
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                if !items.isEmpty {
                    Divider()
                    results(items)
                }
            }
            .frame(width: frame.width)
            // An opaque surface, not a material: a material takes its colour from what is behind
            // it, so over a dark terminal in light mode the rows turned a muddy grey and the grey
            // subtitles all but vanished. White in light mode, near-black in dark.
            // The shadow belongs to the surface only: on the whole view it is also drawn under
            // the rows' text and the selected row, a grey haze inside the palette.
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .padding(.top, 90)
            .padding(.leading, frame.x)
        }
        .onAppear {
            fieldFocused = true
            // After a click on the address (or ⌘L) the field starts with the page's address,
            // selected: typing replaces it, ⌘C copies it, an arrow key lets you edit it.
            guard mode == .navigateCurrent, let address = state.selectedAddress else { return }
            query = address
            // SwiftUI's TextField has no "select all" on macOS 14. Once the field has the keyboard,
            // the window's first responder is its text editor; ask that to select everything.
            // (One turn of the run loop later: the focus and the text arrive after `onAppear`.)
            DispatchQueue.main.async {
                guard state.palette == .navigateCurrent else { return }
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onChange(of: query) { selectedIndex = 0 }
        .onExitCommand(perform: close)
    }

    private var placeholder: String {
        switch mode {
        case .newTab: "Search tabs, history, commands, or enter a URL"
        case .navigateCurrent: "Search or enter a URL"
        case .splitWith: "Choose a tab, or enter a URL, to show beside this one"
        case .newTerminalIn: "New terminal in…"
        case .home: "Search or enter an address"
        }
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
        PaletteResults.perform(items[min(selectedIndex, items.count - 1)], mode: mode, state: state)
    }

    private func close() {
        state.closePalette()
    }
}

/// One result row; also the home's row's results (`HomeSearchField`).
struct PaletteRow: View {
    @Environment(AppState.self) private var state
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            // What Return does, only on the row it would do it to: the same words on every row
            // were noise.
            if isSelected {
                Text(item.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Selected like Spotlight: the accent colour, white text. A faint tint of it over the
        // palette's surface was hard to see and made the grey text on it harder to read.
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Subtitles, the hint and symbols: grey, or a softer white on the selected row.
    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .favicon(let host):
            if let slug = state.selectedSpace?.slug, let image = state.favicons.image(slug: slug, host: host) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "globe").foregroundStyle(secondary)
            }
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(secondary)
        }
    }
}
