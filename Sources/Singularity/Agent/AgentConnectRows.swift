import AppKit
import SingularityCore
import SwiftUI

/// One row per agent (Claude Code, Codex): its name on the left, and on the right what can be done
/// about it right now (Connect, Update, a spinner, "Connected ✓"), with a caption or a command to
/// copy underneath. Used by Settings → Agents and by the welcome flow. The caller starts the check
/// (`connector.refresh()`), so the shell commands only run when the rows are actually shown.
struct AgentConnectRows: View {
    /// `.compact` for Settings; `.roomy` for the welcome flow: larger text (captions 12 pt) and a
    /// divider between the two rows.
    enum Style {
        case compact, roomy
    }

    let connector: AgentConnector
    let style: Style

    init(connector: AgentConnector, style: Style = .compact) {
        self.connector = connector
        self.style = style
    }

    var body: some View {
        ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, agent in
            if style == .roomy && index > 0 {
                Divider()
            }
            row(agent, state: connector.rows[agent] ?? .checking)
        }
    }

    /// The agent's name; the captions and commands under it.
    private var nameFont: Font { style == .roomy ? .system(size: 14) : .body }
    private var captionFont: Font { style == .roomy ? .system(size: 12) : .caption }

    private func row(_ agent: AgentKind, state: AgentConnector.RowState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.title)
                    .font(nameFont)
                Spacer()
                trailing(agent, state: state)
            }
            details(agent, state: state)
        }
    }

    /// The right-hand side: a status word or the one button that applies.
    @ViewBuilder
    private func trailing(_ agent: AgentKind, state: AgentConnector.RowState) -> some View {
        switch state {
        case .checking, .working:
            ProgressView().controlSize(.small)
        case .status(.notInstalled):
            Text("Not found").foregroundStyle(.secondary)
        case .status(.notConnected):
            Button("Connect") { Task { await connector.connect(agent) } }
        case .status(.connected):
            Text("Connected ✓").foregroundStyle(.green)
        case .status(.otherCopy):
            Button("Update") { Task { await connector.connect(agent) } }
        case .status(.translocated), .status(.separateDataFolder), .failed:
            EmptyView()
        }
    }

    /// The line(s) under the name: what the button does, what went wrong, or the command to copy.
    @ViewBuilder
    private func details(_ agent: AgentKind, state: AgentConnector.RowState) -> some View {
        switch state {
        case .status(.notInstalled):
            CopyableCommand(text: connector.command(for: agent), font: captionFont.monospaced())
        case .status(.notConnected):
            caption("Adds Singularity to \(agent.title)’s MCP servers")
        case .status(.otherCopy(let path)):
            caption("Points at another copy of Singularity")
            Text(path)
                .font(captionFont.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        case .failed(let message):
            Text(message)
                .font(captionFont)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            CopyableCommand(text: connector.command(for: agent), font: captionFont.monospaced())
        case .status(.separateDataFolder):
            caption("This copy uses its own data folder, so it can’t change your agents’ setup.")
        case .status(.translocated):
            caption("Move Singularity to the Applications folder and reopen it")
        case .checking, .working, .status(.connected):
            EmptyView()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(captionFont).foregroundStyle(.secondary)
    }
}

/// The Copy buttons (the agent rows' commands, step 4's prompt): `text` replaces what is on the
/// pasteboard. Tests pass a private named pasteboard, never the user's.
enum CopyText {
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A command in monospace with a Copy button, for running it in a terminal by hand.
private struct CopyableCommand: View {
    let text: String
    let font: Font
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                CopyText.copy(text)
                copied = true
            }
            .controlSize(.small)
        }
        // "Copied" turns back into "Copy" after two seconds, as in the welcome flow's step 4.
        // (`.task(id:)` starts again, and cancels the previous wait, each time `copied` changes.)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}
