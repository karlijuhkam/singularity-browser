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
