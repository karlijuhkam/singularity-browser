import AppKit
import SingularityCore
import SwiftUI

/// One row per agent (Claude Code, Codex): its name on the left, and on the right what can be done
/// about it right now (Connect, Update, a spinner, "Connected ✓"), with a caption or a command to
/// copy underneath. Used by Settings → Agents and by the welcome flow. The caller starts the check
/// (`connector.refresh()`), so the shell commands only run when the rows are actually shown.
struct AgentConnectRows: View {
    let connector: AgentConnector

    init(connector: AgentConnector) {
        self.connector = connector
    }

    var body: some View {
        ForEach(AgentKind.allCases, id: \.self) { agent in
            row(agent, state: connector.rows[agent] ?? .checking)
        }
    }

    private func row(_ agent: AgentKind, state: AgentConnector.RowState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.title)
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
        case .status(.translocated), .failed:
            EmptyView()
        }
    }

    /// The line(s) under the name: what the button does, what went wrong, or the command to copy.
    @ViewBuilder
    private func details(_ agent: AgentKind, state: AgentConnector.RowState) -> some View {
        switch state {
        case .status(.notInstalled):
            CopyableCommand(text: connector.command(for: agent))
        case .status(.notConnected):
            caption("Adds Singularity to \(agent.title)’s MCP servers")
        case .status(.otherCopy(let path)):
            caption("Points at another copy of Singularity")
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            CopyableCommand(text: connector.command(for: agent))
        case .status(.translocated):
            caption("Move Singularity to the Applications folder and reopen it")
        case .checking, .working, .status(.connected):
            EmptyView()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// A command in monospace with a Copy button, for running it in a terminal by hand.
private struct CopyableCommand: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
    }
}
