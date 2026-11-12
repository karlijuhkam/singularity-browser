import Foundation
import Testing
@testable import SingularityCore

@Suite struct LittleWindowRulesTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func onlyWebLinksAreAccepted() {
        #expect(LittleWindowRules.accepts(url("https://example.com/a")))
        #expect(LittleWindowRules.accepts(url("HTTP://example.com")))
        #expect(!LittleWindowRules.accepts(url("file:///Users/me/page.html")))
        #expect(!LittleWindowRules.accepts(url("mailto:someone@example.com")))
        #expect(!LittleWindowRules.accepts(url("javascript:alert(1)")))
        #expect(!LittleWindowRules.accepts(url("https:///nohost")))
    }

    @Test func addressIsHostAndPath() {
        #expect(LittleWindowRules.addressText(url("https://github.com/roosa/singularity/pull/42?tab=files#x")) == "github.com/roosa/singularity/pull/42")
        #expect(LittleWindowRules.addressText(url("https://www.example.com/")) == "example.com")
        #expect(LittleWindowRules.addressText(url("http://localhost:3000/app")) == "localhost:3000/app")
        #expect(LittleWindowRules.addressText(nil) == "")
        #expect(LittleWindowRules.addressText(url("about:blank")) == "")
    }

    @Test func homeSpaceIsTheSelectedOneOrTheFirst() {
        let a = UUID(), b = UUID()
        #expect(LittleWindowRules.homeSpace(selected: b, spaces: [a, b]) == b)
        #expect(LittleWindowRules.homeSpace(selected: nil, spaces: [a, b]) == a)
        #expect(LittleWindowRules.homeSpace(selected: UUID(), spaces: [a, b]) == a) // a Space that is gone
        #expect(LittleWindowRules.homeSpace(selected: nil, spaces: []) == nil)
    }

    @Test func homeSpaceMovesAnotherSpaceReloads() {
        let home = UUID(), other = UUID()
        let first = url("https://example.com/first"), current = url("https://example.com/now"), failed = url("https://down.example/x")
        #expect(LittleWindowRules.openAction(home: home, chosen: home, current: current, failed: nil, first: first) == .move)
        // The address showing now, not the one first clicked.
        #expect(LittleWindowRules.openAction(home: home, chosen: other, current: current, failed: nil, first: first) == .reload(current))
        // An error page is showing: the address that failed.
        #expect(LittleWindowRules.openAction(home: home, chosen: other, current: current, failed: failed, first: first) == .reload(failed))
        // Nothing loaded yet, or a page that is not a web address.
        #expect(LittleWindowRules.openAction(home: home, chosen: other, current: nil, failed: nil, first: first) == .reload(first))
        #expect(LittleWindowRules.openAction(home: home, chosen: other, current: url("about:blank"), failed: nil, first: first) == .reload(first))
    }
}

@Suite struct DefaultBrowserRulesTests {
    private let claiming: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["http", "https"]]]]
    private let id = "dev.roosa.Singularity"
    private let installed = "/Applications/Singularity.app"

    @Test func onlyABundleThatDeclaresWebSchemesClaimsLinks() {
        #expect(DefaultBrowserRules.claimsLinks(infoPlist: claiming))
        #expect(!DefaultBrowserRules.claimsLinks(infoPlist: [:]))
        #expect(!DefaultBrowserRules.claimsLinks(infoPlist: ["CFBundleURLTypes": [["CFBundleURLSchemes": ["singularity"]]]]))
    }

    @Test func statusOfTheInstalledRelease() {
        #expect(DefaultBrowserRules.status(infoPlist: claiming, bundlePath: installed, bundleID: id,
                                           defaultAppPath: installed + "/", defaultAppBundleID: id) == .isDefault)
        let notDefault = DefaultBrowserRules.status(infoPlist: claiming, bundlePath: installed, bundleID: id,
                                                    defaultAppPath: "/Applications/Safari.app", defaultAppBundleID: "com.apple.Safari")
        #expect(notDefault == .notDefault)
        #expect(notDefault.canMakeDefault)
        #expect(DefaultBrowserRules.status(infoPlist: claiming, bundlePath: installed, bundleID: id,
                                           defaultAppPath: nil, defaultAppBundleID: nil) == .notDefault)
    }

    @Test func copiesThatCannotBeTheDefaultGetNoButton() {
        // A development build while the installed copy is the default: named, no button.
        let other = DefaultBrowserRules.status(infoPlist: [:], bundlePath: "/Users/me/dev/build/Singularity.app", bundleID: id,
                                               defaultAppPath: installed, defaultAppBundleID: id)
        #expect(other == .otherCopyIsDefault(path: installed))
        #expect(!other.canMakeDefault)
        #expect(other.text.contains(installed))
        // A development build while Safari is the default.
        let dev = DefaultBrowserRules.status(infoPlist: [:], bundlePath: "/Users/me/dev/build/Singularity.app", bundleID: id,
                                             defaultAppPath: "/Applications/Safari.app", defaultAppBundleID: "com.apple.Safari")
        guard case .unavailable(let why) = dev else { Issue.record("expected unavailable, got \(dev)"); return }
        #expect(why.contains("development build"))
        // A release opened straight from the download.
        let translocated = DefaultBrowserRules.status(infoPlist: claiming, bundlePath: "/private/var/folders/x/AppTranslocation/y/d/Singularity.app",
                                                      bundleID: id, defaultAppPath: nil, defaultAppBundleID: nil)
        guard case .unavailable(let move) = translocated else { Issue.record("expected unavailable, got \(translocated)"); return }
        #expect(move.contains("Applications"))
    }
}
