import AppKit
import SingularityCore
import UniformTypeIdentifiers

/// Where a dragged tab will land on a pane: one of its edges (new split) or its middle
/// (replace the pane's tab).
enum PaneDropZone: Equatable {
    case edge(SplitEdge)
    case center
}

extension UTType {
    /// A tab dragged from the sidebar or a pane header. Declared in Info.plist
    /// (UTExportedTypeDeclarations). Private, so web pages never treat it as text.
    static let singularityTab = UTType(exportedAs: "dev.roosa.singularity.tab")
}

extension NSPasteboard.PasteboardType {
    static let singularityTab = NSPasteboard.PasteboardType(UTType.singularityTab.identifier)
}

/// Tracks whether a tab is being dragged, so panes can put their drop layers up only then.
@MainActor
enum TabDragSession {
    static let didBegin = Notification.Name("SingularityTabDragDidBegin")
    static let didEnd = Notification.Name("SingularityTabDragDidEnd")
    private static var timer: Timer?

    /// Called when a tab drag starts (SwiftUI asks for the drag data at that moment).
    static func begin() {
        guard timer == nil else { return }
        NotificationCenter.default.post(name: didBegin, object: nil)
        // AppKit runs its drag loop in "event tracking" mode, where ordinary timers don't fire.
        // So this check only runs after the drag (and its drop) have finished.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer?.invalidate()
                timer = nil
                NotificationCenter.default.post(name: didEnd, object: nil)
            }
        }
    }
}

/// The AppKit view that holds a tab's content (a WKWebView or terminal view) on screen.
///
/// - **Drops:** while a tab is being dragged, it lays a transparent `PaneDropOverlay` over the
///   content. The overlay must sit on top: a web view registers as a drop target for nearly
///   everything and would otherwise take the drop itself.
/// - **Click-to-focus:** a window-wide mouse-down monitor (`installFocusMonitor`) finds which
///   container was clicked, because clicks inside web/terminal views never reach SwiftUI.
final class PaneContainerView: NSView {
    var tabID: UUID?
    var onDrop: ((UUID, PaneDropZone) -> Void)?
    /// Creation order; the newest container showing a tab owns its view (see HostedView).
    let serial: Int
    private static var nextSerial = 0

    /// Live containers, for the click monitor. Weak so closed panes disappear by themselves.
    private static let all = NSHashTable<PaneContainerView>.weakObjects()
    private var overlay: PaneDropOverlay?

    override init(frame: NSRect) {
        Self.nextSerial += 1
        serial = Self.nextSerial
        super.init(frame: frame)
        Self.all.add(self)
        // Selector-based observers are removed automatically when the view is deallocated.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(showOverlay), name: TabDragSession.didBegin, object: nil)
        center.addObserver(self, selector: #selector(hideOverlay), name: TabDragSession.didEnd, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    /// The hosted view is swapped in by `HostedView`; keep the overlay above it.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let overlay, subview !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
    }

    @objc private func showOverlay() {
        guard overlay == nil, onDrop != nil else { return }
        let overlay = PaneDropOverlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onDrop = { [weak self] tab, zone in self?.onDrop?(tab, zone) }
        addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
    }

    @objc private func hideOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    // MARK: Click to focus

    private static var monitor: Any?

    /// Installs (once) a monitor that reports which pane a mouse-down landed in. The event itself
    /// continues unchanged to the web or terminal view.
    static func installFocusMonitor(_ onFocus: @escaping @MainActor (UUID) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            for container in all.allObjects where container.window === event.window {
                let point = container.convert(event.locationInWindow, from: nil)
                if container.bounds.contains(point), let tabID = container.tabID {
                    MainActor.assumeIsolated { onFocus(tabID) }
                    break
                }
            }
            return event
        }
    }
}

/// A transparent layer over a pane, present only while a tab is dragged. It accepts the drop and
/// shows where the tab will land.
final class PaneDropOverlay: NSView {
    var onDrop: ((UUID, PaneDropZone) -> Void)?
    private let highlight = CALayer()
    private var zone: PaneDropZone?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.singularityTab])
        highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        highlight.borderColor = NSColor.controlAccentColor.cgColor
        highlight.borderWidth = 2
        highlight.cornerRadius = 6
        highlight.isHidden = true
        layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let zone = Self.zone(for: point, in: bounds)
        if zone != self.zone {
            self.zone = zone
            showHighlight(for: zone)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        zone = nil
        highlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            zone = nil
            highlight.isHidden = true
        }
        guard let zone,
              let data = sender.draggingPasteboard.data(forType: .singularityTab),
              let droppedTab = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return false }
        onDrop?(droppedTab, zone)
        return true
    }

    /// The outer quarter of each side is that edge's zone; the rest is the middle.
    static func zone(for point: NSPoint, in bounds: NSRect) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let fx = point.x / bounds.width
        let fy = point.y / bounds.height
        let distances: [(SplitEdge, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 0.25 ? .edge(nearest.0) : .center
    }

    private func showHighlight(for zone: PaneDropZone) {
        var rect = bounds
        switch zone {
        case .center: break
        case .edge(.left): rect.size.width /= 2
        case .edge(.right): rect.size.width /= 2; rect.origin.x += rect.size.width
        case .edge(.top): rect.size.height /= 2
        case .edge(.bottom): rect.size.height /= 2; rect.origin.y += rect.size.height
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        highlight.frame = rect.insetBy(dx: 4, dy: 4)
        highlight.isHidden = false
        CATransaction.commit()
    }
}
