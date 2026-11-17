import AppKit
@testable import Singularity
import SingularityCore
import SwiftUI
import Testing

extension AppTests {
    /// Not a check: with SG_PALETTE_SNAPSHOT=<folder> it writes `palette-light.png` and
    /// `palette-dark.png`, the command palette over a light sidebar and a dark page, to look at
    /// its colours and place without putting a window on screen.
    @MainActor
    @Suite struct PaletteSnapshotTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PALETTE_SNAPSHOT"] != nil))
        func snapshot() async throws {
            _ = MainRunLoopGuard.start
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SG_PALETTE_SNAPSHOT"]!)
            let root = TestAppState.makeRoot()
            let state = TestAppState.make(root: root)
            defer {
                TestAppState.shutDown(state)
                try? FileManager.default.removeItem(at: root)
            }
            let size = NSSize(width: 1200, height: 640)
            let frame = PaletteLayout.frame(windowWidth: size.width, pageLeading: 260, pageTrailing: 8)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let backdrop = HStack(spacing: 0) {
                    Color(nsColor: .windowBackgroundColor).frame(width: 260)
                    Color(red: 0.1, green: 0.1, blue: 0.1)
                }
                let root = ZStack { backdrop; CommandPaletteView(mode: .newTab, frame: frame) }
                    .frame(width: size.width, height: size.height)
                    .environment(state)
                let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let hosting = NSHostingView(rootView: root)
                window.contentView = hosting
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(500))
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appending(path: "palette-\(name).png"))
                window.orderOut(nil)
            }
        }
    }
}
