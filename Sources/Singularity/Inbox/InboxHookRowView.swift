import SingularityCore
import SwiftUI

/// Settings → Agents, under the Claude Code row: "Show questions in the inbox" with Install /
/// Update / Remove. What it says comes from `InboxHookRow` (Core, tested); the file work is
/// `HookInstaller`. The file is read when the Agents tab appears and after each button press;
/// there is no polling. Writing happens only from the button.
struct InboxHookRowView: View {
    let installer: HookInstaller
    let captionFont: Font

    @State private var state: InboxHookRow.State = .checking
    @State private var error: String?

    var body: some View {
        let row = InboxHookRow(state: state, error: error, settingsPath: installer.displayPath)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(InboxHookRow.title)
                Spacer()
                if let button = row.button {
                    Button(button.title) { run(button.action) }
                }
            }
            Text(verbatim: row.caption)
                .font(captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = row.otherPath {
                // Read from the file: plain text only.
                Text(verbatim: path)
                    .font(captionFont.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let error = row.error {
                Text(verbatim: error)
                    .font(captionFont)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        // Runs each time the row appears (the Agents tab is shown), like the Connect rows' check.
        .task { refresh() }
    }

    private func refresh() {
        state = installer.rowState()
    }

    private func run(_ action: InboxHookRow.Action) {
        error = nil
        do {
            switch action {
            case .install: try installer.install()
            case .remove: try installer.remove()
            }
        } catch let failure as HookInstaller.Failure {
            error = failure.message(file: installer.displayPath)
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
