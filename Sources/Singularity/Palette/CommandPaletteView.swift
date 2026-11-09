import SingularityCore
import SwiftUI

/// The Cmd+T / Cmd+K overlay: one text field, a ranked result list, keyboard driven.
struct CommandPaletteView: View {
    @Environment(AppState.self) private var state
    let mode: PaletteMode

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = PaletteResults.items(for: query, state: state)

        ZStack(alignment: .top) {
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
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            .padding(.top, 90)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
        .onExitCommand(perform: close)
    }

    private var placeholder: String {
        switch mode {
        case .newTab: "Search tabs, history, commands, or enter a URL"
        case .navigateCurrent: state.selectedTab?.url?.absoluteString ?? "Enter a URL"
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
        let item = items[min(selectedIndex, items.count - 1)]
        close()
        switch item.action {
        case .openURL(let url):
            switch mode {
            case .newTab: state.openInNewTab(url)
            case .navigateCurrent: state.navigateSelectedTab(to: url)
            }
        case .selectTab(let id):
            state.selectTab(id)
        case .run(let action):
            action()
        }
    }

    private func close() {
        state.palette = nil
    }
}

private struct PaletteRow: View {
    @Environment(AppState.self) private var state
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(item.hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .favicon(let host):
            if let slug = state.selectedSpace?.slug, let image = state.favicons.image(slug: slug, host: host) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(.secondary)
        }
    }
}
