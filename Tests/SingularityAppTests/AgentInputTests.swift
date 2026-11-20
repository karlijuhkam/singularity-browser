import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// The real key events agents send (`AgentInput`) reach only their page: a key WebKit hands back
/// to the app (the page didn't use it) is swallowed, so it never lands in another view of the
/// window or fires a menu shortcut. The window is off screen and never key.
@MainActor
@Suite(.serialized) struct AgentInputTests {
    @objc final class MenuTarget: NSObject {
        var fired = 0
        @objc func close(_ sender: Any?) { fired += 1 }
    }

    @Test(.timeLimit(.minutes(1))) func keysNeverLeaveThePage() async throws {
        MainRunLoopGuard.start
        AgentInput.installSwallower()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        window.contentView = content
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 100, y: 50, width: 900, height: 600), configuration: configuration)
        content.addSubview(webView)
        let field = NSTextField(frame: NSRect(x: 4, y: 4, width: 80, height: 22))
        content.addSubview(field)
        window.orderBack(nil)
        window.makeFirstResponder(field)
        defer { window.orderOut(nil) }

        let target = MenuTarget()
        let item = NSMenuItem(title: "Close Test", action: #selector(MenuTarget.close(_:)), keyEquivalent: "w")
        item.target = target
        let top = NSMenuItem()
        top.submenu = NSMenu()
        top.submenu?.addItem(item)
        if NSApp.mainMenu == nil { NSApp.mainMenu = NSMenu() }
        NSApp.mainMenu?.addItem(top)
        defer { NSApp.mainMenu?.removeItem(top) }

        webView.loadHTMLString("<!doctype html><button id=b style='width:200px;height:60px'>B</button>", baseURL: URL(string: "http://127.0.0.1/"))
        try await waitUntil("the page", limit: .seconds(10)) { !webView.isLoading && webView.url != nil }
        try await Task.sleep(for: .milliseconds(300))
        AgentInput.click(webView, at: CGPoint(x: 100, y: 30), double: false)
        for text in ["x", "Escape", "Meta+w"] {
            AgentInput.press(try KeyChord.parse(text), in: webView)
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(field.stringValue == "")
        #expect(target.fired == 0)
        #expect(window.firstResponder === field.currentEditor() || window.firstResponder === field)
    }
}
}
