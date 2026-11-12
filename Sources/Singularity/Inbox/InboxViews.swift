import AppKit
import SingularityCore
import SwiftUI

// Everything an agent or a page put into an entry is shown with `Text(verbatim:)` (never parsed
// as Markdown or looked up as a localisation key) and goes through `InboxText` first.

// MARK: - The rail

/// The tray at the top of the rail: count badge, toggles the panel.
struct InboxRailButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let inbox = state.inbox
        let count = inbox.inbox.count
        Button {
            if inbox.isPanelShown {
                inbox.closePanel()
            } else {
                inbox.showPanel(takingFocus: true)
            }
        } label: {
            Image(systemName: count > 0 ? "tray.full" : "tray")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(inbox.isPanelShown ? 1 : 0.6),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        // Nothing waiting: the button stays, dimmed.
        .foregroundStyle(count > 0 ? HierarchicalShapeStyle.primary : .secondary)
        .overlay(alignment: .topTrailing) {
            InboxCountBadge(count: count)
                .offset(x: 5, y: -4)
                .allowsHitTesting(false)
                // The button's own label already says the count.
                .accessibilityHidden(true)
        }
        // The panel opens beside this button, so it needs the button's AppKit view.
        .background(InboxAnchor { view in inbox.railAnchor = view })
        // The rail starts below the window's title-bar strip, so `.help` is safe here
        // (see CLAUDE.md, Split view).
        .help("Inbox (⌃⌘I)")
        .accessibilityLabel("Inbox, \(count) waiting")
    }
}

/// Small red count on a Space circle; hidden at 0. Used by SpaceDot.
struct InboxCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(verbatim: count > 99 ? "99+" : String(count))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Color.red, in: Capsule())
                .fixedSize()
                .accessibilityLabel("\(count) waiting")
        }
    }
}

/// An invisible AppKit view behind the tray button; hands itself to `onView` so the panel can be
/// placed beside it. It never takes a click (hitTest returns nil), the button above it does.
private struct InboxAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        onView(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        onView(view)
    }
}

// MARK: - The list

/// What a button on a card asks for. `InboxCenter.perform` carries it out. The answers (approval,
/// question, permission) count only once the cards have been still for a moment
/// (`InboxCenter.answersUnlockAt`).
enum InboxCardAction {
    case goTo(InboxEntry)
    case dismiss(UUID)
    /// Allow (`.approved`), Allow on <site> (`.approvedSite`) or Deny (`.denied`).
    case decideApproval(UUID, AgentApprovals.Outcome)
    /// Shows the tab, restarts the clock, answers nothing.
    case showApprovalTab(UUID)
    /// A held question's answers: cleaned question text → cleaned labels, as the card shows them.
    case answerQuestion(UUID, [String: [String]])
    /// Allow (this once) or Deny for a held permission request.
    case decidePermission(UUID, allow: Bool)
}

/// The panel's header: "Inbox" and how many more agents are working.
struct InboxHeader: View {
    let workingCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Inbox")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if workingCount > 0 {
                Text(workingCount == 1 ? "1 more agent working" : "\(workingCount) more agents working")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// The list. `onAction` closures come from InboxCenter; later tasks add cases.
/// Holds the inbox weakly, for the reason given at `InboxPanelContent`.
struct InboxListView: View {
    weak var center: InboxCenter?
    let onAction: (InboxCardAction) -> Void

    var body: some View {
        let entries = center?.inbox.visible ?? []
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text("Nothing is waiting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ForEach(entries) { entry in
                    InboxCard(entry: entry, place: InboxPlace(entry, state: center?.state), onAction: onAction)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// Where an entry comes from, for the card's first line: the Space's colour, and "Space · folder"
/// (terminals) or "site · tab title" (browser approvals).
struct InboxPlace {
    var colour: Color
    var text: String

    @MainActor
    init(_ entry: InboxEntry, state: AppState?) {
        let space = state?.space(entry.spaceID)
        colour = Color(hex: space?.colorHex ?? "#8A8F98")
        let spaceName = space?.name ?? ""
        var parts: [String] = []
        if case .approval(let approval) = entry.kind {
            let host = approval.siteHost ?? approval.url.flatMap { URL(string: $0)?.host() }
            parts = [host, approval.tabTitle].compactMap { $0 }.map { InboxText.clean($0, limit: 80) }
            if parts.allSatisfy(\.isEmpty) { parts = [spaceName] }
        } else {
            parts = [spaceName]
            if let tabID = entry.tabID, let folder = space?.tab(tabID)?.workingDirectory {
                parts.append(Self.folderText(folder))
            }
        }
        text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A terminal's folder as "~/…". It comes from the shell (any folder name a program made), so
    /// it is cleaned like agent text.
    static func folderText(_ workingDirectory: String) -> String {
        InboxText.clean(HomePath.abbreviate(HomePath.expand(workingDirectory)), limit: 80)
    }
}

/// One card: the first line, a body by kind, and the buttons.
private struct InboxCard: View {
    let entry: InboxEntry
    let place: InboxPlace
    let onAction: (InboxCardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(place.colour)
                    .frame(width: 8, height: 8)
                Text(verbatim: InboxText.clean(entry.agent, limit: 40))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: place.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                InboxStateChip(entry: entry)
            }

            cardBody

            InboxCardButtons(entry: entry, onAction: onAction)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // The seam for later tasks: each kind has its own small view.
    @ViewBuilder private var cardBody: some View {
        switch entry.kind {
        case .waiting: InboxWaitingBody(message: entry.message)
        case .done: InboxDoneBody(message: entry.message)
        case .question(let questions): InboxQuestionBody(entry: entry, questions: questions, onAction: onAction)
        case .permission:
            if let shown = InboxPermissionText(entry) { InboxPermissionBody(shown: shown) }
        case .approval(let approval): InboxApprovalBody(approval: approval)
        }
    }
}

// MARK: Bodies by kind

private struct InboxWaitingBody: View {
    let message: String?

    var body: some View {
        Text(verbatim: message.map { InboxText.clean($0, limit: InboxText.messageLimit) } ?? "Waiting for you")
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InboxDoneBody: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(verbatim: InboxText.clean(message, limit: InboxText.messageLimit))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the owner has picked on a question card so far, and what the card's buttons do.
/// - Exactly one single-choice question: an option answers at once (`answersAtOnce`).
/// - Otherwise options toggle (a single-choice question is a radio group) and Send answers, once
///   every question has a choice (`isComplete`).
struct InboxQuestionPicks: Equatable {
    let questions: [InboxQuestion]
    /// Picked labels by question index (two questions may read the same once cleaned).
    private var picked: [Int: Set<String>] = [:]

    init(questions: [InboxQuestion]) {
        self.questions = questions
    }

    var answersAtOnce: Bool {
        questions.count == 1 && !questions[0].multiSelect
    }

    func isPicked(_ question: Int, _ label: String) -> Bool {
        picked[question]?.contains(label) ?? false
    }

    mutating func toggle(_ question: Int, _ label: String) {
        guard questions.indices.contains(question), questions[question].options.contains(label) else { return }
        var labels = picked[question] ?? []
        if labels.contains(label) {
            labels.remove(label)
        } else if questions[question].multiSelect {
            labels.insert(label)
        } else {
            labels = [label]
        }
        picked[question] = labels
    }

    var isComplete: Bool {
        questions.indices.allSatisfy { !(picked[$0] ?? []).isEmpty }
    }

    /// Question text → picked labels in the options' order (what `InboxCenter.answerQuestion` takes).
    var answers: [String: [String]] {
        var result: [String: [String]] = [:]
        for (index, question) in questions.enumerated() {
            let labels = question.options.filter { isPicked(index, $0) }
            if !labels.isEmpty { result[question.question] = labels }
        }
        return result
    }

    /// The action of an option button on a card that answers at once; nil when the card does not.
    static func answerAtOnce(entry: InboxEntry, question index: Int, label: String) -> InboxCardAction? {
        guard case .question(let questions) = entry.kind, InboxQuestionPicks(questions: questions).answersAtOnce,
              questions.indices.contains(index), questions[index].options.contains(label) else { return nil }
        return .answerQuestion(entry.id, [questions[index].question: [label]])
    }
}

/// Claude Code's question: each question (with its short header), its options as buttons, and
/// "Other…", which goes to the terminal where the question then appears (to type an answer of
/// one's own). With several questions or multiple choice, options toggle and "Send" answers.
private struct InboxQuestionBody: View {
    let entry: InboxEntry
    let questions: [InboxQuestion]
    let onAction: (InboxCardAction) -> Void
    @State private var picks: InboxQuestionPicks

    init(entry: InboxEntry, questions: [InboxQuestion], onAction: @escaping (InboxCardAction) -> Void) {
        self.entry = entry
        self.questions = questions
        self.onAction = onAction
        _picks = State(initialValue: InboxQuestionPicks(questions: questions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    if let header = question.header {
                        Text(verbatim: InboxText.clean(header, limit: 80))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: InboxText.clean(question.question, limit: InboxText.messageLimit))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options, id: \.self) { label in
                        option(label, question: index, multiSelect: question.multiSelect)
                    }
                }
            }
            HStack(spacing: 6) {
                if !picks.answersAtOnce {
                    Button("Send") { onAction(.answerQuestion(entry.id, picks.answers)) }
                        .disabled(!picks.isComplete)
                }
                Button("Other…") { onAction(.goTo(entry)) }
            }
            .controlSize(.small)
        }
    }

    private func option(_ label: String, question index: Int, multiSelect: Bool) -> some View {
        let picked = picks.isPicked(index, label)
        return Button {
            if let action = InboxQuestionPicks.answerAtOnce(entry: entry, question: index, label: label) {
                onAction(action)
            } else {
                picks.toggle(index, label)
            }
        } label: {
            HStack(spacing: 5) {
                if !picks.answersAtOnce {
                    Image(systemName: multiSelect ? (picked ? "checkmark.square.fill" : "square")
                                                  : (picked ? "largecircle.fill.circle" : "circle"))
                        .accessibilityHidden(true)
                }
                Text(verbatim: InboxText.clean(label, limit: InboxText.messageLimit))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Claude Code wants to use a tool: which one, and its input (where or what first, see
/// `ClaudeHook`) in a small scrolling monospaced box; when the input had to be cut, a line that
/// says so. Allow and Deny are in `InboxCardButtons`.
private struct InboxPermissionBody: View {
    let shown: InboxPermissionText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: shown.headline)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !shown.input.isEmpty { InboxBlockText(text: shown.input, maxHeight: 90) }
            if let note = shown.cutNote {
                Text(verbatim: note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The texts a permission card shows, each cleaned (all of it comes from Claude Code's input).
struct InboxPermissionText {
    let headline: String   // "Wants to use <tool>"
    let input: String      // keeps line breaks; empty when there is none
    /// "Too long to show in full." when the input was cut; nil otherwise.
    let cutNote: String?

    init?(_ entry: InboxEntry) {
        guard case .permission(let tool, let input, let isComplete) = entry.kind else { return nil }
        headline = "Wants to use \(InboxText.clean(tool, limit: 80))"
        self.input = InboxText.cleanBlock(input, limit: InboxText.inputLimit)
        cutNote = isComplete ? nil : "Too long to show in full."
    }
}

/// Allow and Deny for a held permission request; only Deny when the input could not be shown in
/// full (Go to terminal, on every card with a tab, shows Claude Code's own prompt with all of
/// it). Neither is a default button: the owner decides about his own machine with a deliberate
/// click.
enum InboxPermissionButtons {
    static func choices(for entry: InboxEntry) -> [InboxApprovalButtons.Choice] {
        guard case .permission(_, _, let isComplete) = entry.kind else { return [] }
        let deny = InboxApprovalButtons.Choice(title: "Deny", action: .decidePermission(entry.id, allow: false))
        guard isComplete else { return [deny] }
        return [InboxApprovalButtons.Choice(title: "Allow", action: .decidePermission(entry.id, allow: true)), deny]
    }
}

/// The texts an approval card shows, each cleaned (all of it comes from an agent or a page).
struct InboxApprovalText {
    let headline: String   // "<actor> wants to <action>"
    let detail: String
    let url: String        // empty when there is none
    let text: String       // keeps line breaks; empty when there is none

    init(_ approval: InboxApproval) {
        let actor = InboxText.clean(approval.actor, limit: 80)
        let action = InboxText.clean(approval.action, limit: InboxText.messageLimit)
        headline = "\(actor) wants to \(action)"
        detail = InboxText.clean(approval.detail, limit: InboxText.messageLimit)
        url = InboxText.clean(approval.url ?? "", limit: InboxText.messageLimit)
        text = InboxText.cleanBlock(approval.text ?? "", limit: InboxText.inputLimit)
    }
}

/// "<actor> wants to <action>", the element or URL it is about, the page's address, and the text
/// to be typed or sent (password text arrives already masked). The buttons are in
/// `InboxApprovalButtons`.
private struct InboxApprovalBody: View {
    let approval: InboxApproval

    var body: some View {
        let shown = InboxApprovalText(approval)
        let (detail, url, text) = (shown.detail, shown.url, shown.text)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: shown.headline)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !url.isEmpty, url != detail {
                Text(verbatim: url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !text.isEmpty { InboxBlockText(text: text, maxHeight: 90) }
        }
    }
}

/// Long text (a command, the text a page is about to receive): monospaced, in a box that scrolls
/// beyond `maxHeight`.
private struct InboxBlockText: View {
    let text: String
    var maxHeight: CGFloat = 120
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 20), maxHeight))
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: First line and buttons

private struct InboxCardButtons: View {
    let entry: InboxEntry
    let onAction: (InboxCardAction) -> Void

    var body: some View {
        // No button here is a default button (no `.keyboardShortcut(.defaultAction)`, nothing
        // prominent): Return typed elsewhere must never press one.
        if case .approval = entry.kind {
            InboxApprovalButtons(entry: entry, onAction: onAction)
        } else {
            let isDone = entry.kind == .done
            let permission = InboxPermissionButtons.choices(for: entry)
            if isDone || entry.tabID != nil || !permission.isEmpty {
                HStack(spacing: 6) {
                    if isDone {
                        Button("Dismiss") { onAction(.dismiss(entry.id)) }
                            .controlSize(.small)
                    }
                    ForEach(Array(permission.enumerated()), id: \.offset) { _, choice in
                        Button(choice.title) { onAction(choice.action) }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if entry.tabID != nil {
                        Button("Go to terminal") { onAction(.goTo(entry)) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }
}

/// Allow, Allow on <site> (only when the rules offer it), Deny, and Show Tab (only when the
/// request is about a tab). Plain small buttons, none of them the default.
struct InboxApprovalButtons: View {
    let entry: InboxEntry
    let onAction: (InboxCardAction) -> Void

    /// One button: its title and what it does.
    struct Choice {
        let title: String
        let action: InboxCardAction
    }

    /// The answer buttons, left to right, and Show Tab (at the right, as a link). The view shows
    /// exactly these, so tests read the buttons from here.
    static func choices(for entry: InboxEntry) -> (answers: [Choice], showTab: Choice?) {
        guard case .approval(let approval) = entry.kind else { return ([], nil) }
        var answers = [Choice(title: "Allow", action: .decideApproval(entry.id, .approved))]
        if let siteHost = approval.siteHost {
            // The host comes from the page's address: cleaned like any page text.
            answers.append(Choice(title: "Allow on " + InboxText.clean(siteHost, limit: 80),
                                  action: .decideApproval(entry.id, .approvedSite)))
        }
        answers.append(Choice(title: "Deny", action: .decideApproval(entry.id, .denied)))
        let showTab = entry.tabID == nil ? nil : Choice(title: "Show Tab", action: .showApprovalTab(entry.id))
        return (answers, showTab)
    }

    var body: some View {
        let choices = Self.choices(for: entry)
        HStack(spacing: 6) {
            ForEach(Array(choices.answers.enumerated()), id: \.offset) { index, choice in
                // A `String` title is shown as written (never looked up as a localisation key).
                Button(choice.title) { onAction(choice.action) }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // A long "Allow on <site>" gives way first; Allow and Deny keep their size.
                    .layoutPriority(index == 1 && choices.answers.count == 3 ? -1 : 0)
            }
            Spacer(minLength: 0)
            if let showTab = choices.showTab {
                Button(showTab.title) { onAction(showTab.action) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .fixedSize()
            }
        }
        .controlSize(.small)
    }
}

/// `asks`, `permission`, `waiting`, `done · 4 min`; for approvals the time left, every second.
private struct InboxStateChip: View {
    let entry: InboxEntry

    var body: some View {
        switch entry.kind {
        case .approval:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                InboxChip(text: InboxChipText.timeLeft(until: entry.deadline, now: context.date), tint: .orange)
            }
        case .done:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                InboxChip(text: InboxChipText.done(since: entry.arrived, now: context.date), tint: .green)
            }
        case .question, .waiting(.question):
            InboxChip(text: "asks", tint: .orange)
        case .permission, .waiting(.permission):
            InboxChip(text: "permission", tint: .orange)
        case .waiting:
            InboxChip(text: "waiting", tint: .orange)
        }
    }
}

private struct InboxChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .fixedSize()
    }
}

enum InboxChipText {
    /// "done" in the first minute, then "done · 4 min", "done · 2 h".
    static func done(since arrived: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(arrived) / 60)
        if minutes < 1 { return "done" }
        if minutes < 60 { return "done · \(minutes) min" }
        return "done · \(minutes / 60) h"
    }

    /// "1:45 left"; "0:00 left" once the time is up.
    static func timeLeft(until deadline: Date?, now: Date) -> String {
        let seconds = max(0, Int((deadline ?? now).timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }
}
