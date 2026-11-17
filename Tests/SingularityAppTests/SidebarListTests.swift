import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The sidebar's tab list through the AppKit outline view SwiftUI builds for it: dragging a tab
/// between Pinned, a folder and Tabs, and clicking a folder. No input is sent and no window is
/// made key: the tests call the outline view's data source and delegate the way a drag or a
/// click would.
@MainActor
@Suite(.serialized) struct SidebarListTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let window: NSWindow
        let outline: NSOutlineView
        let pinned: UUID, inFolder: UUID, open: UUID
        let folder: UUID
        var space: Space { state.selectedSpace! }
    }

    /// Rows: 0 "Pinned", 1 the pinned tab, 2 "Folders", 3 folder F, 4 its tab, 5 "Tabs", 6 and 7
    /// the open tabs. The open tab in row 6 is selected (no page loads: nothing is shown).
    func make() async throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        var space = Space(name: "Music", slug: "music", colorHex: "#5E81F4", workingDirectory: "~/Developer")
        let pinned = BrowserTab.web(URL(string: "https://pinned.example/")!, title: "Pinned")
        space.append(pinned)
        space.moveTab(pinned.id, to: .pinned)
        let folder = Folder(name: "F")
        space.folders.append(folder)
        let inFolder = BrowserTab.web(URL(string: "https://infolder.example/")!, title: "In folder")
        space.append(inFolder)
        space.moveTab(inFolder.id, to: .folder(folder.id))
        let open = BrowserTab.web(URL(string: "https://open.example/")!, title: "Open")
        space.append(open)
        space.append(BrowserTab.web(URL(string: "https://open2.example/")!, title: "Open 2"))
        space.selectedTabID = nil
        try SpaceStore(paths: Paths(root: root)).save(space)
        let state = TestAppState.make(root: root)
        state.mutateSpace(state.selectedSpaceID!) { $0.selectedTabID = open.id } // selected, but not loaded

        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 270, height: 520),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SidebarView().environment(state).frame(width: 270, height: 520))
        window.orderFront(nil) // in front of nothing on screen; never made key or active
        try await Task.sleep(for: .milliseconds(500))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let outline = try #require(all(window.contentView!).compactMap { $0 as? NSOutlineView }.first)
        #expect(outline.numberOfRows == 8)
        return Fixture(root: root, state: state, window: window, outline: outline,
                       pinned: pinned.id, inFolder: inFolder.id, open: open.id, folder: folder.id)
    }

    func finish(_ f: Fixture) {
        f.window.close()
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    static var sessions: [NSDraggingSession] = []

    /// What the outline view, as the drag's source, allows for a drag that stays in the app.
    /// (`draggingSourceOperationMaskForLocal:` is what NSTableView's own
    /// `draggingSession(_:sourceOperationMaskFor:)` answers with; SwiftUI doesn't override it.)
    func localSourceMask(_ outline: NSOutlineView) -> NSDragOperation {
        typealias Getter = @convention(c) (AnyObject, Selector, ObjCBool) -> UInt
        let selector = NSSelectorFromString("draggingSourceOperationMaskForLocal:")
        guard let method = class_getInstanceMethod(type(of: outline), selector) else { return [] }
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return NSDragOperation(rawValue: getter(outline, selector, true))
    }

    /// Drags row `fromRow` onto `item`'s child `index` as AppKit would: the drop happens only when
    /// the source's operations and the destination's proposal have one in common. With `perform`
    /// false it only asks whether the drop would happen: a drop *on* a row goes through SwiftUI's
    /// `onDrop`, which AppKit lets read the drag's data only during a real drag.
    @discardableResult
    func drag(_ f: Fixture, fromRow: Int, toRow: Int, childIndex: Int, perform: Bool = true) async throws -> Bool {
        let dataSource = try #require(f.outline.dataSource)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sg-test-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let writer = try #require(dataSource.outlineView?(f.outline, pasteboardWriterForItem: f.outline.item(atRow: fromRow) as Any))
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        // The drag begins: SwiftUI notes which rows it carries (that is how it knows a reorder).
        // A bare session object (AppKit makes real ones only for a real mouse drag). Never freed:
        // freeing one that AppKit didn't set up crashes.
        let session = class_createInstance(NSDraggingSession.self, 0) as! NSDraggingSession
        Self.sessions.append(session)
        let draggedItem = f.outline.item(atRow: fromRow) as Any
        dataSource.outlineView?(f.outline, draggingSession: session, willBeginAt: .zero, forItems: [draggedItem])
        defer { dataSource.outlineView?(f.outline, draggingSession: session, endedAt: .zero, operation: []) }
        let info = StubDrag(pasteboard: pasteboard, source: f.outline, window: f.window, mask: localSourceMask(f.outline))
        let item = f.outline.item(atRow: toRow)
        let proposed = dataSource.outlineView?(f.outline, validateDrop: info, proposedItem: item, proposedChildIndex: childIndex) ?? []
        guard !proposed.intersection(info.draggingSourceOperationMask).isEmpty else { return false }
        guard perform else { return true }
        let accepted = dataSource.outlineView?(f.outline, acceptDrop: info, item: item, childIndex: childIndex) ?? false
        try await Task.sleep(for: .milliseconds(300)) // the item provider hands its data over asynchronously
        return accepted
    }

    @Test func aTabMovesBetweenPinnedFoldersAndTabs() async throws {
        let f = try await make()
        defer { finish(f) }

        // The pinned tab to the end of Tabs.
        #expect(try await drag(f, fromRow: 1, toRow: 5, childIndex: 2))
        #expect(f.space.tab(f.pinned)?.section == .open)
        #expect(f.space.sidebarItems(in: .open).last == .tab(f.pinned))
        try await Task.sleep(for: .milliseconds(300)) // the list catches up: Pinned is gone

        // Rows now: 0 "Folders", 1 folder F, 2 its tab, 3 "Tabs", 4…6 the open tabs.
        // An open tab into the folder, as its first row.
        #expect(f.outline.numberOfRows == 7)
        #expect(try await drag(f, fromRow: 4, toRow: 1, childIndex: 0))
        #expect(f.space.tab(f.open)?.section == .folder(f.folder))
        #expect(f.space.sidebarItems(in: .folder(f.folder)).first == .tab(f.open))
    }

    @Test func aTabCanBeDroppedOnAFolder() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(try await drag(f, fromRow: 1, toRow: 3, childIndex: NSOutlineViewDropOnItemIndex, perform: false))
    }

    @Test func anEmptyTabsSectionShowsWhereToDrop() async throws {
        let f = try await make()
        defer { finish(f) }
        f.state.moveTab(f.open, to: .pinned)
        f.state.moveTab(f.space.sidebarItems(in: .open)[0].tabIDs[0], to: .pinned)
        try await Task.sleep(for: .milliseconds(300))
        // Rows: 0 "Pinned", 1…3 the pinned tabs, 4 "Folders", 5 F, 6 its tab, 7 "Tabs".
        #expect(f.outline.numberOfRows == 8)
        NotificationCenter.default.post(name: TabDragSession.didBegin, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.outline.numberOfRows == 9)
        #expect(try await drag(f, fromRow: 6, toRow: 8, childIndex: NSOutlineViewDropOnItemIndex, perform: false))
        NotificationCenter.default.post(name: TabDragSession.didEnd, object: nil)
    }

    @Test func withNothingPinnedADragShowsWhereToPin() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(try await drag(f, fromRow: 1, toRow: 5, childIndex: 0)) // nothing pinned now
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.outline.numberOfRows == 7)

        // A tab drag begins: "Pinned" and its one row appear at the top of the list.
        NotificationCenter.default.post(name: TabDragSession.didBegin, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.outline.numberOfRows == 9)
        // Rows: 0 "Pinned", 1 "Drop here to pin", 2 "Folders", 3 F, 4 its tab, 5 "Tabs", 6…8.
        #expect(try await drag(f, fromRow: 6, toRow: 1, childIndex: NSOutlineViewDropOnItemIndex, perform: false))
        NotificationCenter.default.post(name: TabDragSession.didEnd, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.outline.numberOfRows == 7)
    }

    @Test func reorderingWithinASectionStillWorks() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(try await drag(f, fromRow: 7, toRow: 5, childIndex: 0))
        #expect(f.space.sidebarItems(in: .open).first != .tab(f.open))
        #expect(f.space.sidebarItems(in: .open).count == 2)
    }

    @Test func clickingAFolderTogglesItAndKeepsTheTab() async throws {
        let f = try await make()
        defer { finish(f) }
        let delegate = try #require(f.outline.delegate)
        // A click asks the delegate whether the row may be selected: never the folder's.
        #expect(delegate.outlineView?(f.outline, shouldSelectItem: f.outline.item(atRow: 3) as Any) == false)
        // Its tab, inside it, and the other tabs still can be.
        #expect(delegate.outlineView?(f.outline, shouldSelectItem: f.outline.item(atRow: 4) as Any) == true)
        #expect(delegate.outlineView?(f.outline, shouldSelectItem: f.outline.item(atRow: 1) as Any) == true)

        // Even if the folder's row became the selection, no tab that isn't one gets selected.
        f.outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.space.selectedTabID == f.open)

        // The click itself folds and unfolds it.
        f.state.toggleFolder(f.folder)
        #expect(f.space.folders.first?.isExpanded == false)
        f.state.toggleFolder(f.folder)
        #expect(f.space.folders.first?.isExpanded == true)
        #expect(f.space.selectedTabID == f.open)
    }
}
}

/// The parts of a drag that the outline view's data source reads.
@MainActor
final class StubDrag: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard: NSPasteboard
    let source: Any?
    let window: NSWindow
    let mask: NSDragOperation
    init(pasteboard: NSPasteboard, source: Any?, window: NSWindow, mask: NSDragOperation) {
        self.pasteboard = pasteboard
        self.source = source
        self.window = window
        self.mask = mask
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { NSPoint(x: 50, y: 50) }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
