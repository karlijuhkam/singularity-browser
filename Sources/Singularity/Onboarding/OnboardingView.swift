import SingularityCore
import SwiftUI

/// The welcome flow (spec: docs/superpowers/specs/2026-11-11-onboarding-design.md). It covers the
/// whole window on a brand-new install, and again when chosen from the app menu or the palette.
///
/// Layout: the live orb on the left (large on step 1, smaller after), the step on the right. The
/// step column has one fixed height for all four steps: the title and text pinned at the top, the
/// footer (step dots, a quiet "Skip setup" = Esc, Back, the step's secondary button and its primary
/// button = Return) pinned at the bottom, the step's controls in between (scrolling only when they
/// don't fit). So nothing moves between steps except the orb's size. Sizes grow with the window
/// (`OnboardingLayout`); in a narrow window the orb is left out rather than squeezing the controls.
///
/// All state lives in `AppState` (`onboarding`, `advanceWelcome`, …) except step 2's draft,
/// which only Continue writes back: Back, Skip, Skip setup and Esc throw it away.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = SpaceDraft()
    /// Bundled plugins being copied (step 4). While this is not empty, the buttons that leave the
    /// step are off, so the approval sheet that follows can't be lost.
    @State private var addingPlugins: Set<String> = []
    /// Step 3's agent rows. Held here so Back and forward again don't lose what was found.
    @State private var connector: AgentConnector

    /// `connector` is for tests (a fake shell); the app uses the one pointing at this copy.
    init(connector: AgentConnector? = nil) {
        _connector = State(initialValue: connector ?? AgentConnector(launcher: AgentConnector.thisAppLauncher))
    }

    /// The flow as `AppState` has it. (The fallback only matters for a frame while it closes.)
    private var flow: OnboardingFlow { state.onboarding ?? OnboardingFlow() }

    var body: some View {
        // GeometryReader hands us the space the window offers, which sets every size below.
        GeometryReader { geometry in
            let layout = OnboardingLayout(size: geometry.size)
            HStack(spacing: layout.gap) {
                if layout.showsOrb {
                    // The orb's centre stays put; only its size changes between steps.
                    OrbView(size: flow.step == .welcome ? layout.largeOrb : layout.smallOrb)
                        .frame(width: layout.orbSideWidth)
                }
                column(layout)
                    .frame(width: layout.columnWidth, height: layout.columnHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Room for the traffic lights (the window has no visible title bar) and some air below.
        .padding(.top, OnboardingLayout.topPadding)
        .padding(.bottom, OnboardingLayout.bottomPadding)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: flow.step)
        .onChange(of: flow.step, initial: true) { _, step in
            // Entering step 2 (from step 1, from Back on step 3, or reopened from the menu)
            // always starts from the Space as it is saved.
            if step == .space, let space = state.welcomeSpace { draft = SpaceDraft(space) }
        }
    }

    private func column(_ layout: OnboardingLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(step: flow.step, titleSize: layout.titleSize, textSize: layout.textSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A new identity per step, so the switch crossfades instead of morphing.
                .id(flow.step)
                .transition(.opacity)

            ScrollView {
                stepControls
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                    .id(flow.step)
                    .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Takes whatever space is left, so the footer sits at the column's bottom.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var stepControls: some View {
        switch flow.step {
        case .welcome: EmptyView()
        case .space: SpaceStep(draft: $draft)
        case .agents: AgentsStep(connector: connector)
        case .plugins: PluginsStep(adding: $addingPlugins)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            StepDots(steps: flow.visibleSteps, current: flow.step)
            // Leaves the whole flow from any step. Esc does the same (the cancel shortcut).
            Button("Skip setup") { state.closeWelcome() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .padding(.leading, 14)
            Spacer(minLength: 12)
            Group {
                if flow.canGoBack {
                    Button("Back") { state.welcomeBack() }
                        .disabled(!addingPlugins.isEmpty)
                }
                secondaryButton
            }
            .buttonStyle(.bordered)
            primaryButton
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch flow.step {
        case .welcome:
            if FileManager.default.fileExists(atPath: ArcImport.defaultFile.path) {
                // The import moves the flow on to step 3 itself (`AppState.importArcSpaces`);
                // cancelling the sheet stays here.
                Button("Import from Arc…") { state.isImportingFromArc = true }
            }
        case .space, .agents:
            // Next step without applying this one.
            Button("Skip") { state.advanceWelcome() }
        case .plugins:
            EmptyView()
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch flow.step {
        case .welcome:
            Button("Get started") { state.advanceWelcome() }
        case .space:
            Button("Continue") {
                state.applyWelcomeSpace(name: draft.trimmedName, colorHex: draft.colorHex,
                                        workingDirectory: draft.workingDirectory)
                // After it: the placeholder may just have been given its new slug and folder.
                if let space = state.welcomeSpace { state.setSpaceIcon(draft.icon, spaceID: space.id) }
                state.advanceWelcome()
            }
            .disabled(draft.trimmedName.isEmpty)
        case .agents:
            Button("Continue") { state.advanceWelcome() }
        case .plugins:
            Button("Start browsing") { state.advanceWelcome() }
                .disabled(!addingPlugins.isEmpty)
        }
    }
}

/// Every size in the flow, from the space the window offers. `t` runs from 0 at the app's
/// minimum window (820×520) to 1 at about 1500×1000 and up; sizes are interpolated between a
/// small and a large value. Below about 770 points of width the orb is left out.
struct OnboardingLayout {
    static let topPadding: CGFloat = 44
    static let bottomPadding: CGFloat = 32
    private static let sideMargin: CGFloat = 32

    let showsOrb: Bool
    let largeOrb: CGFloat
    let smallOrb: CGFloat
    let orbSideWidth: CGFloat
    let gap: CGFloat
    let columnWidth: CGFloat
    let columnHeight: CGFloat
    let titleSize: CGFloat
    let textSize: CGFloat

    /// `size` is what the view gets inside the top and bottom padding.
    init(size: CGSize) {
        let minHeight = 520 - Self.topPadding - Self.bottomPadding
        let tWidth = (size.width - 820) / 680
        let tHeight = (size.height - minHeight) / 480
        let t = min(max(min(tWidth, tHeight), 0), 1)
        func lerp(_ small: CGFloat, _ large: CGFloat) -> CGFloat { (small + (large - small) * t).rounded() }

        largeOrb = lerp(220, 340)
        smallOrb = lerp(150, 240)
        titleSize = lerp(30, 36)
        textSize = t < 0.5 ? 15 : 16

        // The orb's side holds the large orb with some air; the column takes what is left, up to its width.
        let orbSide = largeOrb + lerp(40, 80)
        let orbGap = lerp(24, 72)
        let wanted = lerp(440, 520)
        showsOrb = size.width - orbSide - orbGap - 2 * Self.sideMargin >= 420
        orbSideWidth = showsOrb ? orbSide : 0
        gap = showsOrb ? orbGap : 0
        columnWidth = max(0, min(wanted, size.width - orbSideWidth - gap - 2 * Self.sideMargin))
        // Tall enough for the tallest step (agents: two agent rows and a Space switch), never
        // taller than the window; the middle part scrolls when a step needs more.
        columnHeight = max(0, min(lerp(440, 580), size.height))
    }
}

/// A step's title and its one or two sentences (the spec's wording).
private struct StepHeader: View {
    let step: OnboardingStep
    let titleSize: CGFloat
    let textSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A `String` value (not a literal) is shown as-is, never read as Markdown.
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: textSize))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Singularity"
        case .space: "Your first Space"
        case .agents: "Connect your agent"
        case .plugins: "Plugins"
        }
    }

    private var text: String {
        switch step {
        case .welcome: "A browser built around Spaces. Web pages, terminals and the pages your agents make sit side by side in one sidebar."
        case .space: "A Space keeps its own tabs, logins and working folder."
        case .agents: "Agents you already use can drive this browser. They ask before acting."
        case .plugins: "Small add-ons you can read and approve."
        }
    }
}

/// One dot per step, the current one solid.
private struct StepDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
    }
}
