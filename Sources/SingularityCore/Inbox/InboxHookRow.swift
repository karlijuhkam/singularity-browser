import Foundation

/// What the "Show questions in the inbox" row in Settings → Agents shows: its caption, the one
/// button that applies (if any) and an error from the last Install / Remove. Pure, so every
/// state is tested; the view (`InboxHookRowView`) only draws it.
///
/// There is no disabled button: Install and Remove finish at once (a small file is rewritten),
/// so the row has no "working" state. A button is either offered or absent.
public struct InboxHookRow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The file has not been read yet.
        case checking
        /// No `singularity-hook` next to the running program (the bare debug binary).
        case helperMissing
        /// The app runs from a translocated, read-only copy whose path changes on every launch.
        case translocated
        case status(ClaudeHookSettings.Status)
    }

    public enum Action: Equatable, Sendable {
        case install     // also Update: install repoints our entries at this copy
        case remove
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let action: Action

        public init(title: String, action: Action) {
            self.title = title
            self.action = action
        }
    }

    public static let title = "Show questions in the inbox"

    public let caption: String
    /// The other copy's helper path, for `.otherCopy`. Read from the file, so cleaned like any
    /// untrusted text and shown as plain text.
    public let otherPath: String?
    public let button: Button?
    /// What went wrong in the last Install / Remove, shown in the row.
    public let error: String?

    /// `settingsPath`: the file in use, as shown to the owner (`~/.claude/settings.json`).
    public init(state: State, error: String?, settingsPath: String) {
        let base = "Adds a hook to \(settingsPath) so Claude Code's questions and permission requests "
            + "can be answered in Singularity's inbox. Rewriting the file may reorder its keys."
        var otherPath: String?
        var error = error
        switch state {
        case .checking:
            caption = base
            button = nil
        case .helperMissing:
            caption = "This copy of Singularity runs without its app bundle, and the hook needs the app bundle."
            button = nil
        case .translocated:
            caption = "Move Singularity to the Applications folder and reopen it"
            button = nil
        case .status(.notInstalled):
            caption = base
            button = Button(title: "Install", action: .install)
        case .status(.installed):
            caption = base + " Remove takes only Singularity's entries out again."
            button = Button(title: "Remove", action: .remove)
        case .status(.otherCopy(let path)):
            caption = base + " It points at another copy of Singularity:"
            otherPath = InboxText.clean(path, limit: InboxText.messageLimit)
            button = Button(title: "Update", action: .install)
        case .status(.unreadable):
            caption = "\(settingsPath) couldn't be read as JSON; it was left alone."
            button = nil
            error = nil       // the caption already says what is wrong
        }
        self.otherPath = otherPath
        self.error = error
    }
}
