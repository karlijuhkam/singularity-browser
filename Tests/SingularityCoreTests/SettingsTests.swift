import Foundation
import Testing
@testable import SingularityCore

@Suite struct SettingsTests {
    @Test func defaultsAndMissingFields() throws {
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"terminalFontSize": 16}"#.utf8))
        #expect(partial.terminalFontSize == 16)
        #expect(partial.searchEngine == .duckDuckGo)
        #expect(partial.closeTerminalOnExit)
        #expect(partial.agentApprovalTimeoutSeconds == 120)
        // An unknown engine name (e.g. from a newer version) falls back instead of failing.
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"searchEngine": "altavista"}"#.utf8))
        #expect(unknown.searchEngine == .duckDuckGo)
    }

    @Test func checksForUpdatesSetting() throws {
        func decode(_ json: String) throws -> AppSettings { try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) }
        #expect(try decode("{}").checksForUpdates)
        #expect(try decode(#"{"checksForUpdates": false}"#).checksForUpdates == false)
        #expect(try decode(#"{"checksForUpdates": "no"}"#).checksForUpdates)
        var settings = AppSettings()
        settings.checksForUpdates = false
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.checksForUpdates == false)
    }

    @Test func roundTripThroughTheStore() throws {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = SpaceStore(paths: paths)
        #expect(store.loadSettings() == AppSettings())
        var settings = AppSettings()
        settings.searchEngine = .kagi
        settings.terminalFontName = "Menlo"
        try store.save(settings)
        #expect(store.loadSettings() == settings)
    }

    @Test func searchTemplates() {
        var settings = AppSettings()
        settings.searchEngine = .google
        #expect(URLInput.classify("swift actors", searchTemplate: settings.searchTemplate)
                == .search(URL(string: "https://www.google.com/search?q=swift%20actors")!))
        settings.searchEngine = .custom
        settings.customSearchTemplate = "https://search.example/find?term=%s&lang=et"
        #expect(settings.searchEngineName == "search.example")
        #expect(URLInput.classify("a&b", searchTemplate: settings.searchTemplate)
                == .search(URL(string: "https://search.example/find?term=a%26b&lang=et")!))
        // URLs are still URLs, whatever the engine.
        #expect(URLInput.classify("example.com", searchTemplate: settings.searchTemplate) == .url(URL(string: "https://example.com")!))
    }

    @Test func invalidCustomTemplateFallsBackToDuckDuckGo() {
        var settings = AppSettings()
        settings.searchEngine = .custom
        for bad in ["", "https://example.com/?q=", "not a url %s", "ftp://example.com/?q=%s"] {
            settings.customSearchTemplate = bad
            #expect(settings.searchTemplate == SearchEngine.duckDuckGo.template!, "\(bad)")
            #expect(settings.searchEngineName == "DuckDuckGo")
        }
    }
}

@Suite struct TerminalOptionKeyTests {
    @Test func eachModeDecidesMetaFromTheOptionKeysHeld() {
        #expect(!TerminalOptionKey.typesCharacters.isMeta(leftOptionDown: true, rightOptionDown: false))
        #expect(!TerminalOptionKey.typesCharacters.isMeta(leftOptionDown: false, rightOptionDown: true))
        #expect(TerminalOptionKey.meta.isMeta(leftOptionDown: true, rightOptionDown: false))
        #expect(TerminalOptionKey.meta.isMeta(leftOptionDown: false, rightOptionDown: true))
        #expect(TerminalOptionKey.leftMeta.isMeta(leftOptionDown: true, rightOptionDown: false))
        #expect(!TerminalOptionKey.leftMeta.isMeta(leftOptionDown: false, rightOptionDown: true))
    }

    @Test func typesCharactersByDefaultAndSurvivesARoundTrip() throws {
        #expect(AppSettings().terminalOptionKey == .typesCharacters)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.terminalOptionKey == .typesCharacters)
        let junk = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"terminalOptionKey":"sideways","terminalFontSize":15}"#.utf8))
        #expect(junk.terminalOptionKey == .typesCharacters)
        #expect(junk.terminalFontSize == 15)
        var settings = AppSettings()
        settings.terminalOptionKey = .leftMeta
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.terminalOptionKey == .leftMeta)
    }
}
