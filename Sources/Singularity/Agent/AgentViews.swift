import SingularityCore
import SwiftUI

/// The colour that means "an agent did / is doing this".
let agentTint = Color(hex: "#9B6BDF")

/// Shown next to a tab's title: sparkles if an agent opened the tab, pulsing while an agent
/// is working on it.
struct AgentBadge: View {
    @Environment(AppState.self) private var state
    let tab: BrowserTab

    var body: some View {
        let busy = state.isAgentBusy(tab.id)
        if busy || tab.openedByAgent {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(busy ? agentTint : Color.secondary.opacity(0.7))
                .symbolEffect(.pulse, isActive: busy)
                .help(busy ? "An agent is working on this tab" : "Opened by an agent")
        }
    }
}

/// A soft agent-coloured background behind a tab row/chip/header while an agent works on it.
struct AgentBusyBackground: ViewModifier {
    @Environment(AppState.self) private var state
    let tabID: UUID
    var cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content.background {
            if state.isAgentBusy(tabID) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(agentTint.opacity(0.18))
                    .padding(.horizontal, -4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.isAgentBusy(tabID))
    }
}

extension View {
    func agentBusyBackground(_ tabID: UUID, cornerRadius: CGFloat = 6) -> some View {
        modifier(AgentBusyBackground(tabID: tabID, cornerRadius: cornerRadius))
    }
}

/// The sidebar's "Agent activity" section: the Space's most recent agent actions.
struct AgentLogPane: View {
    @Environment(AppState.self) private var state
    let space: Space
    @State private var isExpanded = false

    var body: some View {
        let entries = Array((state.agentLogs[space.id] ?? []).suffix(40).reversed())
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(agentTint)
                    Text("Agent activity")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(space.agentPolicy.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)

            if isExpanded {
                if entries.isEmpty {
                    Text("Nothing yet. Agent actions in this Space appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                AgentLogRow(entry: entry, space: space)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .onAppear { state.loadAgentLog(spaceID: space.id) }
        .onChange(of: space.id) { state.loadAgentLog(spaceID: space.id) }
    }
}

private struct AgentLogRow: View {
    @Environment(AppState.self) private var state
    let entry: AgentLogEntry
    let space: Space

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Button {
            if let tabID = entry.tabID, space.tab(tabID) != nil { state.selectTab(tabID) }
        } label: {
            HStack(spacing: 6) {
                icon
                    .font(.system(size: 10))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(action)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    if !target.isEmpty {
                        Text(target)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text(Self.timeFormat.string(from: entry.date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(entry.client) · \(entry.decision)\n\(entry.result)")
    }

    /// "click" from "work.click"; "prompt" for artifact pages.
    private var action: String {
        let name = entry.tool.split(separator: ".").last.map(String.init) ?? entry.tool
        let decision = entry.decision == "auto" ? "" : " · \(entry.decision.replacingOccurrences(of: "_", with: " "))"
        return name.replacingOccurrences(of: "_", with: " ") + decision
    }

    private var target: String {
        if let url = entry.args["url"] { return url }
        if let ref = entry.args["ref"] { return "[\(ref)]" + (entry.args["text"].map { " “\($0)”" } ?? "") }
        if let query = entry.args["query"] { return "“\(query)”" }
        if let text = entry.args["text"] { return "“\(text)”" }
        if let tabID = entry.tabID, let tab = space.tab(tabID) { return tab.displayTitle }
        return ""
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.decision {
        case "denied", "timeout": Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case "readonly": Image(systemName: "lock.fill").foregroundStyle(.secondary)
        default:
            if entry.ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}
