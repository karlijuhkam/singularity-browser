import AppKit
import SwiftUI

/// The draggable surface of a pane header.
///
/// Why AppKit: pane headers sit in the window's invisible title bar strip, where macOS turns a
/// mouse-down into a *window* drag before the view under the mouse gets a say (verified:
/// `mouseDownCanMoveWindow = false` alone is not enough there). So while the mouse is over a
/// header, this view switches the window's `isMovable` off, and back on when the mouse leaves.
/// It starts the tab drag itself (same pasteboard type as sidebar rows); a click without
/// dragging focuses the pane. Don't put SwiftUI `.help()` on the header: it adds an invisible
/// view on top that takes the click (the tooltip is set here, in AppKit, instead).
struct PaneDragHandle: NSViewRepresentable {
    let tabID: UUID
    let title: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> PaneDragHandleView {
        PaneDragHandleView()
    }

    func updateNSView(_ view: PaneDragHandleView, context: Context) {
        view.tabID = tabID
        view.title = title
        view.onClick = onClick
    }
}

final class PaneDragHandleView: NSView, NSDraggingSource {
    var tabID: UUID?
    var title = ""
    var onClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    /// The window whose `isMovable` we switched off (so we can always switch it back on).
    private weak var pinnedWindow: NSWindow?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // An AppKit tooltip (a SwiftUI .help() would add a view on top that swallows the drag).
        toolTip = "Drag onto another pane to move this one"
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: Keep the window still while the mouse is over the header

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window else { return }
        window.isMovable = false
        pinnedWindow = window
    }

    override func mouseExited(with event: NSEvent) {
        releaseWindow()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The header can disappear while hovered (pane removed or moved): never leave the window stuck.
        if newWindow == nil { releaseWindow() }
    }

    private func releaseWindow() {
        pinnedWindow?.isMovable = true
        pinnedWindow = nil
    }

    // MARK: Click and drag

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let tabID else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return } // ignore tiny movements (still a click)
        mouseDownEvent = nil

        TabDragSession.begin() // put the panes' drop layers up
        let item = NSPasteboardItem()
        item.setData(Data(tabID.uuidString.utf8), forType: .singularityTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = Self.dragImage(title: title)
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
        context == .withinApplication ? .move : []
    }

    /// A small rounded label with the tab's title, shown under the cursor while dragging.
    private static func dragImage(title: String) -> NSImage {
        let text = (title.count > 40 ? String(title.prefix(39)) + "…" : title) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 20, height: 24)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: 10, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
    }
}
