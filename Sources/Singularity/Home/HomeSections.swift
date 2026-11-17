import SingularityCore
import SwiftUI

/// What the home's sections show, as plain rows built from the app's own state (the inbox, the
/// terminal board, the Space's tabs). Everything a terminal, agent or page reported is untrusted:
/// it is cleaned here (`InboxText.clean`) and drawn with `Text(verbatim:)`.
@MainActor
enum HomeOverview {
    /// Terminal titles and sources are cut here; the row cuts again with an ellipsis.
    static let titleLimit = 120
    static let lineLimit = 200

    struct WaitingRow: Identifiable {
        let entry: InboxEntry
        var id: UUID { entry.id }
        var tabID: UUID? { entry.tabID }
        /// The agent or source ("Claude Code", "An agent").
        let source: String
        /// The terminal's (or page's) title; empty when there is none.
        let title: String
        /// The entry's first line.
        let line: String
        let isApproval: Bool
    }

    struct TerminalRow: Identifiable {
        let id: UUID
        let state: TerminalBoard.State
        /// nil: nothing was ever reported for this terminal.
        let since: Date?
        /// The program in front (nil: the shell, or not running since launch).
        let program: String?
        let title: String
        let project: String?
        /// Its state changed after the owner last left this Space's home (`HomeRules.isNew`).
        let isNew: Bool
    }

    /// Waiting for you: the Space's entries the inbox counts, in the inbox's order.
    static func waiting(state: AppState, space: Space) -> [WaitingRow] {
        state.inbox.inbox.visible.filter { $0.spaceID == space.id }.map { entry in
            var isApproval = false
            var line = entry.message ?? ""
            var title = entry.tabID.flatMap { space.tab($0)?.displayTitle } ?? ""
            var source = entry.agent
            switch entry.kind {
            case .approval(let approval):
                isApproval = true
                source = approval.actor
                line = "wants to \(approval.action)"
                if let tabTitle = approval.tabTitle { title = tabTitle }
            case .question(let questions):
                if line.isEmpty { line = questions.first?.question ?? "asks a question" }
            case .permission(let tool, _, _):
                if line.isEmpty { line = "asks to use \(tool)" }
            case .waiting:
                if line.isEmpty { line = "is waiting" }
            case .done:
                if line.isEmpty { line = "is done" }
            }
            let firstLine = line.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return WaitingRow(entry: entry, source: InboxText.clean(source, limit: 60),
                              title: InboxText.clean(title, limit: titleLimit),
                              line: InboxText.clean(firstLine, limit: lineLimit), isApproval: isApproval)
        }
    }

    /// Terminals: every terminal tab of the Space, waiting first (`HomeRules.terminalOrder`).
    static func terminals(state: AppState, space: Space) -> [TerminalRow] {
        _ = state.inbox.boardRevision // the board itself is not observed; this redraws on a change
        let lastLeft = state.homeLeftAt[space.id]
        let rows = space.tabsInSidebarOrder.filter(\.isTerminal).map { tab -> TerminalRow in
            let board = state.inbox.board.row(tab.id)
            // Only a session that already exists: this never starts a shell.
            let program = state.terminalHandle(tab.id)?.foregroundProgram
            return TerminalRow(id: tab.id, state: board?.state ?? .unknown, since: board?.since,
                               program: program.map { InboxText.clean($0, limit: 40) }.flatMap { $0.isEmpty ? nil : $0 },
                               title: InboxText.clean(tab.displayTitle, limit: titleLimit),
                               project: space.project(tab.projectID).map { InboxText.clean($0.displayName, limit: 60) },
                               isNew: board.map { HomeRules.isNew(since: $0.since, lastLeft: lastLeft) } ?? false)
        }
        let order = HomeRules.terminalOrder(rows.map { (id: $0.id, state: $0.state, since: $0.since ?? .distantPast) })
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }
    }

    /// "12 min" (how long it has been working or waiting) or "5 min ago" (when it finished).
    static func relative(_ since: Date, now: Date, ongoing: Bool) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let amount: String
        switch seconds {
        case ..<60: return ongoing ? "under a min" : "just now"
        case ..<3600: amount = "\(seconds / 60) min"
        case ..<86_400: amount = "\(seconds / 3600) h"
        default: amount = "\(seconds / 86_400) d"
        }
        return ongoing ? amount : "\(amount) ago"
    }
}

/// The sections under the home's row: Waiting for you, Terminals, Projects, Recent.
struct HomeSections: View {
    @Environment(AppState.self) private var state
    let space: Space
    /// The home tab (nil: the empty Space's home, which has no tab to replace).
    let homeID: UUID?
    let recent: [HomeRecentFile]

    var body: some View {
        // Relative times tick once a minute, and only while the home is on screen.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let waiting = HomeOverview.waiting(state: state, space: space)
            let terminals = HomeOverview.terminals(state: state, space: space)
            VStack(alignment: .leading, spacing: 28) {
                if !waiting.isEmpty {
                    section("Waiting for you (\(waiting.count))") {
                        ForEach(waiting) { row in waitingRow(row) }
                    }
                }
                if !terminals.isEmpty {
                    section("Terminals") {
                        ForEach(terminals) { row in terminalRow(row, now: context.date) }
                    }
                }
                HStack(alignment: .top, spacing: 32) {
                    section("Projects") { projects }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !recent.isEmpty {
                        section("Recent") {
                            ForEach(recent, id: \.path) { file in recentRow(file) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 2) { content() }
        }
    }

    // MARK: Waiting for you

    private func waitingRow(_ row: HomeOverview.WaitingRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.isApproval ? "hand.raised" : "circle.fill")
                .font(.system(size: row.isApproval ? 12 : 7))
                .foregroundStyle(Color.orange)
                .frame(width: 16)
            Text(verbatim: row.title.isEmpty ? row.source : "\(row.source) · \(row.title)")
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(verbatim: row.line)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // Links only: answering stays in the inbox panel (its lock and no default button).
            if row.isApproval {
                Button("Show") { state.inbox.showPanel(takingFocus: true) }
                    .controlSize(.small)
            } else if row.tabID != nil {
                Button("Go") { state.inbox.goTo(row.entry) }
                    .controlSize(.small)
            }
        }
        .modifier(HomeRowStyle())
    }

    // MARK: Terminals

    private func terminalRow(_ row: HomeOverview.TerminalRow, now: Date) -> some View {
        Button {
            state.selectTab(row.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(row.state))
                    .foregroundStyle(Self.colour(row.state))
                    .frame(width: 16)
                Text(Self.word(row.state))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Text(verbatim: [row.program, row.title.isEmpty ? nil : row.title].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let project = row.project {
                    Text(verbatim: project)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let since = row.since, row.state != .unknown, row.state != .idle {
                    Text(HomeOverview.relative(since, now: now, ongoing: row.state == .working || row.state == .waiting))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if row.isNew {
                    Text("new")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .modifier(HomeRowStyle())
        }
        .buttonStyle(.plain)
    }

    private static func symbol(_ state: TerminalBoard.State) -> String {
        switch state {
        case .waiting: "exclamationmark.circle.fill"
        case .working: "circle.dotted.circle"
        case .done: "checkmark.circle"
        case .idle: "circle"
        case .unknown: "circle.dashed"
        }
    }

    private static func colour(_ state: TerminalBoard.State) -> Color {
        switch state {
        case .waiting: .orange
        case .working: .accentColor
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }

    private static func word(_ state: TerminalBoard.State) -> String {
        switch state {
        case .waiting: "waiting"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        case .unknown: "—"
        }
    }

    // MARK: Projects

    @ViewBuilder
    private var projects: some View {
        if space.projects.isEmpty {
            Button {
                state.showSpaceEditor(spaceID: space.id)
            } label: {
                Label("Add a project…", systemImage: "folder.badge.plus")
                    .modifier(HomeRowStyle())
            }
            .buttonStyle(.plain)
        } else {
            ForEach(space.projects) { project in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(verbatim: project.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button {
                        state.homeNewTerminal(homeID: homeID, projectID: project.id, launcherID: nil)
                    } label: {
                        Label("Terminal", systemImage: "plus")
                    }
                    .controlSize(.small)
                    if !state.launchers.isEmpty {
                        Menu {
                            ForEach(state.launchers) { launcher in
                                Button("New \(launcher.displayName) Terminal") {
                                    state.homeNewTerminal(homeID: homeID, projectID: project.id, launcherID: launcher.id)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                .modifier(HomeRowStyle())
            }
        }
    }

    // MARK: Recent

    private func recentRow(_ file: HomeRecentFile) -> some View {
        Button {
            open(file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(file.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: Self.name(file))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.kind == .app {
                    Text("app")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .modifier(HomeRowStyle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ file: HomeRecentFile) {
        switch file.kind {
        case .note:
            state.replacingHome(homeID) { state.openNote(file.path) }
        case .artifact:
            state.replacingHome(homeID) { state.openArtifact(file.path) }
        case .app:
            let pages = state.artifacts.host(space.id)?.pages
                ?? ArtifactFiles.listPages(in: state.paths.artifactsDirectory(space.slug))
            guard let page = HomeRecentLoader.entryPage(ofApp: file.path, pages: pages) else { return }
            state.replacingHome(homeID) { state.openArtifact(page) }
        }
    }

    private static func symbol(_ kind: HomeRecentFile.Kind) -> String {
        switch kind {
        case .note: "note.text"
        case .artifact: "doc.richtext"
        case .app: "app.dashed"
        }
    }

    private static func name(_ file: HomeRecentFile) -> String {
        switch file.kind {
        case .note: NoteFiles.title(ofPath: file.path)
        case .artifact, .app: (file.path as NSString).lastPathComponent
        }
    }
}

/// A section row: full width, a little padding, a soft highlight under the pointer.
private struct HomeRowStyle: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovered = $0 }
    }
}
