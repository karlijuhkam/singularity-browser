import SingularityCore
import SwiftUI

/// The Space's home: what a new tab (⌘T) opens as, and what an empty Space shows. `tabID` is the
/// home tab, or nil for an empty Space's home (no tab is made until something opens).
///
/// The orb, the row (`HomeSearchField`: the palette's search, inline) and, while the row is
/// empty, the sections (`HomeSections`). Spec: docs/superpowers/specs/2026-11-17-space-home-design.md
struct HomeView: View {
    @Environment(AppState.self) private var state
    let tabID: UUID?

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let space = state.selectedSpace {
                // A new identity per Space and home tab: the typed text and the Recent list never
                // carry over from another Space's home (two empty Spaces show the same view here).
                HomeContent(space: space, tabID: tabID)
                    .id(HomeIdentity(spaceID: space.id, tabID: tabID))
            }
        }
        // In a split, a click here focuses the pane (the click monitor only sees hosted views),
        // as on a plugin's native "isn't running" page.
        .simultaneousGesture(TapGesture().onEnded { if let tabID { state.focusPane(tabID) } })
    }

    private struct HomeIdentity: Hashable {
        let spaceID: UUID
        let tabID: UUID?
    }
}

private struct HomeContent: View {
    @Environment(AppState.self) private var state
    let space: Space
    let tabID: UUID?

    @State private var query = ""
    @State private var recent: [HomeRecentFile] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Like singularity.rroosa.ee: a white orb in dark mode, a black one in light
                // mode. It may stay on screen all day, so it holds still when nobody moves the pointer.
                OrbView(size: 96, stopsWhenIdle: true)
                    .padding(.top, 48)
                    .padding(.bottom, 12)
                Text(verbatim: space.name)
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 20)
                HomeSearchField(tabID: tabID, takesFocus: takesFocus, query: $query)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HomeSections(space: space, homeID: tabID, recent: recent)
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        // On appear and whenever a note or artifact file changed: the Recent list, and the notes
        // the row's results offer (the palette reads those when it opens; the home does here).
        .task(id: state.homeFilesRevision) {
            state.refreshPaletteNotes()
            await loadRecent()
        }
    }

    /// The row takes the keyboard when this home is what the owner is on: the selected tab (the
    /// focused pane of a split), or the empty Space's home.
    private var takesFocus: Bool {
        tabID == nil || space.selectedTabID == tabID
    }

    /// Reads the Recent list off the main actor; a result for a Space no longer shown is dropped.
    private func loadRecent() async {
        let spaceID = space.id
        let notesRoot = state.paths.notesDirectory(space.slug)
        let artifactsRoot = state.paths.artifactsDirectory(space.slug)
        let files = await Task.detached(priority: .utility) {
            HomeRecentLoader.load(notesRoot: notesRoot, artifactsRoot: artifactsRoot)
        }.value
        guard !Task.isCancelled, state.selectedSpaceID == spaceID else { return }
        recent = files
    }
}
