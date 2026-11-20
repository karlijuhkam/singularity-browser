import AppKit
@testable import Singularity
import SingularityCore

/// Clicks and drags a `SidebarDragHandleView` the way AppKit would deliver them, without the mouse:
/// the window is found by hit testing (so a SwiftUI view on top that would swallow the mouse-down
/// fails the test), the events go to the view that was hit, and the real drag is replaced by
/// `startDragForTest`. No window is made key and no dragging session starts.
@MainActor
enum SidebarDragHandleProbe {
    static func handles(in view: NSView) -> [SidebarDragHandleView] {
        ([view] + view.subviews.flatMap { all($0) }).compactMap { $0 as? SidebarDragHandleView }
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// The view a left click at the handle's middle lands in.
    static func hitView(at handle: SidebarDragHandleView) -> NSView? {
        guard let window = handle.window, let frameView = window.contentView?.superview else { return nil }
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        return frameView.hitTest(frameView.convert(point, from: nil))
    }

    private static func event(_ type: NSEvent.EventType, _ view: NSView, dx: CGFloat = 0) -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX + dx, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }

    static func click(_ view: NSView) {
        view.mouseDown(with: event(.leftMouseDown, view))
        view.mouseUp(with: event(.leftMouseUp, view))
    }

    /// Drags 20 pt; returns what the handle would have put on the pasteboard.
    static func drag(_ handle: SidebarDragHandleView) -> TabDragPayload? {
        var dragged: TabDragPayload?
        handle.startDragForTest = { dragged = $0 }
        defer { handle.startDragForTest = nil }
        handle.mouseDown(with: event(.leftMouseDown, handle))
        handle.mouseDragged(with: event(.leftMouseDragged, handle, dx: 20))
        handle.mouseUp(with: event(.leftMouseUp, handle, dx: 20))
        return dragged
    }
}
