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

    /// Where the view has drawn something (alpha above 8 of 255: an off-screen button's bezel is
    /// drawn at about 20) between the x positions `xs`, in points from the view's top left.
    /// `bottomRight` is the right-most drawn point in the lowest 20 points of drawing: the footer's
    /// primary button, which sits at the right.
    private struct Ink {
        let top: CGFloat
        let bottom: CGFloat
        let bottomRight: CGFloat
    }

    /// Reads the drawing from the view itself (`cacheDisplay`), so it measures what SwiftUI laid
    /// out without asking SwiftUI for frames. Only the strip `xs` is drawn into the copy, which
    /// leaves out the orb: copying the live Metal view while it draws on its own timer is asking
    /// for trouble.
    private func ink(of view: NSView, xs: ClosedRange<CGFloat>) throws -> Ink? {
        let strip = NSRect(x: xs.lowerBound, y: 0, width: xs.upperBound - xs.lowerBound, height: view.bounds.height)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: strip))
        view.cacheDisplay(in: strip, to: rep)
        let image = try #require(rep.cgImage)
        let (width, height) = (image.width, image.height)
        let scale = CGFloat(width) / strip.width
        // Known byte layout: RGBA, 8 bits each, top row first.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var rows: [Int: Int] = [:] // drawn row → right-most drawn column in it
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                rows[y] = max(rows[y] ?? 0, x)
            }
        }
        guard let top = rows.keys.min(), let bottom = rows.keys.max() else { return nil }
        let band = Int(20 * scale)
        let right = rows.filter { $0.key > bottom - band }.values.max() ?? 0
        return Ink(top: CGFloat(top) / scale, bottom: CGFloat(bottom + 1) / scale,
                   bottomRight: xs.lowerBound + CGFloat(right + 1) / scale)
    }

    /// Requirement: nothing jumps between steps (the title and the footer stay where they are),
    /// and the footer with its primary button is inside the window, also at a small size.
    @Test(arguments: [CGSize(width: 1100, height: 720), CGSize(width: 700, height: 500)])
    func titleAndFooterStayPutAndFitTheWindow(size: CGSize) async throws {
        MainRunLoopGuard.start
        let hosted = host(size: size)
        defer { tearDown(hosted) }
        let (state, window) = (hosted.state, hosted.window)
        let view = try #require(window.contentView)

        // The step column's x range, from the same layout the view uses (the row is centred).
        let inner = CGSize(width: size.width,
                           height: size.height - OnboardingLayout.topPadding - OnboardingLayout.bottomPadding)
        let layout = OnboardingLayout(size: inner)
        #expect(layout.showsOrb == (size.width >= 1000))
        let left = (size.width - layout.orbSideWidth - layout.gap - layout.columnWidth) / 2 + layout.orbSideWidth + layout.gap
        let columnXs = left...(left + layout.columnWidth)

        var tops: [CGFloat] = []
        var bottoms: [CGFloat] = []
        for step in OnboardingStep.allCases {
            try await settle(window)
            try await Task.sleep(for: .milliseconds(400)) // the crossfade between steps
            #expect(state.onboarding?.step == step)
            let drawn = try #require(try ink(of: view, xs: columnXs), "nothing drawn on \(step)")
            tops.append(drawn.top)
            bottoms.append(drawn.bottom)
            // The footer ends well inside the window, and its right end (the primary button's
            // bezel, drawn a few points inside its frame) reaches the column's right edge
            // without going past the window's.
            #expect(drawn.bottom <= size.height - 16, "footer cut off on \(step): \(drawn.bottom)")
            #expect(drawn.top >= OnboardingLayout.topPadding, "title under the title bar on \(step): \(drawn.top)")
            #expect(drawn.bottomRight >= columnXs.upperBound - 12 && drawn.bottomRight <= size.width - 16,
                    "primary button not at the column's right edge on \(step): \(drawn.bottomRight)")
            state.advanceWelcome()
        }
        // The title's top may differ by its first letter's overshoot ("C" rises a little above "W").
        #expect(tops.max()! - tops.min()! <= 1, "title moved between steps: \(tops)")
        #expect(Set(bottoms).count == 1, "footer moved between steps: \(bottoms)")
        try await settle(window)
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
