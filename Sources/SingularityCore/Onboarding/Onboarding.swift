import Foundation

/// The welcome flow's steps, in order (spec: docs/superpowers/specs/2026-11-11-onboarding-design.md).
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, space, agents, plugins
}

/// Where the welcome flow is. Pure state; `AppState` holds one while the flow is on screen.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var step: OnboardingStep = .welcome
    /// True once Spaces were imported from Arc in this flow: the Space step is left out.
    public private(set) var importedFromArc = false

    public init() {}

    public var canGoBack: Bool { step != .welcome }

    /// The next step, or nil when the flow is finished (after .plugins).
    public mutating func advance() -> OnboardingStep? {
        guard let next = following(step) else { return nil }
        step = next
        return next
    }

    /// .agents → .space, or → .welcome after an Arc import. Does nothing on .welcome.
    public mutating func back() {
        switch step {
        case .welcome: break
        case .space: step = .welcome
        case .agents: step = importedFromArc ? .welcome : .space
        case .plugins: step = .agents
        }
    }

    /// The Spaces came from Arc, so there is nothing to customise: go on with the agents step.
    public mutating func arcImportFinished() {
        importedFromArc = true
        step = .agents
    }

    private func following(_ step: OnboardingStep) -> OnboardingStep? {
        switch step {
        case .welcome: return importedFromArc ? .agents : .space
        case .space: return .agents
        case .agents: return .plugins
        case .plugins: return nil
        }
    }
}

public enum FirstRun {
    /// A brand-new install: nothing was loaded and nothing failed to load. (A data folder whose
    /// Space files are all unreadable is not brand-new: the load-error alert is shown instead.)
    public static func isBrandNew(loadedSpaceCount: Int, loadErrorCount: Int) -> Bool {
        loadedSpaceCount == 0 && loadErrorCount == 0
    }

    /// The one case where a Space's slug may follow its name (spec, step 2): the Space a
    /// brand-new install made at launch, while it has no tabs. Everywhere else the slug is fixed.
    public static func mayReslug(isFirstRunPlaceholder: Bool, tabCount: Int) -> Bool {
        isFirstRunPlaceholder && tabCount == 0
    }
}
