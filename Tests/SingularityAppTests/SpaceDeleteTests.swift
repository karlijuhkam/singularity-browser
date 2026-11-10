import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// Deleting Spaces with the real window on screen (off-screen), before any web page was shown.
/// That once crashed inside WebKit: removing a Space's website data needs WebKit set up first.
@MainActor
@Suite(.serialized) struct SpaceDeleteTests {
    @Test func deletingSpacesBeforeAnyPageWasShown() async throws {
        MainRunLoopGuard.start
        // A short path: the agent socket lives under it, and Unix sockets allow ~100 characters.
        let root = URL(filePath: "/private/tmp/sg-t-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpaceStore(paths: Paths(root: root))
        for name in ["one", "two", "three"] {
            // Nested folders, some open, as an import from Arc leaves them.
            let outer = Folder(name: "Outer"), inner = Folder(name: "Inner", parentID: outer.id)
            var space = Space(name: name, slug: name, colorHex: "#5E81F4", folders: [outer, inner])
            for folder in [outer, inner] {
                var tab = BrowserTab.web(URL(string: "https://example.com/\(folder.name)")!, title: folder.name)
                tab.folderID = folder.id
                space.append(tab)
            }
            try store.save(space)
        }

        let state = AppState(paths: Paths(root: root))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 700),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView().environment(state))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(state.spaces.count == 3)

        // The selected Space, then one that isn't selected. The website data is removed a second
        // after the Space goes, so wait past that: the crash came from there.
        state.deleteSpace(try #require(state.selectedSpaceID))
        try await Task.sleep(for: .seconds(2))
        #expect(state.spaces.count == 2 && state.selectedSpace != nil)
        state.deleteSpace(try #require(state.spaces.last { $0.id != state.selectedSpaceID }).id)
        try await Task.sleep(for: .seconds(2))
        #expect(state.spaces.count == 1)
        // The last Space stays.
        state.deleteSpace(state.spaces[0].id)
        #expect(state.spaces.count == 1)
    }
}
}
