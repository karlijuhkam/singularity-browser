import SingularityCore
import SwiftUI

/// The vertical column of Spaces on the far left. One coloured circle per Space.
struct SpaceRail: View {
    @Environment(AppState.self) private var state
    @State private var spacePendingDeletion: Space?

    var body: some View {
        VStack(spacing: 10) {
            InboxRailButton()

            ForEach(state.spaces) { space in
                SpaceDot(space: space, isSelected: space.id == state.selectedSpaceID,
                         waiting: state.inbox.inbox.count(spaceID: space.id))
                    .onTapGesture { state.userSelectSpace(space.id) }
                    .contextMenu {
                        Button("Edit Space…") { state.showSpaceEditor(spaceID: space.id) }
                        Button("Delete Space…", role: .destructive) { spacePendingDeletion = space }
                            .disabled(state.spaces.count == 1)
                    }
            }

            Button {
                state.showSpaceEditor(spaceID: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Space")

            Spacer()
        }
        .padding(.top, 2)
        .confirmationDialog(
            "Delete “\(spacePendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { spacePendingDeletion != nil }, set: { if !$0 { spacePendingDeletion = nil } }),
            presenting: spacePendingDeletion
        ) { space in
            Button("Delete Space", role: .destructive) { state.deleteSpace(space.id) }
        } message: { _ in
            Text("Its tabs are closed, its cookies and site data are deleted, and its folder is moved to the Trash.")
        }
    }
}

private struct SpaceDot: View {
    let space: Space
    let isSelected: Bool
    /// The Space's inbox entries.
    let waiting: Int

    var body: some View {
        let colour = Color(hex: space.colorHex)
        Text(space.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(colour, in: Circle())
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? colour : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                InboxCountBadge(count: waiting)
                    .offset(x: 2, y: -1)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
            .help(space.name)
    }
}
