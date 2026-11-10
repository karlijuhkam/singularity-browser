import Foundation
import Testing
@testable import SingularityCore

@Suite struct WebTests {
    @Test func errorPageIsShownForRealFailuresOnly() {
        #expect(LoadErrorPage.shouldShow(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        #expect(LoadErrorPage.shouldShow(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(LoadErrorPage.shouldShow(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        #expect(!LoadErrorPage.shouldShow(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(!LoadErrorPage.shouldShow(domain: "WebKitErrorDomain", code: 102)) // became a download
        #expect(!LoadErrorPage.shouldShow(domain: "WebKitErrorDomain", code: 204))
    }

    @Test func errorPageEscapesTheURLAndMessage() {
        let html = LoadErrorPage.html(url: #"https://x.test/"><script>alert(1)</script>"#, message: "<b>no & 'way'</b>")
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<b>"))
        #expect(html.contains(#"href="https://x.test/&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;""#))
        #expect(html.contains("&lt;b&gt;no &amp; &#39;way&#39;&lt;/b&gt;"))
        #expect(html.contains("default-src 'none'"))
    }

    @Test func zoomSteps() {
        #expect(PageZoom.next(from: 1.0, larger: true) == 1.1)
        #expect(PageZoom.next(from: 1.0, larger: false) == 0.9)
        #expect(PageZoom.next(from: 3.0, larger: true) == 3.0)
        #expect(PageZoom.next(from: 0.5, larger: false) == 0.5)
        #expect(PageZoom.next(from: 1.2, larger: true) == 1.25) // an off-ladder value joins the ladder
        #expect(PageZoom.next(from: 1.2, larger: false) == 1.1)
    }
}

@Suite struct LaunchSafetyTests {
    private func tempPaths() -> Paths {
        Paths(root: FileManager.default.temporaryDirectory.appending(path: "launch-\(UUID().uuidString)"))
    }

    @Test func onlyOneCopyHoldsTheLock() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var first: InstanceLock? = InstanceLock.acquire(paths: paths)
        #expect(first != nil)
        #expect(InstanceLock.acquire(paths: paths) == nil) // flock is per open file, so this works in one process
        first = nil
        #expect(InstanceLock.acquire(paths: paths) != nil)
    }

    @Test func aCopiedSpaceFolderIsSkippedAndARepeatedIdDoesNotCrash() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = SpaceStore(paths: paths)
        let space = Space(name: "Work", slug: "work", colorHex: "#000000", workingDirectory: "~")
        try store.save(space)
        try FileManager.default.copyItem(at: paths.spaceDirectory("work"), to: paths.spaceDirectory("work-backup"))
        var state = AppStateFile()
        state.spaceOrder = [space.id, space.id]
        try store.save(state)

        let loaded = store.load()
        #expect(loaded.spaces.count == 1)
        #expect(loaded.errors.count == 1)
        #expect(loaded.errors[0].contains("work-backup"))
    }

    @Test func oneBadSettingKeepsTheOthers() throws {
        let json = #"{"terminalFontSize": "big", "closeTerminalOnExit": false, "searchEngine": "kagi"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.terminalFontSize == AppSettings().terminalFontSize)
        #expect(!settings.closeTerminalOnExit)
        #expect(settings.searchEngine == .kagi)
    }
}
