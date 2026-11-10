import Foundation
import Testing
@testable import SingularityCore

@Suite struct SiteSettingsTests {
    @Test func sitesAndConnections() {
        #expect(SiteInfo.site(of: URL(string: "https://Example.com/a?b")) == "https://example.com")
        #expect(SiteInfo.site(of: URL(string: "http://localhost:3000/x")) == "http://localhost:3000")
        #expect(SiteInfo.site(of: URL(string: "file:///etc/hosts")) == nil)
        #expect(SiteInfo.site(of: URL(string: "about:blank")) == nil)
        #expect(SiteInfo.site(of: nil) == nil)
        #expect(SiteInfo.connection(of: URL(string: "https://example.com")!) == .secure)
        #expect(SiteInfo.connection(of: URL(string: "http://example.com")!) == .notSecure)
        #expect(SiteInfo.connection(of: URL(string: "http://localhost:5173")!) == .local)
        #expect(SiteInfo.connection(of: URL(string: "http://127.0.0.1:8080")!) == .local)
        #expect(SiteInfo.connection(of: URL(string: "http://app.localhost")!) == .local)
        #expect(SiteInfo.displayName(ofSite: "https://www.example.com") == "example.com")
        #expect(SiteInfo.displayName(ofSite: "http://localhost:3000") == "localhost:3000")
    }

    @Test func settingsAreStoredOnlyWhenChosenAndSurviveJSON() throws {
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        var settings = space.settings(forSite: "https://example.com")
        #expect(settings.isDefault)
        settings.camera = .allow
        settings.disabledPlugins = ["b", "a"]
        space.setSettings(settings, forSite: "https://example.com")
        space.agentInspection = true

        let data = try JSONEncoder().encode(space)
        let loaded = try JSONDecoder().decode(Space.self, from: data)
        #expect(loaded.siteSettings == space.siteSettings)
        #expect(loaded.agentInspection)
        #expect(loaded.sitesWherePluginIsOff("a") == ["https://example.com"])
        #expect(loaded.sitesWherePluginIsOff("zzz").isEmpty)

        space.setSettings(SiteSettings(), forSite: "https://example.com")
        #expect(space.siteSettings.isEmpty)
    }

    @Test func oldAndOddFilesStillLoad() throws {
        // A space.json from before site settings existed.
        let old = ##"{"id":"6916BFB3-AA44-4400-83E8-6735FE2E2030","name":"P","slug":"p","colorHex":"#000000"}"##
        let space = try JSONDecoder().decode(Space.self, from: Data(old.utf8))
        #expect(space.siteSettings.isEmpty)
        #expect(!space.agentInspection)
        // Unknown values fall back to the defaults instead of failing the file.
        let odd = #"{"camera":"always","microphone":"block","extra":1}"#
        let settings = try JSONDecoder().decode(SiteSettings.self, from: Data(odd.utf8))
        #expect(settings.camera == .ask)
        #expect(settings.microphone == .block)
    }

    @Test func cameraAndMicrophoneDecisions() {
        let page = "https://meet.example.com"
        var settings = SiteSettings()
        #expect(MediaRules.decide(.camera, settings: settings, requestingSite: page, pageSite: page) == .prompt)
        settings.camera = .allow
        #expect(MediaRules.decide(.camera, settings: settings, requestingSite: page, pageSite: page) == .grant)
        // Both are needed for a request for both.
        #expect(MediaRules.decide(.cameraAndMicrophone, settings: settings, requestingSite: page, pageSite: page) == .prompt)
        settings.microphone = .allow
        #expect(MediaRules.decide(.cameraAndMicrophone, settings: settings, requestingSite: page, pageSite: page) == .grant)
        // Allow never covers a frame from another site.
        #expect(MediaRules.decide(.camera, settings: settings, requestingSite: "https://ads.example.net", pageSite: page) == .prompt)
        #expect(MediaRules.decide(.camera, settings: settings, requestingSite: nil, pageSite: nil) == .prompt)
        // Block covers everything in the page, and wins.
        settings.microphone = .block
        #expect(MediaRules.decide(.cameraAndMicrophone, settings: settings, requestingSite: page, pageSite: page) == .deny)
        #expect(MediaRules.decide(.microphone, settings: settings, requestingSite: "https://ads.example.net", pageSite: page) == .deny)
        #expect(MediaRules.decide(.camera, settings: settings, requestingSite: page, pageSite: page) == .grant)
    }

    @Test func inspectionNeedsBothSwitchesAndTheExactSite() {
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        let site = "http://localhost:3000"
        space.setSettings(SiteSettings(agentsCanInspect: true), forSite: site)
        // Site on, Space off.
        #expect(!InspectionRules.isAllowed(space, site: site))
        #expect(InspectionRules.capturedSites(space).isEmpty)
        space.agentInspection = true
        // Still off: agents aren't enabled for the Space at all.
        #expect(!InspectionRules.isAllowed(space, site: site))
        space.agentsEnabled = true
        #expect(InspectionRules.isAllowed(space, site: site))
        #expect(InspectionRules.capturedSites(space) == [site])
        // Another port is another site.
        #expect(!InspectionRules.isAllowed(space, site: "http://localhost:5173"))
        #expect(!InspectionRules.isAllowed(space, site: nil))
        // Space on, site off.
        space.setSettings(SiteSettings(), forSite: site)
        #expect(!InspectionRules.isAllowed(space, site: site))
        #expect(InspectionRules.refusal(space: space, site: site).contains("localhost:3000"))
    }
}

@Suite struct PageCaptureTests {
    private func net(_ fields: [String: Any]) -> String {
        var object: [String: Any] = ["t": "net", "kind": "fetch", "method": "post", "url": "https://api.example.com/x", "status": 500]
        object.merge(fields) { $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func recordsConsoleAndNetworkAndHidesLogins() {
        var capture = PageCapture()
        capture.record(json: #"{"t":"console","level":"exception","text":"TypeError: x is undefined","source":"https://example.com/app.js","line":12}"#)
        capture.record(json: net(["reqHeaders": ["Authorization": "Bearer abc", "Content-Type": "application/json", "X-Api-Key": "k"],
                                  "reqBody": #"{"a":1}"#, "resHeaders": ["set-cookie": "sid=1", "content-type": "application/json"],
                                  "resBody": #"{"error":"boom"}"#]))
        let console = capture.consoleReport(since: nil)
        #expect(console.count == 1 && console.cursor == 1)
        #expect(console.text.contains("exception: TypeError: x is undefined"))
        #expect(console.text.contains("at https://example.com/app.js:12"))

        let network = capture.networkReport(since: nil)
        #expect(network.text.contains("POST https://api.example.com/x → 500 (fetch)"))
        #expect(network.text.contains("Authorization: [hidden]"))
        #expect(network.text.contains("X-Api-Key: [hidden]"))
        #expect(network.text.contains("set-cookie: [hidden]"))
        #expect(network.text.contains("Content-Type: application/json"))
        #expect(!network.text.contains("Bearer abc") && !network.text.contains("sid=1"))
        #expect(network.text.contains(#"{"error":"boom"}"#))
    }

    @Test func ignoresAnythingMisshapen() {
        var capture = PageCapture()
        for junk in ["", "not json", "[1,2]", #"{"t":"other"}"#, #"{"t":"console"}"#, #"{"t":"console","level":"info","text":"x"}"#,
                     #"{"t":"net"}"#, #"{"t":"console","text":5}"#] {
            capture.record(json: junk)
        }
        #expect(capture.isEmpty)
        // Odd field types are dropped, the entry is kept.
        capture.record(json: #"{"t":"net","url":"https://a/","status":"500","reqHeaders":[1],"resHeaders":{"a":1,"b":"c"}}"#)
        #expect(capture.network.count == 1)
        #expect(capture.network[0].status == nil)
        #expect(capture.network[0].responseHeaders.map(\.name) == ["b"])
    }

    @Test func cursorOnlyGrowsAndSaysWhatWasDropped() {
        var capture = PageCapture()
        for index in 1...250 { capture.record(json: #"{"t":"console","level":"error","text":"e\#(index)"}"#) }
        #expect(capture.console.count == PageCapture.maxConsoleEntries)
        let all = capture.consoleReport(since: nil)
        #expect(all.cursor == 250 && all.count == 200)
        #expect(all.text.hasPrefix("50 earlier entries were dropped"))
        // Asked from a cursor inside what is kept: nothing dropped, only newer entries.
        let some = capture.consoleReport(since: 248)
        #expect(some.count == 2 && !some.text.contains("dropped"))
        #expect(some.text.contains("e249") && !some.text.contains("e248"))
        #expect(capture.consoleReport(since: 250).text.hasPrefix("Nothing new"))
        // Clearing keeps the counter, so an old cursor doesn't match new entries.
        capture.clear()
        capture.record(json: #"{"t":"console","level":"error","text":"after"}"#)
        #expect(capture.consoleReport(since: 250).count == 1)
        #expect(capture.consoleReport(since: 251).count == 0)
    }

    @Test func cutsLongTextsAndCapsTheTab() {
        var capture = PageCapture()
        let long = String(repeating: "é", count: 60_000) // 120 000 bytes
        capture.record(json: net(["resBody": long, "reqBody": long]))
        let entry = capture.network[0]
        #expect(entry.responseBody!.contains("[cut: 120000 bytes in all"))
        #expect(entry.responseBody!.utf8.count < PageCapture.maxTextBytes + 200)
        #expect(entry.requestBody!.contains("[cut:"))
        // 4 MB in all: ~128 KB an entry, so about 32 fit.
        let body = String(repeating: "a", count: 64_000)
        for _ in 0..<60 { capture.record(json: net(["resBody": body, "reqBody": body])) }
        #expect(capture.network.count < 40)
        #expect(capture.networkReport(since: nil).text.contains("dropped"))
        #expect(capture.network.last?.seq == 61)
    }
}
