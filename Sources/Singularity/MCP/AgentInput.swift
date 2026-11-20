import AppKit
import SingularityCore
import WebKit

/// Real mouse and key events for agents (`click`, `type` with `slowly` or `submit`, `press_key`),
/// handed straight to a tab's `WKWebView`, the way Playwright drives a browser: the page gets them
/// as trusted events (`isTrusted`), also in a background tab with no window, and nothing is
/// activated. Measured on 2026-11-20 (see the spec `2026-11-20-playwright-parity-design.md`).
///
/// Two things to keep:
/// - **A key the page doesn't use comes back to the app.** WebKit re-sends it through
///   `NSApp.sendEvent`, where it would land in whatever has the keyboard (the owner's terminal) or
///   fire a menu shortcut (⌘W). Every event made here gets a unique timestamp, which WebKit keeps,
///   and one app-wide monitor (`installSwallower`) drops any key event that carries one.
/// - **The window's first responder is put back** after each action, in case WebKit took it.
///
/// Hover and drag are not here: `mouseMoved` and `mouseDragged` sent this way reach no page.
@MainActor
enum AgentInput {
    /// Timestamps of the events made here, kept for ten minutes (`isSynthetic`).
    private static var stamps: [TimeInterval: Date] = [:]
    private static var lastStamp: TimeInterval = 0
    private static var swallower: Any?

    static func isSynthetic(_ event: NSEvent) -> Bool {
        isSynthetic(timestamp: event.timestamp)
    }

    static func isSynthetic(timestamp: TimeInterval) -> Bool {
        stamps[timestamp] != nil
    }

    /// Installs the monitor that drops our key events when WebKit hands them back to the app.
    /// Called when the app starts (and by tests); installing again does nothing.
    static func installSwallower() {
        guard swallower == nil else { return }
        swallower = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            MainActor.assumeIsolated { isSynthetic(event) } ? nil : event
        }
    }

    /// A timestamp no other event has (the system clock, nudged forward if two calls collide).
    private static func stamp() -> TimeInterval {
        let now = Date()
        // Kept for minutes: WebKit can hand a key back late (the page's handler opened a dialog
        // that waited for an answer), and it must still be recognised then.
        if stamps.count > 500 { stamps = stamps.filter { now.timeIntervalSince($0.value) < 600 } }
        var value = ProcessInfo.processInfo.systemUptime
        if value <= lastStamp { value = lastStamp + 0.000_001 }
        lastStamp = value
        stamps[value] = now
        return value
    }

    // MARK: - Mouse

    /// Clicks at a point given in the page's CSS pixels (main frame, frame offsets already added).
    static func click(_ webView: WKWebView, at css: CGPoint, double: Bool) {
        let location = windowLocation(webView, css)
        let number = webView.window?.windowNumber ?? 0
        keepingFirstResponder(webView) {
            for count in double ? [1, 2] : [1] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: stamp(),
                                                         windowNumber: number, context: nil, eventNumber: 0, clickCount: count,
                                                         pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                    if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
                }
            }
        }
    }

    /// CSS px → the coordinates AppKit expects in a mouse event: the window's (origin bottom left).
    /// `WKWebView` is flipped (y grows down, like CSS); page zoom and magnification scale CSS px.
    /// With no window, WebKit reads the location as if the view filled one.
    private static func windowLocation(_ webView: WKWebView, _ css: CGPoint) -> NSPoint {
        let scale = webView.pageZoom * webView.magnification
        let inView = NSPoint(x: css.x * scale, y: css.y * scale)
        if webView.window != nil { return webView.convert(inView, to: nil) }
        return NSPoint(x: inView.x, y: webView.bounds.height - inView.y)
    }

    // MARK: - Keys

    static func press(_ chord: KeyChord, in webView: WKWebView) {
        var flags: NSEvent.ModifierFlags = []
        if chord.shift { flags.insert(.shift) }
        if chord.control { flags.insert(.control) }
        if chord.option { flags.insert(.option) }
        if chord.command { flags.insert(.command) }
        let isLetter = chord.characters.count == 1 && chord.characters.first?.isLetter == true
        let ignoring = isLetter ? chord.characters.lowercased() : chord.characters
        var characters = chord.shift && isLetter ? chord.characters.uppercased() : chord.characters
        // Control+letter: AppKit reports the control character (Control+k is 0x0B).
        if chord.control, isLetter, let ascii = ignoring.unicodeScalars.first?.value, ascii < 128 {
            characters = String(UnicodeScalar(UInt8(ascii & 0x1F)))
        }
        let number = webView.window?.windowNumber ?? 0
        keepingFirstResponder(webView) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: stamp(),
                                                   windowNumber: number, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: ignoring, isARepeat: false,
                                                   keyCode: chord.keyCode) else { continue }
                if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
            }
        }
    }

    /// One key press per character, as a person types (`type` with `slowly`). A newline is Enter.
    static func typeSlowly(_ text: String, in webView: WKWebView) async {
        for character in text {
            let chord: KeyChord
            if character == "\n" || character == "\r" {
                chord = (try? KeyChord.parse("Enter"))!
            } else if character == "\t" {
                chord = (try? KeyChord.parse("Tab"))!
            } else {
                let upper = character.isUppercase && character.isLetter
                chord = KeyChord(key: String(character), characters: String(character), keyCode: KeyChord.keyCode(for: character),
                                 shift: upper, control: false, option: false, command: false)
            }
            press(chord, in: webView)
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// Runs `work` and puts the window's first responder back if WebKit moved it (so the owner's
    /// keyboard focus, e.g. a terminal in the same window, stays where it was).
    private static func keepingFirstResponder(_ webView: WKWebView, _ work: () -> Void) {
        let window = webView.window
        let before = window?.firstResponder
        work()
        if let window, let before, window.firstResponder !== before {
            window.makeFirstResponder(before)
        }
    }
}
