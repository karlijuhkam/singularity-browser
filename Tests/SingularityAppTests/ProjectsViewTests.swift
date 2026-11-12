import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The views that show projects, laid out in off-screen windows: the sidebar (folder header with
/// its project, a terminal with a tag), Edit Space with its Projects list, and the list by itself.
/// These are smoke tests: SwiftUI gives no way to read the drawn text back. Run with
/// `SG_SNAPSHOT_DIR=/some/folder` to also get a PNG of each view to look at.
@MainActor
@Suite(.serialized) struct ProjectsViewTests {
    /// Hosts `view` in a window far off screen, lets SwiftUI lay it out, and returns its drawing.
    func render(_ view: some View, size: NSSize, name: String) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The window's own background colour behind the view, or light text would be drawn on nothing.
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

    /// True when the drawing is not one flat colour (something was drawn).
    func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        let first = rep.colorAt(x: 2, y: 2)
        for x in stride(from: 4, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 4, to: rep.pixelsHigh, by: 7) where rep.colorAt(x: x, y: y) != first { return true }
        }
        return false
    }

    @Test func sidebarAndEditorRender() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = Project(name: "acme-web", path: "~/Developer/acme-web")
        let docs = Project(name: "acme-docs", path: "~/Developer/acme-docs")
        let task = Folder(name: "ACME-412 shift export", projectID: web.id)
        let other = Folder(name: "No project yet")
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~/Developer",
                          folders: [task, other], projects: [web, docs])
        // Nothing is selected, so no page loads and no shell starts.
        var ticket = BrowserTab.web(URL(string: "https://example.com/ACME-412")!, title: "ACME-412: Export shifts as CSV")
        ticket.folderID = task.id
        space.append(ticket)
        for (title, project, folder) in [("claude", web.id, task.id as UUID?), ("claude with quite a long title here", docs.id, task.id),
                                         ("zsh", web.id, nil), ("plain", nil as UUID?, nil)] {
            var tab = BrowserTab.terminal(workingDirectory: "~/Developer")
            tab.title = title
            tab.projectID = project
            tab.folderID = folder
            space.append(tab)
        }
        try SpaceStore(paths: Paths(root: root)).save(space)
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        #expect(state.selectedSpace?.projects.count == 2)

        let sidebar = try await render(SidebarView().environment(state), size: NSSize(width: 270, height: 520), name: "sidebar")
        #expect(hasContent(sidebar))

        let request = SpaceEditorRequest(spaceID: state.selectedSpaceID)
        let sheet = try await render(SpaceEditorSheet(request: request).environment(state), size: NSSize(width: 420, height: 520), name: "edit-space")
        #expect(hasContent(sheet))

        var projects = [web, docs]
        let binding = Binding(get: { projects }, set: { projects = $0 })
        let editor = try await render(ProjectsEditor(projects: binding).padding(), size: NSSize(width: 380, height: 160), name: "projects-editor")
        #expect(hasContent(editor))
        // A very long project name is cut in the middle, so the tag can't take the whole row.
        #expect(ProjectTag.short("acme-web") == "acme-web")
        #expect(ProjectTag.short("acme-web-frontend-monorepo") == "acme-web…monorepo")
        let empty = try await render(ProjectsEditor(projects: .constant([])).padding(), size: NSSize(width: 380, height: 80), name: "projects-editor-empty")
        #expect(hasContent(empty))
    }
}
}
