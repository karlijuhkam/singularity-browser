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

/// What a button on a card asks for. `InboxCenter.perform` carries it out; later tasks add the
/// answers to questions, permissions and approvals.
enum InboxCardAction {
    case goTo(InboxEntry)
    case dismiss(UUID)
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
struct InboxListView: View {
    let center: InboxCenter
    let onAction: (InboxCardAction) -> Void

    var body: some View {
        let entries = center.inbox.visible
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text("Nothing is waiting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ForEach(entries) { entry in
                    InboxCard(entry: entry, place: InboxPlace(entry, state: center.state), onAction: onAction)
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
                parts.append(HomePath.abbreviate(HomePath.expand(folder)))
            }
        }
        text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
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
        case .question(let questions): InboxQuestionBody(questions: questions)
        case .permission(let tool, let input): InboxPermissionBody(tool: tool, input: input)
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

/// Task 6 adds the answer buttons.
private struct InboxQuestionBody: View {
    let questions: [InboxQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                Text(verbatim: InboxText.clean(question.question, limit: InboxText.messageLimit))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Task 8 adds Allow and Deny.
private struct InboxPermissionBody: View {
    let tool: String
    let input: String

    var body: some View {
        let text = InboxText.cleanBlock(input, limit: InboxText.inputLimit)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Wants to use \(InboxText.clean(tool, limit: 80))")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !text.isEmpty { InboxBlockText(text: text) }
        }
    }
}

/// Task 6 adds Allow, Allow on <site> and Deny.
private struct InboxApprovalBody: View {
    let approval: InboxApproval

    var body: some View {
        let actor = InboxText.clean(approval.actor, limit: 80)
        let action = InboxText.clean(approval.action, limit: InboxText.messageLimit)
        let detail = InboxText.clean(approval.detail, limit: InboxText.messageLimit)
        let text = InboxText.cleanBlock(approval.text ?? "", limit: InboxText.inputLimit)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(actor) wants to \(action)")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !text.isEmpty { InboxBlockText(text: text) }
        }
    }
}

/// Long text (a command, the text a page is about to receive): monospaced, in a box that scrolls
/// beyond 120 pt, like the approval sheet's.
private struct InboxBlockText: View {
    let text: String
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
        .frame(height: min(max(height, 20), 120))
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: First line and buttons

private struct InboxCardButtons: View {
    let entry: InboxEntry
    let onAction: (InboxCardAction) -> Void

    var body: some View {
        let isApproval = if case .approval = entry.kind { true } else { false }
        let isDone = entry.kind == .done
        // No button here is a default button (no `.keyboardShortcut(.defaultAction)`, nothing
        // prominent): Return typed elsewhere must never press one.
        if isDone || entry.tabID != nil {
            HStack(spacing: 6) {
                if isDone {
                    Button("Dismiss") { onAction(.dismiss(entry.id)) }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if entry.tabID != nil {
                    Button(isApproval ? "Show Tab" : "Go to terminal") { onAction(.goTo(entry)) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
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
