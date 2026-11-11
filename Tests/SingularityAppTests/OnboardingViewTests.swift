import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
@testable import SingularityCore

/// Answers every command line with "found" and runs nothing, so the agents step never starts the
/// user's login shell (nor `claude`/`codex`).
private actor QuietShell: AgentShell {
    private(set) var lines: [String] = []

    func run(_ commandLine: String) async -> (exitCode: Int32, output: String, timedOut: Bool) {
        lines.append(commandLine)
        return (0, "", false)
    }
}

extension AppTests {
/// The welcome flow on screen (an off-screen window) with a real `AppState` on a temporary data
/// folder, driven the way a user without a mouse would: Return, Esc and typing.
@MainActor
@Suite(.serialized) struct OnboardingViewTests {
    private struct Hosted {
        let state: AppState
        let window: NSWindow
        let shell: QuietShell
        let root: URL
    }

    /// A short path: the agent socket lives under it, and Unix sockets allow ~100 characters.
    private func host(size: CGSize) -> Hosted {
        let root = URL(filePath: "/private/tmp/sg-t-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let state = AppState(paths: Paths(root: root))
        let shell = QuietShell()
        // An empty home folder: no agent config files, so both rows read "not connected".
        let connector = AgentConnector(launcher: "/Applications/Singularity.app/Contents/MacOS/singularity-mcp",
                                       home: root, shell: shell)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(connector: connector).environment(state))
        window.orderFront(nil)
        return Hosted(state: state, window: window, shell: shell, root: root)
    }

    /// Stops what `AppState.init` started (agent socket, plugin watcher, artifact servers).
    private func tearDown(_ hosted: Hosted) {
        hosted.window.close()
        hosted.state.mcp?.stop()
        hosted.state.plugins.terminateAll()
        for space in hosted.state.spaces { hosted.state.artifacts.stop(space.id) }
        try? FileManager.default.removeItem(at: hosted.root)
    }

    /// Lets SwiftUI update and lay out the window.
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A key press as the window would get it: first as a key equivalent (where SwiftUI's
    /// `.keyboardShortcut` buttons live), else as an ordinary key press for the focused view.
    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    private func pressReturn(_ window: NSWindow) { press("\r", keyCode: 36, in: window) }
    private func pressEscape(_ window: NSWindow) { press("\u{1b}", keyCode: 53, in: window) }

    /// Step 2's name field (the only editable text field in the flow).
    private func nameField(_ window: NSWindow) -> NSTextField? {
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        return all(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    /// Replaces the name field's text by typing, as a user would.
    private func type(_ text: String, into field: NSTextField, in window: NSWindow) {
        window.makeFirstResponder(field)
        let editor = field.currentEditor() as? NSTextView
        editor?.selectAll(nil)
        editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
    }

    @Test(arguments: [CGSize(width: 1100, height: 720), CGSize(width: 700, height: 500)])
    func laysOutEveryStepAndFinishes(size: CGSize) async throws {
        MainRunLoopGuard.start
        let hosted = host(size: size)
        defer { tearDown(hosted) }
        let state = hosted.state

        for step in OnboardingStep.allCases {
            try await settle(hosted.window)
            #expect(state.onboarding?.step == step)
            state.advanceWelcome()
        }
        try await settle(hosted.window)
        #expect(state.onboarding == nil)
    }

    @Test func returnTypingAndEscapeDriveTheFlow() async throws {
        MainRunLoopGuard.start
        let hosted = host(size: CGSize(width: 1100, height: 720))
        defer { tearDown(hosted) }
        let (state, window) = (hosted.state, hosted.window)
        let id = try #require(state.firstRunPlaceholderID)
        try await settle(window)

        // Step 1: Return is "Get started".
        pressReturn(window)
        try await settle(window)
        #expect(state.onboarding?.step == .space)

        // Step 2 starts from the Space as saved; Return is "Continue", which saves.
        let field = try #require(nameField(window))
        #expect(field.stringValue == "Personal")
        type("Work", into: field, in: window)
        try await settle(window)
        pressReturn(window)
        try await settle(window)
        #expect(state.onboarding?.step == .agents)
        #expect(state.space(id)?.name == "Work")
        #expect(state.space(id)?.slug == "work")
        state.flushSaves()
        #expect(Set((try? FileManager.default.contentsOfDirectory(atPath: state.paths.spacesDirectory.path)) ?? []) == ["work"])

        // Step 3: the check ran when the step appeared; the Space stays closed to agents.
        for _ in 0..<40 {
            if await hosted.shell.lines.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await hosted.shell.lines.count == 2)
        #expect(state.space(id)?.agentsEnabled == false)
        #expect(state.space(id)?.agentPolicy == .ask)
        pressReturn(window)
        try await settle(window)
        #expect(state.onboarding?.step == .plugins)

        // Step 4: Return is "Start browsing", which ends the flow.
        pressReturn(window)
        try await settle(window)
        #expect(state.onboarding == nil)

        // Reopened (menu, palette): step 2 shows the saved name; Back throws away what was typed.
        state.showWelcome()
        try await settle(window)
        pressReturn(window)
        try await settle(window)
        let again = try #require(nameField(window))
        #expect(again.stringValue == "Work")
        type("Something else", into: again, in: window)
        try await settle(window)
        state.welcomeBack()
        try await settle(window)
        state.advanceWelcome()
        try await settle(window)
        #expect(try #require(nameField(window)).stringValue == "Work")
        #expect(state.space(id)?.name == "Work")

        // Esc leaves the whole flow, from any step.
        pressEscape(window)
        try await settle(window)
        #expect(state.onboarding == nil)
        #expect(state.space(id)?.name == "Work")
        #expect(state.space(id)?.slug == "work")
    }
}
}
