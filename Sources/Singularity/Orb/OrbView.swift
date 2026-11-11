import AppKit
import MetalKit
import SwiftUI

/// The Singularity orb, alive: the site's shader drawn by Metal (`OrbRenderer`), a square of
/// `size` points, transparent outside the sphere. Like singularity.rroosa.ee it is white in dark
/// mode and black in light mode, and its ripples start from where the pointer touches it.
///
/// Without Metal (or if the shader does not compile) it shows the still `Orb-dark/-light.png`
/// from the app bundle instead, and nothing if those are missing too (e.g. a bare debug binary).
struct OrbView: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(size: CGFloat) {
        self.size = size
    }

    var body: some View {
        Group {
            if OrbRenderer.pipeline != nil {
                OrbMetalRepresentable(whiteOrb: colorScheme == .dark, reduceMotion: reduceMotion)
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

/// Puts the AppKit/Metal view into SwiftUI and hands it the current colour and motion setting.
private struct OrbMetalRepresentable: NSViewRepresentable {
    let whiteOrb: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> OrbMetalView {
        OrbMetalView()
    }

    func updateNSView(_ view: OrbMetalView, context: Context) {
        view.whiteOrb = whiteOrb
        view.reduceMotion = reduceMotion
    }
}

/// An `MTKView` that draws the orb about 30 times a second while it can be seen.
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
        didSet { if reduceMotion != oldValue { updatePaused() } }
    }

    /// Seconds into the site's animation for the still frame; the animation also starts there.
    private static let stillTime: Float = 4
    private let startTime = CACurrentMediaTime()
    /// Ripple origin as drawn, easing towards `targetCursor` a little each frame.
    private var cursor = OrbRenderer.defaultCursor
    private var targetCursor = OrbRenderer.defaultCursor
    private var trackingArea: NSTrackingArea?

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
        guard let pipeline = OrbRenderer.pipeline,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = pipeline.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if reduceMotion {
            OrbRenderer.draw(into: encoder, time: Self.stillTime, whiteOrb: whiteOrb, cursor: OrbRenderer.defaultCursor)
        } else {
            cursor += (targetCursor - cursor) * 0.1
            let time = Self.stillTime + Float(CACurrentMediaTime() - startTime)
            OrbRenderer.draw(into: encoder, time: time, whiteOrb: whiteOrb, cursor: cursor)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Pausing (no drawing while nobody can see it)

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: window)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePaused()
    }

    @objc private func visibilityChanged() {
        updatePaused()
    }

    /// Animates only while the view is in a window that is on screen and not covered, the app is
    /// not hidden, and reduce motion is off. Paused, it still draws the current frame once.
    private func updatePaused() {
        let visible = window?.occlusionState.contains(.visible) == true && !NSApp.isHidden
        let paused = reduceMotion || !visible
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
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // With reduce motion the orb stays one still frame, pointer or not.
        guard !reduceMotion else { return }
        // MTKView is not flipped: y grows upwards, as in the shader's view space.
        let point = convert(event.locationInWindow, from: nil)
        if let direction = OrbRenderer.sphereDirection(at: point, side: bounds.width) {
            targetCursor = direction
        }
    }
}
