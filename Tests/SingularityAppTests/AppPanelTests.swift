import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The app's panel (the button at the right of the address row, and what it opens), laid out in
/// an off-screen window that is never made key. No Worker runs here: the panel only reads the
/// Space's record, the key store and the Worker's status.
@MainActor
@Suite(.serialized) struct AppPanelTests {
    struct Fixture {
        let root: URL
        let state: AppState
        let keys: MemoryAppKeyStore
        let space: Space
        let appTab: BrowserTab
        let plainTab: BrowserTab
        let webTab: BrowserTab
    }

    /// A Space with three tabs: a page of the app `firma`, a plain artifact, and a web page.
    /// The app has one allowed host and one key. Nothing is loaded and no server runs.
    private func makeFixture() throws -> Fixture {
        MainRunLoopGuard.start
        let fm = FileManager.default
        let root = TestAppState.makeRoot()
        let paths = Paths(root: root)
        let artifacts = paths.artifactsDirectory("work")
        for folder in ["firma", "plain"] {
            try fm.createDirectory(at: artifacts.appending(path: folder), withIntermediateDirectories: true)
            try Data("<p>page</p>".utf8).write(to: artifacts.appending(path: "\(folder)/index.html"))
        }
        try Data("{}".utf8).write(to: artifacts.appending(path: "firma/wrangler.jsonc"))

        let appTab = BrowserTab.artifact(path: "firma/index.html")
        let plainTab = BrowserTab.artifact(path: "plain/index.html")
        let webTab = BrowserTab.web(URL(string: "about:blank")!, title: "web")
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", tabs: [appTab, plainTab, webTab])
        space.apps["firma"] = AppRecord(hosts: ["api.example.com"], keys: [AppKey(name: "API_KEY", host: "api.example.com")])
        let store = SpaceStore(paths: paths)
        try store.save(space)
        try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))

        let keys = MemoryAppKeyStore()
        try keys.set("s3cr3t-value-never-shown", space: space.id, app: "firma", name: "API_KEY")
        let state = TestAppState.make(root: root, keys: keys)
        return Fixture(root: root, state: state, keys: keys, space: space, appTab: appTab, plainTab: plainTab, webTab: webTab)
    }

    private func tearDown(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    /// Hosts `view` in a window far off screen (never key, never active) and lets SwiftUI lay it out.
    private func host(_ view: some View, size: NSSize) async throws -> (window: NSWindow, view: NSView) {
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The window's own background behind the view, or light text would be drawn on nothing.
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        return (window, hosting)
    }

    /// Every view below `view`, itself included.
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @Test func theButtonIsOnlyForATabThatShowsAnApp() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        #expect(AppPanelButton.app(of: f.appTab, in: f.space, state: f.state) == "firma")
        #expect(AppPanelButton.app(of: f.plainTab, in: f.space, state: f.state) == nil)
        #expect(AppPanelButton.app(of: f.webTab, in: f.space, state: f.state) == nil)
        #expect(AppPanelButton.app(of: nil, in: f.space, state: f.state) == nil)
    }

    @Test func thePanelNeverShowsAKeysValueAndHasNoDefaultButton() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let (window, view) = try await host(AppPanel(spaceID: f.space.id, app: "firma").environment(f.state),
                                            size: NSSize(width: 340, height: 620))
        defer { window.close() }
        let views = descendants(of: view)

        // The value is typed into a secure field (dots on screen), which starts empty.
        let secure = views.compactMap { $0 as? NSSecureTextField }
        #expect(secure.count == 1)
        #expect(secure.first?.stringValue == "")
        // Nothing on the panel holds the stored value.
        for field in views.compactMap({ $0 as? NSTextField }) {
            #expect(!field.stringValue.contains("s3cr3t"))
        }
        // Return typed anywhere must not press Allow, Add or Save.
        #expect(window.defaultButtonCell == nil)
        #expect(!window.isKeyWindow)

        // Something was drawn (SwiftUI gives no way to read its text back).
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["SG_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(filePath: folder).appending(path: "app-panel.png"))
        }
        let first = rep.colorAt(x: 2, y: 2)
        var drawn = false
        for x in stride(from: 4, to: rep.pixelsWide, by: 9) {
            for y in stride(from: 4, to: rep.pixelsHigh, by: 9) where rep.colorAt(x: x, y: y) != first { drawn = true }
        }
        #expect(drawn)
    }

    @Test func thePanelsWords() throws {
        #expect(AppPanel.workerText(AppWorkerStatus(running: true)) == "Worker is running")
        #expect(AppPanel.workerText(AppWorkerStatus()) == "Worker is stopped")
        #expect(AppPanel.workerText(AppWorkerStatus(running: false, lastError: "worker.ts: oops")) == "Worker could not run")
        // A Worker that runs again after an error is running.
        #expect(AppPanel.workerText(AppWorkerStatus(running: true, lastError: "old")) == "Worker is running")

        let record = AppRecord(hosts: [], keys: [AppKey(name: "API_KEY", host: "api.example.com")])
        #expect(AppPanel.valuePrompt(record, name: "API_KEY") == "Value (leave empty to keep it)")
        #expect(AppPanel.valuePrompt(record, name: " API_KEY ") == "Value (leave empty to keep it)")
        #expect(AppPanel.valuePrompt(record, name: "OTHER") == "Value")

        let folder = FileManager.default.temporaryDirectory.appending(path: "sg-panel-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(AppPanel.dataText(folder).hasPrefix("No database yet"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(AppPanel.dataText(folder).hasPrefix("No database (the app's wrangler.jsonc names none)"))
        try Data(count: 4096).write(to: folder.appending(path: "DB.sqlite"))
        try Data("log".utf8).write(to: folder.appending(path: "worker.log"))
        #expect(AppPanel.dataText(folder).hasPrefix("DB.sqlite ("))
        #expect(!AppPanel.dataText(folder).contains("worker.log"))
    }

    @Test func thePanelsChangesReachTheRecordAndTheStore() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let apps = f.state.apps
        apps.allowHost("other.example.com", space: f.space.id, app: "firma")
        apps.allowHost("not a host", space: f.space.id, app: "firma")          // refused
        #expect(apps.record(space: f.space.id, app: "firma").hosts == ["api.example.com", "other.example.com"])
        apps.removeHost("api.example.com", space: f.space.id, app: "firma")
        #expect(apps.record(space: f.space.id, app: "firma").hosts == ["other.example.com"])

        // Changing a key's switch without typing the value again keeps the value.
        try apps.setKey(name: "API_KEY", host: "api.example.com", readable: true, value: nil, space: f.space.id, app: "firma")
        #expect(f.keys.value(space: f.space.id, app: "firma", name: "API_KEY") == "s3cr3t-value-never-shown")
        #expect(apps.record(space: f.space.id, app: "firma").keys == [AppKey(name: "API_KEY", host: "api.example.com", readable: true)])
        // A key's host is allowed with it.
        #expect(apps.record(space: f.space.id, app: "firma").hosts.contains("api.example.com"))

        apps.deleteKey(name: "API_KEY", space: f.space.id, app: "firma")
        #expect(f.keys.count == 0)
        #expect(apps.record(space: f.space.id, app: "firma").keys.isEmpty)

        // An app with nothing allowed is not listed in the Space's file.
        apps.removeHost("other.example.com", space: f.space.id, app: "firma")
        apps.removeHost("api.example.com", space: f.space.id, app: "firma")
        #expect(f.state.space(f.space.id)?.apps["firma"] == nil)
    }

    @Test func settingsListsAnAppWhoseFolderIsGone() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let paths = Paths(root: f.root)
        // Data left behind by an app whose folder no longer exists, one level down.
        let orphan = paths.appDataDirectory("work", app: "tools/old")
        try FileManager.default.createDirectory(at: orphan.appending(path: "tmp"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: orphan.appending(path: "DB.sqlite"))

        #expect(f.state.apps.knownApps(space: f.space.id) == [
            KnownApp(path: "firma", folderExists: true, hasRecord: true, hasData: false),
            KnownApp(path: "tools/old", folderExists: false, hasRecord: false, hasData: true),
        ])
        // The app's folder goes: its hosts and keys stay until the owner forgets them.
        try FileManager.default.removeItem(at: paths.artifactsDirectory("work").appending(path: "firma"))
        #expect(f.state.apps.knownApps(space: f.space.id).first == KnownApp(path: "firma", folderExists: false, hasRecord: true, hasData: false))
        #expect(f.keys.count == 1)

        f.state.apps.deleteData(space: f.space.id, app: "tools/old")
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        f.state.apps.forget(space: f.space.id, app: "firma")
        #expect(f.state.apps.knownApps(space: f.space.id).isEmpty)
        #expect(f.keys.count == 0)
    }
}
}
