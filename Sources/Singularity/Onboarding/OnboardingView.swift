import SingularityCore
import SwiftUI

/// The welcome flow (spec: docs/superpowers/specs/2026-11-11-onboarding-design.md). It covers the
/// whole window on a brand-new install, and again when chosen from the app menu or the palette.
///
/// Layout: the live orb on the left (large on step 1, smaller after), the step on the right, and
/// under the step a footer with the step dots, a quiet "Skip setup" (also Esc), Back, the step's
/// own secondary button and its primary button (also Return). Below about 720 points of width
/// the orb is left out rather than squeezing the controls.
///
/// All state lives in `AppState` (`onboarding`, `advanceWelcome`, …) except step 2's draft,
/// which only Continue writes back: Back, Skip, Skip setup and Esc throw it away.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = SpaceDraft()
    /// The current step's height, measured, so the column can hug it (see `column`).
    @State private var contentHeight: CGFloat = 0
    /// Step 3's agent rows. Held here so Back and forward again don't lose what was found.
    @State private var connector: AgentConnector

    /// `connector` is for tests (a fake shell); the app uses the one pointing at this copy.
    init(connector: AgentConnector? = nil) {
        _connector = State(initialValue: connector ?? AgentConnector(launcher: AgentConnector.thisAppLauncher))
    }

    /// The flow as `AppState` has it. (The fallback only matters for a frame while it closes.)
    private var flow: OnboardingFlow { state.onboarding ?? OnboardingFlow() }

    var body: some View {
        // GeometryReader hands us the window's size, to decide whether the orb fits beside the step.
        GeometryReader { geometry in
            let layout = OnboardingLayout(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.showsOrb {
                    OrbView(size: flow.step == .welcome ? 220 : 150)
                        .frame(width: layout.orbSideWidth)
                }
                column
                    .frame(width: layout.columnWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Room for the traffic lights (the window has no visible title bar) and some air below.
        .padding(.top, 44)
        .padding(.bottom, 32)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: flow.step)
        .onChange(of: flow.step, initial: true) { _, step in
            // Entering step 2 (from step 1, from Back on step 3, or reopened from the menu)
            // always starts from the Space as it is saved.
            if step == .space, let space = state.welcomeSpace { draft = SpaceDraft(space) }
        }
    }

    /// The step on top, the footer right underneath; the pair is centred beside the orb. The step
    /// scrolls only when the window is too short for it.
    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A new identity per step, so the switch crossfades instead of morphing.
                    .id(flow.step)
                    .transition(.opacity)
                    .padding(.vertical, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // A ScrollView takes all the height it is offered; this keeps it to its content's.
            .frame(maxHeight: contentHeight)
            footer
                .padding(.top, 32)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: contentHeight)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .welcome: WelcomeStep()
        case .space: SpaceStep(draft: $draft)
        case .agents: AgentsStep(connector: connector)
        case .plugins: PluginsStep()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            StepDots(steps: visibleSteps, current: flow.step)
            // Leaves the whole flow from any step. Esc does the same (the cancel shortcut).
            Button("Skip setup") { state.closeWelcome() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .padding(.leading, 14)
            Spacer(minLength: 12)
            if flow.canGoBack {
                Button("Back") { state.welcomeBack() }
            }
            secondaryButton
            primaryButton
        }
        .controlSize(.large)
    }

    /// After an Arc import the Space step is left out, so there are three dots.
    private var visibleSteps: [OnboardingStep] {
        flow.importedFromArc ? OnboardingStep.allCases.filter { $0 != .space } : OnboardingStep.allCases
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

    private var primaryButton: some View {
        Group {
            switch flow.step {
            case .welcome:
                Button("Get started") { state.advanceWelcome() }
            case .space:
                Button("Continue") {
                    state.applyWelcomeSpace(name: draft.trimmedName, colorHex: draft.colorHex,
                                            workingDirectory: draft.workingDirectory)
                    state.advanceWelcome()
                }
                .disabled(draft.trimmedName.isEmpty)
            case .agents:
                Button("Continue") { state.advanceWelcome() }
            case .plugins:
                Button("Start browsing") { state.advanceWelcome() }
            }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
}

/// How wide the orb side and the step column are for a given window width.
private struct OnboardingLayout {
    let showsOrb: Bool
    let orbSideWidth: CGFloat
    let columnWidth: CGFloat

    init(width: CGFloat) {
        let margin: CGFloat = 32
        showsOrb = width >= 720
        // About 40 % of the width, as in the mockup, but never more than the orb needs.
        orbSideWidth = showsOrb ? min(320, width * 0.4) : 0
        columnWidth = max(0, min(460, width - orbSideWidth - 2 * margin))
    }
}

/// One dot per step, the current one solid.
private struct StepDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
    }
}
