import Foundation
import Testing
@testable import SingularityCore

@Suite struct PluginTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func sitePatterns() throws {
        let all = try SitePattern("<all_urls>")
        #expect(all.matches(url("https://a.com/x")))
        #expect(all.matches(url("http://b.org")))
        #expect(!all.matches(url("about:blank")))
        #expect(!all.matches(url("file:///tmp/x")))

        let gh = try SitePattern("https://*.github.com/*")
        #expect(gh.matches(url("https://github.com/login")))
        #expect(gh.matches(url("https://gist.github.com/x")))
        #expect(!gh.matches(url("http://github.com/")))
        #expect(!gh.matches(url("https://evilgithub.com/")))

        let any = try SitePattern("*://example.com/*")
        #expect(any.matches(url("http://example.com/a")))
        #expect(any.matches(url("https://example.com/a")))
        #expect(!any.matches(url("ftp://example.com/a")))

        for bad in ["ftp://x/*", "https://exa*mple.com/*", "", "https://a.com:8080/*", "https://a.com"] {
            #expect(throws: PluginError.invalidSitePattern(bad)) { _ = try SitePattern(bad) }
        }
    }

    @Test func sitePatternDetails() throws {
        let p = try SitePattern("https://example.com/*")
        #expect(p.matches(url("https://EXAMPLE.com/a")))
        #expect(p.matches(url("https://example.com./a")))
        #expect(p.matches(url("https://example.com:8443/a")))
        #expect(p.matches(url("https://example.com")))

        let upper = try SitePattern("https://Example.COM./*")
        #expect(upper.matches(url("https://example.com/")))

        let path = try SitePattern("https://a.com/docs/*/edit")
        #expect(path.matches(url("https://a.com/docs/x/y/edit")))
        #expect(!path.matches(url("https://a.com/docs/x/edit/more")))

        let query = try SitePattern("https://a.com/s?q=*")
        #expect(query.matches(url("https://a.com/s?q=hi")))
        #expect(!query.matches(url("https://a.com/s")))

        let star = try SitePattern("https://*/*")
        #expect(star.matches(url("https://anything.dev/x")))
    }

    @Test func hostMatching() {
        #expect(HostMatch.isSameOrSubdomain("www.github.com", of: "github.com"))
        #expect(HostMatch.isSameOrSubdomain("github.com", of: "github.com"))
        #expect(!HostMatch.isSameOrSubdomain("github.com", of: "www.github.com"))
        #expect(!HostMatch.isSameOrSubdomain("evilgithub.com", of: "github.com"))
        #expect(HostMatch.isSameOrSubdomain("WWW.GitHub.com.", of: "github.COM"))
    }

    @Test func negativeMatches() throws {
        let gh = try SitePattern("https://*.github.com/*")
        for u in ["https://github.com.evil.com/", "https://evil.com/?x=github.com",
                  "https://github.com@evil.com/", "https://.github.com/"] {
            #expect(!gh.matches(url(u)), "\(u)")
        }
        let ex = try SitePattern("https://example.com/*")
        #expect(!ex.matches(url("https://www.example.com/")))
        #expect(!ex.matches(url("https://evilexample.com/")))
        for p in ["<all_urls>", "*://*/*"] {
            let sp = try SitePattern(p)
            #expect(!sp.matches(url("ws://a.com/")))
            #expect(!sp.matches(url("file:///etc/hosts")))
        }
        for bad in ["https://*./*", "https://*.*.com/*", "https://user@github.com/*",
                    "https://.github.com/*", "https://a..b.com/*", "https://a.com?x/*", "https://a b.com/*"] {
            #expect(throws: PluginError.invalidSitePattern(bad)) { _ = try SitePattern(bad) }
        }
        #expect(!HostMatch.isSameOrSubdomain(".github.com", of: "github.com"))
        #expect(!HostMatch.isSameOrSubdomain("a..github.com", of: "github.com"))
        #expect(!HostMatch.isSameOrSubdomain("", of: ""))
    }

    @Test func pathLiterals() throws {
        let p = try SitePattern("https://a.com/a.b+c(d)*")
        #expect(p.matches(url("https://a.com/a.b+c(d)x")))
        #expect(!p.matches(url("https://a.com/aXb+c(d)x")))
    }
}
