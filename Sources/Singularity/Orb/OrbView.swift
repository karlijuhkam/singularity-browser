import AppKit
import MetalKit
import SwiftUI

/// The Singularity orb, alive: the site's shader drawn by Metal (`OrbRenderer`), a square of
/// `size` points, transparent outside the sphere. Like singularity.rroosa.ee it is white in dark
/// mode and black in light mode, and its ripples start from where the pointer touches it.
///
/// Without Metal (or if the shader does not compile) it shows the still `Orb-dark/-light.png`
/// from the app bundle instead, and nothing if those are missing too (e.g. a bare debug binary).
///
/// It animates only while its window is the key window and can be seen (`OrbAnimation`). With
/// `stopsWhenIdle` (the empty-Space placeholder, which may stay open all day) it also holds still
/// after 30 seconds without the pointer moving over it, until the pointer comes back or the window
/// becomes key again. The welcome flow leaves it off, so the orb keeps moving there.
struct OrbView: View {
    let size: CGFloat
    let stopsWhenIdle: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(size: CGFloat, stopsWhenIdle: Bool = false) {
        self.size = size
        self.stopsWhenIdle = stopsWhenIdle
    }

    var body: some View {
        Group {
            if OrbRenderer.pipeline != nil {
                OrbMetalRepresentable(whiteOrb: colorScheme == .dark, reduceMotion: reduceMotion,
                                      stopsWhenIdle: stopsWhenIdle)
            } else if let url = Bundle.main.url(forResource: colorScheme == .dark ? "Orb-dark" : "Orb-light",
                                                withExtension: "png"),
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}

/// When the orb animates. The facts come in as plain values, so the rule can be tested
/// (`OrbAnimationTests`); `OrbMetalView.updatePaused` gathers them from AppKit.
enum OrbAnimation {
    /// Seconds without pointer movement after which an orb that `stopsWhenIdle` holds still.
    static let idleLimit: TimeInterval = 30

    /// Animate only in the key window, when it is on screen and not covered, the app is not hidden
    /// (⌘H) and Reduce Motion is off; with `stopsWhenIdle`, also only within `idleLimit` seconds
    /// of the pointer last moving over the orb (or of the window becoming key).
    static func shouldAnimate(windowIsKey: Bool, windowIsVisible: Bool, appIsHidden: Bool, reduceMotion: Bool,
                              stopsWhenIdle: Bool, secondsSincePointerMoved: TimeInterval) -> Bool {
        guard windowIsKey, windowIsVisible, !appIsHidden, !reduceMotion else { return false }
        return !stopsWhenIdle || secondsSincePointerMoved < idleLimit
    }
}

/// Puts the AppKit/Metal view into SwiftUI and hands it the current colour and motion setting.
private struct OrbMetalRepresentable: NSViewRepresentable {
    let whiteOrb: Bool
    let reduceMotion: Bool
    let stopsWhenIdle: Bool

    func makeNSView(context: Context) -> OrbMetalView {
        OrbMetalView()
    }

    func updateNSView(_ view: OrbMetalView, context: Context) {
        view.whiteOrb = whiteOrb
        view.reduceMotion = reduceMotion
        view.stopsWhenIdle = stopsWhenIdle
    }
}

/// An `MTKView` that draws the orb about 30 times a second while it can be seen (see `OrbAnimation`).
///
/// MTKView runs its own display timer and calls `draw(_:)` on every tick unless `isPaused` is set.
/// Paused, with `enableSetNeedsDisplay` on, it draws once whenever `needsDisplay` is set, which is
/// how a still frame (reduce motion, colour change while hidden) gets drawn.
final class OrbMetalView: MTKView {
    /// White orb (dark appearance) or black orb (light appearance).
    var whiteOrb = true {
        didSet { if whiteOrb != oldValue { needsDisplay = true } }
    }
    /// Reduce motion: one still frame (at `stillTime`), no animation.
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            updatePaused()
            needsDisplay = true // the still frame (or the first moving one)
        }
    }
    /// Hold still after `OrbAnimation.idleLimit` seconds without the pointer moving over the orb.
    var stopsWhenIdle = false {
        didSet { if stopsWhenIdle != oldValue { updatePaused() } }
    }

    /// Seconds into the site's animation for the still frame; the animation also starts there.
    private static let stillTime: Float = 4
    private let startTime = CACurrentMediaTime()
    /// Ripple origin as drawn, easing towards `targetCursor` a little each frame.
    private(set) var cursor = OrbRenderer.defaultCursor
    /// Where the pointer last touched the sphere (a unit vector, view space, y up).
    private(set) var targetCursor = OrbRenderer.defaultCursor
    /// Frames drawn so far (read by `OrbTests`: one still frame under Reduce Motion).
    private(set) var framesDrawn = 0
    private var trackingArea: NSTrackingArea?
    /// When the pointer last moved over the orb, or the window last became key (the idle count's start).
    private var lastPointerMove = CACurrentMediaTime()

    init() {
        super.init(frame: .zero, device: OrbRenderer.pipeline?.device)
        colorPixelFormat = OrbRenderer.pixelFormat
        // Colours go out as sRGB values, as a web canvas does (the shader writes them as-is).
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Transparent outside the sphere: clear to nothing and let what is behind show through.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = true
        isPaused = true

        // Also pause while the app is hidden (⌘H), without relying on occlusion updates for that.
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                               name: NSApplication.didHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                               name: NSApplication.didUnhideNotification, object: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The idle limit has no notification of its own, so the running animation checks it on
        // each frame. Only while running: paused, `updatePaused` would not change anything (and a
        // paused draw must not ask for another one).
        if !isPaused, stopsWhenIdle, CACurrentMediaTime() - lastPointerMove >= OrbAnimation.idleLimit {
            updatePaused()
        }
        guard let pipeline = OrbRenderer.pipeline,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = pipeline.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if reduceMotion {
            OrbRenderer.draw(into: encoder, time: Self.stillTime, whiteOrb: whiteOrb, cursor: OrbRenderer.defaultCursor)
        } else {
            easeCursor()
            let time = Self.stillTime + Float(CACurrentMediaTime() - startTime)
            OrbRenderer.draw(into: encoder, time: time, whiteOrb: whiteOrb, cursor: cursor)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        framesDrawn += 1
    }

    /// One frame's step of the ripple origin: 10 % of the way to where the pointer is.
    func easeCursor() {
        cursor += (targetCursor - cursor) * 0.1
    }

    // MARK: Pausing (no drawing while nobody is looking)

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The window tells us when it is covered or uncovered, and when it becomes or stops being
        // the key window (the one taking keyboard input; not key = another window or app in front).
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeKeyNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastPointerMove = CACurrentMediaTime()
        updatePaused()
        needsDisplay = true // the first frame, also when it starts paused
    }

    @objc private func visibilityChanged() {
        updatePaused()
    }

    /// Back in front: the idle count starts again.
    @objc private func windowBecameKey() {
        lastPointerMove = CACurrentMediaTime()
        updatePaused()
    }

    /// Starts or stops MTKView's frame timer when `OrbAnimation` says so. On stopping it draws one
    /// more frame and then holds it.
    private func updatePaused() {
        let animate = OrbAnimation.shouldAnimate(
            windowIsKey: window?.isKeyWindow == true,
            windowIsVisible: window?.occlusionState.contains(.visible) == true,
            appIsHidden: NSApp.isHidden,
            reduceMotion: reduceMotion,
            stopsWhenIdle: stopsWhenIdle,
            secondsSincePointerMoved: CACurrentMediaTime() - lastPointerMove)
        let paused = !animate
        guard paused != isPaused else { return } // already as it should be
        // The two go together: `enableSetNeedsDisplay` also stops MTKView's own timer.
        isPaused = paused
        enableSetNeedsDisplay = paused
        needsDisplay = true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.inVisibleRect` keeps the area matching the view's bounds as it resizes.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                         .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerMoved(event)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(event)
    }

    private func pointerMoved(_ event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    /// The pointer is at `point` (in this view's coordinates). Over the sphere it becomes the new
    /// ripple origin; anywhere else the origin stays.
    func pointerMoved(to point: CGPoint) {
        // With reduce motion the orb stays one still frame, pointer or not.
        guard !reduceMotion else { return }
        // The idle count starts again; an orb that had stopped for it moves again.
        lastPointerMove = CACurrentMediaTime()
        if isPaused { updatePaused() }
        // MTKView is not flipped: y grows upwards, as in the shader's view space.
        if let direction = OrbRenderer.sphereDirection(at: point, side: bounds.width) {
            targetCursor = direction
        }
    }
}
