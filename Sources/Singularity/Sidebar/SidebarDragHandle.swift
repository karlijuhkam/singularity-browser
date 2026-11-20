import AppKit
import SingularityCore
import SwiftUI

/// A click-and-drag surface laid over a sidebar row that selects by its own tap (a split's chip,
/// the own line of a terminal with child terminals).
///
/// Why AppKit: a SwiftUI `.onTapGesture` over a List row takes the mouse-down, so the List never
/// sees the drag and the row's `.itemProvider` is never asked: those rows could not be dragged
/// (0.18.1). Plain `TabRow`s have no tap gesture and drag through the List as before.
///
/// This view takes only the *left* button. For a right-click, a control-click and mouse movement
/// its `hitTest` answers nil, so the row's SwiftUI `.contextMenu`, `.help` and hover keep working
/// on the views under it. A left mouse-up without movement is the click (`onClick`); moving more
/// than 3 pt starts the drag with `payload`, the same pasteboard type as every other tab drag.
struct SidebarDragHandle: NSViewRepresentable {
    let payload: TabDragPayload
    let title: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> SidebarDragHandleView { SidebarDragHandleView() }

    func updateNSView(_ view: SidebarDragHandleView, context: Context) {
        view.payload = payload
        view.title = title
        view.onClick = onClick
    }
}

final class SidebarDragHandleView: NSView, NSDraggingSource {
    var payload: TabDragPayload?
    var title = ""
    var onClick: (() -> Void)?
    /// Tests replace the real drag (which needs a live mouse) with this.
    var startDragForTest: ((TabDragPayload) -> Void)?
    private var mouseDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }

    /// Only plain left-button events land here (see the type's comment). `event` is the one being
    /// dispatched; nil (no event, e.g. a test's own hit test) counts as a left click.
    static func takes(_ event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return !event.modifierFlags.contains(.control) // control-click is the context menu
        default:
            return false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.takes(NSApplication.shared.currentEvent) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let payload else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return } // tiny movements are still a click
        mouseDownEvent = nil

        // A split's row can only be dropped in the sidebar: the panes keep their drop layers down.
        if case .split = payload { TabDragSession.begin(raisesPanes: false) } else { TabDragSession.begin() }
        if let startDragForTest { startDragForTest(payload); return }
        let item = NSPasteboardItem()
        item.setData(Data(payload.string.utf8), forType: .singularityTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = PaneDragHandleView.dragImage(title: title)
        let start = convert(down.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(origin: NSPoint(x: start.x - 12, y: start.y - image.size.height / 2), size: image.size),
                                      contents: image)
        beginDraggingSession(with: [draggingItem], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick?() }
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy too: the sidebar's drop targets (SwiftUI) propose copy, and AppKit drops only when
        // source and target share an operation (as for a pane header's drag).
        context == .withinApplication ? [.move, .copy] : []
    }
}
