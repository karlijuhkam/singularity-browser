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

        let window = NeverKeyWindow(contentRect: NSRect(x: -5000, y: -5000, width: 270, height: 520),
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
    /// With `settle`, the List gets a moment after the drag began (and may add rows, as it does
    /// for an empty Pinned section) before `toRow` is read, as in a real drag.
    func drag(_ f: Fixture, fromRow: Int, toRow: @autoclosure () -> Int, childIndex: Int, perform: Bool = true,
              settle: Bool = false) async throws -> Bool {
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
        if settle { try await Task.sleep(for: .milliseconds(100)) }
        let info = StubDrag(pasteboard: pasteboard, source: f.outline, window: f.window, mask: localSourceMask(f.outline))
        let item = f.outline.item(atRow: toRow())
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
        // The list catches up: Pinned is gone. (Waited for, not a fixed pause: a busy Mac, e.g.
        // during a release's build, once needed more than 300 ms.)
        for _ in 0..<30 where f.outline.numberOfRows != 7 {
            try await Task.sleep(for: .milliseconds(100))
        }

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

    @Test func whileTheListAddsPinnedTheDropStillLands() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(try await drag(f, fromRow: 1, toRow: 5, childIndex: 2)) // nothing pinned now
        try await Task.sleep(for: .milliseconds(400))
        #expect(f.outline.numberOfRows == 7)
        // The drag of an open tab begins; the List adds "Pinned" and its row before the drop.
        // Rows then: 0 "Pinned", 1 its drop row, 2 "Folders", 3 F, 4 its tab, 5 "Tabs", 6…8.
        var rowsDuringDrag = 0
        // Before it: 0 "Folders", 1 F, 2 its tab, 3 "Tabs", 4 Open, 5 Open 2, 6 Pinned.
        #expect(try await drag(f, fromRow: 4, toRow: { rowsDuringDrag = f.outline.numberOfRows; return 3 }(),
                               childIndex: 1, settle: true))
        #expect(rowsDuringDrag == 9)
        #expect(f.space.tab(f.open)?.section == .folder(f.folder))
        #expect(f.space.sidebarItems(in: .folder(f.folder)).last == .tab(f.open))
    }

    @Test func aSplitsRowMovesWithinItsSectionAndToAnother() async throws {
        let f = try await make()
        defer { finish(f) }
        let open2 = f.space.sidebarItems(in: .open)[1].tabIDs[0]
        let third = BrowserTab.web(URL(string: "https://third.example/")!, title: "Third")
        f.state.mutateSpace(f.state.selectedSpaceID!) {
            _ = $0.split(open2, beside: f.open, edge: .right)
            $0.append(third)
        }
        try await Task.sleep(for: .milliseconds(300))
        // Rows: … 5 "Tabs", 6 the split, 7 Third.
        #expect(f.outline.numberOfRows == 8)
        #expect(try await drag(f, fromRow: 6, toRow: 5, childIndex: 2))
        #expect(f.space.sidebarItems(in: .open).map(\.tabIDs.count) == [1, 2])
        #expect(f.space.sidebarItems(in: .open).first == .tab(third.id))
        // Into folder F, as its first row: both of its tabs go, and it stays a split.
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await drag(f, fromRow: 7, toRow: 3, childIndex: 0))
        #expect(f.space.splitGroup(containing: f.open) != nil)
        #expect(f.space.tab(f.open)?.section == .folder(f.folder))
        #expect(f.space.tab(open2)?.section == .folder(f.folder))
        #expect(f.space.sidebarItems(in: .folder(f.folder)).map(\.tabIDs.count) == [2, 1])
        #expect(f.space.sidebarItems(in: .open) == [.tab(third.id)])
    }

    @Test func withNothingPinnedASplitsRowCanBePinned() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(try await drag(f, fromRow: 1, toRow: 5, childIndex: 0)) // nothing pinned now
        let open2 = f.space.sidebarItems(in: .open)[2].tabIDs[0]
        f.state.mutateSpace(f.state.selectedSpaceID!) { _ = $0.split(open2, beside: f.open, edge: .right) }
        // Rows: 0 "Folders", 1 F, 2 its tab, 3 "Tabs", 4 Pinned (now open), 5 the split.
        for _ in 0..<30 where f.outline.numberOfRows != 6 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(f.outline.numberOfRows == 6)
        // The split's row is dragged: "Pinned" and its drop row appear at the top, and that row
        // takes the drop. Rows then: 0 "Pinned", 1 "Drop here to pin", 2 "Folders", …
        // (Only asked, not dropped: a drop *on* a row goes through SwiftUI's `onDrop`, which can
        // read the drag's data only in a real drag; see `drag`.)
        var rowsDuringDrag = 0
        let wouldLand = try await drag(f, fromRow: 5, toRow: { rowsDuringDrag = f.outline.numberOfRows; return 1 }(),
                                       childIndex: NSOutlineViewDropOnItemIndex, perform: false, settle: true)
        #expect(rowsDuringDrag == 8)
        #expect(wouldLand)
        // What that row does with the split's payload: the whole split is pinned.
        let groupID = try #require(f.space.splitGroup(containing: f.open)?.id)
        f.state.moveDropped(.split(groupID: groupID), to: .pinned, atRow: .max)
        #expect(f.space.tab(f.open)?.section == .pinned)
        #expect(f.space.tab(open2)?.section == .pinned)
        #expect(f.space.splitGroup(containing: f.open) != nil)
    }

    @Test func aSplitsRowDragLeavesThePanesDropLayersDown() async throws {
        MainRunLoopGuard.start
        let pane = PaneContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        pane.onDrop = { _, _ in }
        func hasOverlay() -> Bool { pane.subviews.contains { $0 is PaneDropOverlay } }
        func waitForEnd() async throws {
            // The session ends on a timer once no mouse button is down (none is, in a test).
            var ended = false
            let token = NotificationCenter.default.addObserver(forName: TabDragSession.didEnd, object: nil, queue: nil) { _ in ended = true }
            defer { NotificationCenter.default.removeObserver(token) }
            for _ in 0..<30 where !ended { try await Task.sleep(for: .milliseconds(100)) }
        }

        TabDragSession.begin(raisesPanes: false)
        #expect(!hasOverlay())
        try await waitForEnd()
        TabDragSession.begin()
        #expect(hasOverlay())
        try await waitForEnd()
        #expect(!hasOverlay())
    }

    @Test func aDropInAFolderCountsItsTabsNotItsFolders() async throws {
        let f = try await make()
        defer { finish(f) }
        let second = BrowserTab.web(URL(string: "https://second.example/")!, title: "Second")
        f.state.mutateSpace(f.state.selectedSpaceID!) {
            $0.append(second)
            $0.moveTab(second.id, to: .folder(f.folder))
        }
        _ = f.state.createFolder(named: "Inner", inside: f.folder)
        try await Task.sleep(for: .milliseconds(300))
        // Rows: 3 F, 4 Inner, 5 its first tab, 6 Second, 7 "Tabs", 8 Open, 9 Open 2.
        #expect(f.outline.numberOfRows == 10)
        // Open dropped after F's first tab: F's third child in the outline, its second tab row.
        #expect(try await drag(f, fromRow: 8, toRow: 3, childIndex: 2))
        #expect(f.space.sidebarItems(in: .folder(f.folder)) == [.tab(f.inFolder), .tab(f.open), .tab(second.id)])
    }

    @Test func reorderingWithinASectionStillWorks() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(try await drag(f, fromRow: 7, toRow: 5, childIndex: 0))
        #expect(f.space.sidebarItems(in: .open).first != .tab(f.open))
        #expect(f.space.sidebarItems(in: .open).count == 2)
    }

    /// The click itself (SwiftUI's tap on the folder's name) can't be sent here: a test window
    /// never becomes key, and the outline view takes no click in a window that isn't.
    /// The menu a right-click at `point` (in the outline view's coordinates) would show, as AppKit
    /// finds it: the view under the pointer, then up its superviews, the first that has a menu.
    /// Its item titles, after the menu's delegate filled it in (SwiftUI's are filled when opened).
    func menuTitles(_ f: Fixture, at point: NSPoint) throws -> [String] {
        let inWindow = f.outline.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: inWindow, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: f.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        let frameView = try #require(f.window.contentView?.superview)
        var view = frameView.hitTest(frameView.convert(inWindow, from: nil))
        while let current = view {
            if let menu = current.menu(for: event) {
                menu.delegate?.menuNeedsUpdate?(menu)
                return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            }
            view = current.superview
        }
        return []
    }

    @Test func aRightClickOnEmptySpaceOffersNewTabTerminalAndNote() async throws {
        let f = try await make()
        defer { finish(f) }
        let lastRow = f.outline.rect(ofRow: f.outline.numberOfRows - 1)
        let below = NSPoint(x: lastRow.midX, y: lastRow.maxY + 40)
        #expect(f.outline.bounds.contains(below))
        #expect(f.outline.row(at: below) == -1)
        #expect(try menuTitles(f, at: below) == ["New Tab", "New Terminal", "New Note"])
        // A section's title (row 5, "Tabs") is no tab either.
        let title = f.outline.rect(ofRow: 5)
        #expect(try menuTitles(f, at: NSPoint(x: title.midX, y: title.midY)) == ["New Tab", "New Terminal", "New Note"])

        // A tab's row keeps its own menu, without these three.
        let tabRow = f.outline.rect(ofRow: 6)
        let titles = try menuTitles(f, at: NSPoint(x: tabRow.midX, y: tabRow.midY))
        #expect(titles.contains("Move to Folder"))
        #expect(!titles.contains("New Note"))
        // And so does a folder's.
        let folderRow = f.outline.rect(ofRow: 3)
        let folderTitles = try menuTitles(f, at: NSPoint(x: folderRow.midX, y: folderRow.midY))
        #expect(folderTitles.contains("Rename…"))
        #expect(!folderTitles.contains("New Note"))
    }

    @Test func aFoldersRowIsNotSelectableAndItsToggleKeepsTheTab() async throws {
        let f = try await make()
        defer { finish(f) }
        #expect(f.outline.selectedRow == 6)
        let delegate = try #require(f.outline.delegate)
        // The outline view won't select the folder's row; its tab's row and the others still can be.
        #expect(delegate.outlineView?(f.outline, shouldSelectItem: f.outline.item(atRow: 3) as Any) == false)
        #expect(delegate.outlineView?(f.outline, shouldSelectItem: f.outline.item(atRow: 4) as Any) == true)
        #expect(delegate.outlineView?(f.outline, shouldSelectItem: f.outline.item(atRow: 1) as Any) == true)

        // What the click does: the folder folds and unfolds, the tab and its row stay selected.
        f.state.toggleFolder(f.folder)
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.space.folders.first?.isExpanded == false)
        #expect(f.space.selectedTabID == f.open)
        #expect(f.outline.numberOfRows == 7)
        #expect(f.outline.selectedRowIndexes == IndexSet(integer: 5)) // the open tab, one row up now
        f.state.toggleFolder(f.folder)
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.space.folders.first?.isExpanded == true)
        #expect(f.outline.selectedRowIndexes == IndexSet(integer: 6))

        // Even if the folder's row became the selection some other way, no tab that isn't one
        // gets selected (that showed an empty page).
        f.outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.space.selectedTabID == f.open)
    }
}
}

/// A window that can't take the keyboard.
final class NeverKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
