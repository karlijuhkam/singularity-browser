import Foundation
import Testing
@testable import SingularityCore

/// The "Show questions in the inbox" row in Settings → Agents: what it says and which button it
/// offers, for every state; and which settings file the installer uses.
@Suite struct InboxHookRowTests {
    let path = "~/.claude/settings.json"
    let base = "Adds a hook to ~/.claude/settings.json so Claude Code's questions and permission requests "
        + "can be answered in Singularity's inbox. Rewriting the file may reorder its keys."

    func row(_ state: InboxHookRow.State, error: String? = nil) -> InboxHookRow {
        InboxHookRow(state: state, error: error, settingsPath: path)
    }

    @Test func title() {
        #expect(InboxHookRow.title == "Show questions in the inbox")
    }

    @Test func checkingHasNoButton() {
        let r = row(.checking)
        #expect(r.caption == base)
        #expect(r.button == nil)
        #expect(r.otherPath == nil)
        #expect(r.error == nil)
    }

    @Test func notInstalledOffersInstall() {
        let r = row(.status(.notInstalled))
        #expect(r.caption == base)
        #expect(r.button == InboxHookRow.Button(title: "Install", action: .install))
    }

    @Test func installedOffersRemoveAndSaysHowToUndo() {
        let r = row(.status(.installed))
        #expect(r.caption == base + " Remove takes only Singularity's entries out again.")
        #expect(r.button == InboxHookRow.Button(title: "Remove", action: .remove))
    }

    @Test func otherCopyOffersUpdateAndShowsThePathCleaned() {
        let r = row(.status(.otherCopy("/Volumes/Old/Singularity.app/Contents/MacOS/\u{202E}singularity-hook\n")))
        #expect(r.caption == base + " It points at another copy of Singularity:")
        #expect(r.otherPath == "/Volumes/Old/Singularity.app/Contents/MacOS/singularity-hook")
        // Update = install, which repoints our entries at this copy.
        #expect(r.button == InboxHookRow.Button(title: "Update", action: .install))
    }

    @Test func unreadableHasNoButtonAndHidesTheRepeatedError() {
        let r = row(.status(.unreadable), error: "anything")
        #expect(r.caption == "~/.claude/settings.json couldn't be read as JSON; it was left alone.")
        #expect(r.button == nil)
        #expect(r.error == nil)
    }

    @Test func translocatedHasNoButton() {
        let r = row(.translocated)
        #expect(r.caption == "Move Singularity to the Applications folder and reopen it")
        #expect(r.button == nil)
    }

    @Test func helperMissingSaysItNeedsTheAppBundle() {
        let r = row(.helperMissing)
        #expect(r.caption.contains("needs the app bundle"))
        #expect(r.button == nil)
    }

    @Test func errorsAreShown() {
        let r = row(.status(.notInstalled), error: "Permission denied")
        #expect(r.error == "Permission denied")
        #expect(r.button?.title == "Install")
    }

    @Test func captionNamesTheFileInUse() {
        let r = InboxHookRow(state: .status(.notInstalled), error: nil, settingsPath: "/private/tmp/sg-test/claude-settings.json")
        #expect(r.caption.hasPrefix("Adds a hook to /private/tmp/sg-test/claude-settings.json so"))
    }

    // MARK: - Which file

    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func realFileWhenNothingIsSet() {
        #expect(ClaudeHookSettings.file(environment: [:], home: home).path == "/Users/someone/.claude/settings.json")
        #expect(ClaudeHookSettings.file(environment: ["SINGULARITY_HOME": "", "SINGULARITY_CLAUDE_SETTINGS": ""], home: home).path
                == "/Users/someone/.claude/settings.json")
    }

    @Test func testCopyNeverGetsTheRealFile() {
        let file = ClaudeHookSettings.file(environment: ["SINGULARITY_HOME": "/private/tmp/sg-test"], home: home)
        #expect(file.path == "/private/tmp/sg-test/claude-settings.json")
    }

    @Test func explicitOverrideWins() {
        let file = ClaudeHookSettings.file(
            environment: ["SINGULARITY_HOME": "/private/tmp/sg-test", "SINGULARITY_CLAUDE_SETTINGS": "/private/tmp/x/settings.json"],
            home: home)
        #expect(file.path == "/private/tmp/x/settings.json")
    }

    @Test func oneTimeoutForInstallAndStatus() {
        #expect(ClaudeHookSettings.hookTimeoutSeconds == 3600)
    }
}
