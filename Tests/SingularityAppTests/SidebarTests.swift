import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The sidebar through the real `AppState`: launchers, Space icons, hiding. No test here starts
/// a shell (a launcher's command is only ever *registered* for a tab), makes a window key, or
/// runs `claude` / `codex`. Run with `SG_SNAPSHOT_DIR=/some/folder` to get PNGs of the views.
@MainActor
@Suite(.serialized) struct SidebarStateTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        var space: Space { state.selectedSpace! }
    }

    /// One Space "Music" with two projects and a web page in Tabs. Nothing is selected, so no
    /// page loads and no shell starts.
    func make(projects: Bool = true) throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        var space = Space(name: "Music", slug: "music", colorHex: "#5E81F4", workingDirectory: "~/Developer",
                          projects: projects ? [Project(name: "web", path: "~/Developer/web"), Project(name: "docs", path: "~/Developer/docs")] : [])
        space.append(BrowserTab.web(URL(string: "https://example.com/")!, title: "Example"))
        space.selectedTabID = nil
        try SpaceStore(paths: Paths(root: root)).save(space)
        return Fixture(root: root, state: TestAppState.make(root: root))
    }

    func finish(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    func render(_ view: some View, size: NSSize, name: String) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFront(nil) // in front of nothing on screen; never made key or active
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["SG_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
        }
        return rep
    }

    func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        let first = rep.colorAt(x: 2, y: 2)
        for x in stride(from: 4, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 4, to: rep.pixelsHigh, by: 7) where rep.colorAt(x: x, y: y) != first { return true }
        }
        return false
    }

    // MARK: Launchers

    @Test func aLauncherAsksForTheProjectAndThePickerKeepsIt() throws {
        let f = try make()
        defer { finish(f) }
        let claude = try #require(f.state.launchers.first)
        #expect(claude.command == "claude")
        f.state.openTerminal(launcher: claude)
        // The Space has projects and the terminal would land in no folder: the picker asks, and
        // carries the launcher, so the choice starts Claude Code and not a plain terminal.
        #expect(f.state.palette == .newTerminalIn(folderID: nil, adoptForFolder: false, launcherID: claude.id))
        #expect(f.space.tabs.count == 1)
        #expect(f.state.pendingCommands.isEmpty)
    }

    @Test func aLaunchersCommandIsHandedOverOnce() throws {
        let f = try make()
        defer { finish(f) }
        let tab = UUID()
        f.state.setPendingCommand(Launcher(name: "Two lines", command: " echo a\necho b "), for: tab)
        #expect(f.state.takePendingCommand(tab) == "echo a echo b")
        // A restarted shell, or a herdr-core tab finding its shell again, asks too and gets nothing.
        #expect(f.state.takePendingCommand(tab) == nil)
        // No launcher, or one without a command: nothing is registered.
        f.state.setPendingCommand(nil, for: tab)
        f.state.setPendingCommand(Launcher(name: "Empty", command: "  "), for: tab)
        #expect(f.state.pendingCommands.isEmpty)
    }

    @Test func halfTypedLaunchersAreNotButtons() throws {
        let f = try make()
        defer { finish(f) }
        f.state.updateSettings { $0.launchers.append(Launcher(name: "New", command: "")) }
        #expect(f.state.settings.launchers.count == 3)
        #expect(f.state.launchers.map(\.command) == ["claude", "codex"])
    }

    @Test func bothLogosAreReadable() {
        for name in Launcher.logoNames {
            let image = LauncherLogos.image(name)
            #expect(image != nil, "the \(name) logo")
            #expect((image?.size.width ?? 0) > 0)
            #expect(image?.isTemplate == true)
        }
        #expect(LauncherLogos.image("nothing") == nil)
    }

    /// Opt-in (`SG_REAL_SHELL=1`, skipped by `scripts/test.sh`): starts the owner's login shell
    /// off screen with a launcher command that appends a line to a file in a temp folder, and
    /// checks the line arrives exactly once, also after the shell is replaced as Return-after-exit
    /// replaces it. Nothing but that temp file is written.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_REAL_SHELL"] != nil))
    func aRealShellGetsTheCommandTypedOnce() async throws {
        MainRunLoopGuard.start
        let folder = TestAppState.makeRoot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "typed.txt")
        func lines() -> Int {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let first = TerminalSession(tabID: UUID(), spaceID: UUID(), spaceSlug: "test", workingDirectory: folder.path,
                                    font: font, state: nil, initialCommand: "echo typed >> '\(file.path)'")
        try await waitUntil("the command to be typed", limit: .seconds(20)) { lines() >= 1 }
        try await Task.sleep(for: .seconds(1))
        #expect(lines() == 1)
        first.tearDown()
        // A shell without a command (a restart, a restored tab) types nothing.
        let second = TerminalSession(tabID: UUID(), spaceID: UUID(), spaceSlug: "test", workingDirectory: folder.path,
                                     font: font, state: nil)
        await second.waitUntilReady()
        try await Task.sleep(for: .seconds(1))
        second.tearDown()
        #expect(lines() == 1)
    }

    // MARK: Space icons

    @Test func aSpaceIconIsOneEmojiAndIsSaved() throws {
        let f = try make()
        defer { finish(f) }
        f.state.setSpaceIcon("🎧", spaceID: f.space.id)
        #expect(f.space.icon == "🎧")
        f.state.setSpaceIcon("headphones", spaceID: f.space.id)
        #expect(f.space.icon == nil)
        f.state.setSpaceIcon("🎸", spaceID: f.space.id)
        f.state.flushSaves()
        let saved = SpaceStore(paths: Paths(root: f.root)).load().spaces.first
        #expect(saved?.icon == "🎸")
        #expect(saved?.slug == "music")
    }

    // MARK: Hiding

    @Test func hidingTheSidebar() throws {
        let f = try make()
        defer { finish(f) }
        #expect(!f.state.sidebarIsOffScreen)
        #expect(f.state.inbox.trayIsOnScreen())
        f.state.toggleSidebar()
        #expect(f.state.settings.sidebarHidden)
        #expect(f.state.sidebarIsOffScreen)
        // The inbox panel then opens at the window's corner, not beside a button that is off screen.
        #expect(!f.state.inbox.trayIsOnScreen())
        // No window is key in a test, so the pointer "reaching the edge" must not slide it out.
        f.state.sidebarPeek.pointerReachedEdge()
        #expect(!f.state.sidebarPeek.isPeeking)
        // The welcome flow covers the window: it keeps its buttons, and nothing slides out.
        f.state.showWelcome()
        #expect(!f.state.sidebarIsOffScreen)
        f.state.closeWelcome()
        f.state.toggleSidebar()
        #expect(!f.state.settings.sidebarHidden)
        f.state.flushSaves()
        #expect(SpaceStore(paths: Paths(root: f.root)).loadSettings().sidebarHidden == false)
    }

    @Test func theWidthIsClampedWhileDragged() throws {
        let f = try make()
        defer { finish(f) }
        #expect(f.state.sidebarWidth == 270)
        f.state.sidebarPeek.liveWidth = 9000
        #expect(f.state.sidebarWidth == 480)
        f.state.sidebarPeek.liveWidth = nil
        f.state.updateSettings { $0.sidebarWidth = 300 }
        #expect(f.state.sidebarWidth == 300)
    }

    // MARK: Views (smoke tests; pictures with SG_SNAPSHOT_DIR)

    @Test func theViewsRender() async throws {
        let f = try make()
        defer { finish(f) }
        f.state.setSpaceIcon("🎧", spaceID: f.space.id)
        f.state.updateSettings {
            $0.launchers.append(Launcher(name: "Yolo", command: "claude --dangerously-skip-permissions", icon: "🔥"))
            $0.launchers.append(Launcher(name: "opencode", command: "opencode"))
            $0.launchers.append(Launcher(name: "Fifth", command: "echo five"))
        }
        let state = f.state
        #expect(hasContent(try await render(SidebarView().environment(state), size: NSSize(width: 270, height: 520), name: "sidebar-launchers")))
        #expect(hasContent(try await render(SidebarView().environment(state), size: NSSize(width: 220, height: 520), name: "sidebar-narrow")))
        #expect(hasContent(try await render(MainView().environment(state), size: NSSize(width: 900, height: 560), name: "main-shown")))
        state.toggleSidebar()
        #expect(hasContent(try await render(MainView().environment(state), size: NSSize(width: 900, height: 560), name: "main-hidden")))
        state.sidebarPeek.isPeeking = true // as if the pointer were at the edge
        #expect(!state.sidebarIsOffScreen)
        #expect(hasContent(try await render(MainView().environment(state), size: NSSize(width: 900, height: 560), name: "main-slid-out")))
        state.sidebarPeek.close()
        state.toggleSidebar()
        #expect(hasContent(try await render(Form { LaunchersEditor() }.formStyle(.grouped).environment(state),
                                            size: NSSize(width: 600, height: 360), name: "launchers-editor")))
        #expect(hasContent(try await render(AgentActivitySheet(space: f.space).environment(state),
                                            size: NSSize(width: 460, height: 460), name: "agent-activity")))
        let request = SpaceEditorRequest(spaceID: state.selectedSpaceID)
        #expect(hasContent(try await render(SpaceEditorSheet(request: request).environment(state),
                                            size: NSSize(width: 420, height: 560), name: "space-editor-icon")))
    }
}
}
