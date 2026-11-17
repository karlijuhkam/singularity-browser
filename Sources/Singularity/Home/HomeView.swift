import SingularityCore
import SwiftUI

/// The Space's home: what a new tab (⌘T) opens as, and what an empty Space shows. `tabID` is the
/// home tab, or nil for an empty Space's home (no tab is made until something opens).
///
/// For now the orb and the Space's name; the row and the sections come next (see the spec,
/// docs/superpowers/specs/2026-11-17-space-home-design.md).
struct HomeView: View {
    @Environment(AppState.self) private var state
    let tabID: UUID?

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            VStack(spacing: 8) {
                // Like singularity.rroosa.ee: a white orb in dark mode, a black one in light mode.
                // It may stay on screen all day, so it holds still when nobody moves the pointer.
                OrbView(size: 96, stopsWhenIdle: true)
                    .padding(.bottom, 8)
                Text(state.selectedSpace?.name ?? "")
                    .font(.title2.weight(.semibold))
                Text(tabID == nil ? "Press ⌘T to open a tab, or ⌥⌘T for a terminal" : "Home")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
