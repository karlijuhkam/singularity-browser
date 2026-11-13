import Foundation
import Testing
@testable import SingularityCore

/// The sidebar's pure rules: launchers, the one-emoji rule, the width, the slide-out.
@Suite struct SidebarTests {
    private func settings(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func launchersDefaultToClaudeAndCodex() throws {
        let launchers = try settings("{}").launchers
        #expect(launchers.map(\.command) == ["claude", "codex"])
        #expect(launchers.map(\.glyph) == [.logo("claude"), .logo("codex")])
        // The same two at every launch, so nothing about them changes until the owner edits the list.
        #expect(launchers == Launcher.defaults)
    }

    @Test func anEmptyLauncherListStaysEmpty() throws {
        #expect(try settings(#"{"launchers": []}"#).launchers.isEmpty)
        var mine = AppSettings()
        mine.launchers = []
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(mine)).launchers.isEmpty)
    }

    @Test func brokenLauncherEntriesAreDroppedAndTheRestSurvives() throws {
        let decoded = try settings(#"""
        {"terminalFontSize": 16, "launchers": [
          {"name": "Yolo", "command": "claude --dangerously-skip-permissions", "icon": "🔥"},
          {"name": "No command"},
          "not an object",
          {"name": "Wrong type", "command": 5},
          {"name": "Blank", "command": "   "},
          {"name": "Two lines", "command": "echo a\necho b", "icon": "words"}
        ]}
        """#)
        #expect(decoded.terminalFontSize == 16)
        #expect(decoded.launchers.map(\.command) == ["claude --dangerously-skip-permissions", "echo a echo b"])
        #expect(decoded.launchers[0].glyph == .emoji("🔥"))
        #expect(decoded.launchers[1].icon == "")
        #expect(decoded.launchers[1].glyph == .letter("T"))
    }

    @Test func aLauncherListOfTheWrongTypeFallsBackToTheDefaults() throws {
        #expect(try settings(#"{"launchers": "claude"}"#).launchers == Launcher.defaults)
    }

    @Test func cleaningKeepsOneEntryPerId() {
        let id = UUID()
        let cleaned = Launcher.clean([Launcher(id: id, name: "A", command: "a"), Launcher(id: id, name: "B", command: "b")])
        #expect(cleaned.map(\.name) == ["A"])
        #expect(Launcher(name: " ", command: "opencode").displayName == "opencode")
    }

    @Test func oneEmojiOrNothing() {
        #expect(Emoji.single("🎧") == "🎧")
        #expect(Emoji.single(" 🎧 ") == "🎧")
        #expect(Emoji.single("🎧🎸") == "🎧")
        #expect(Emoji.single("🇪🇪") == "🇪🇪")
        #expect(Emoji.single("👨‍👩‍👧") == "👨‍👩‍👧")
        #expect(Emoji.single("👍🏽") == "👍🏽")
        #expect(Emoji.single("❤️") == "❤️")
        #expect(Emoji.single("M") == nil)
        #expect(Emoji.single("Music 🎧") == nil)
        #expect(Emoji.single("7") == nil)
        #expect(Emoji.single("#") == nil)
        #expect(Emoji.single("") == nil)
    }

    @Test func aSpaceIconIsOneEmojiAndOldFilesHaveNone() throws {
        let base = ##""id": "6F1B1F0E-7C0B-4E9B-8B8F-0A1B2C3D4E5F", "name": "Music", "slug": "music", "colorHex": "#5E81F4""##
        func space(_ extra: String) throws -> Space {
            try JSONDecoder().decode(Space.self, from: Data("{\(base)\(extra)}".utf8))
        }
        #expect(try space("").icon == nil)
        #expect(try space(#", "icon": "🎧""#).icon == "🎧")
        #expect(try space(#", "icon": "headphones""#).icon == nil)
        #expect(try space(#", "icon": 7"#).icon == nil)
        var music = try space("")
        music.icon = "🎸"
        #expect(try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(music)).icon == "🎸")
    }

    @Test func theWidthStaysBetweenItsLimits() throws {
        #expect(SidebarLayout.clamp(100) == 220)
        #expect(SidebarLayout.clamp(300) == 300)
        #expect(SidebarLayout.clamp(900) == 480)
        #expect(SidebarLayout.clamp(.nan) == 270)
        #expect(try settings("{}").sidebarWidth == 270)
        #expect(try settings(#"{"sidebarWidth": 5000}"#).sidebarWidth == 480)
        #expect(try settings(#"{"sidebarWidth": "wide"}"#).sidebarWidth == 270)
        #expect(try settings("{}").sidebarHidden == false)
        #expect(try settings(#"{"sidebarHidden": true}"#).sidebarHidden)
    }

    @Test func theSlideOutOpensOnlyAtTheEdgeOfAnUncoveredKeyWindow() {
        var facts = SidebarPeekFacts()
        #expect(!SidebarPeek.shouldOpen(facts))
        facts.pointerAtEdge = true
        #expect(SidebarPeek.shouldOpen(facts))
        facts.windowIsKey = false
        #expect(!SidebarPeek.shouldOpen(facts))
        facts.windowIsKey = true
        facts.covered = true // the welcome flow or a sheet
        #expect(!SidebarPeek.shouldOpen(facts))
        facts.covered = false
        facts.hidden = false
        #expect(!SidebarPeek.shouldOpen(facts))
        // A drag or an open menu elsewhere never opens it.
        var dragging = SidebarPeekFacts()
        dragging.mouseButtonDown = true
        dragging.menuOpen = true
        #expect(!SidebarPeek.shouldOpen(dragging))
    }

    @Test func theSlideOutStaysUnderTheOwnersHand() {
        #expect(!SidebarPeek.shouldStay(SidebarPeekFacts()))
        for keyPath in [\SidebarPeekFacts.pointerInside, \.pointerAtEdge, \.menuOpen, \.mouseButtonDown, \.inboxOpenFromTray] {
            var facts = SidebarPeekFacts()
            facts[keyPath: keyPath] = true
            #expect(SidebarPeek.shouldStay(facts))
            facts.covered = true
            #expect(!SidebarPeek.shouldStay(facts))
            facts.covered = false
            facts.hidden = false
            #expect(!SidebarPeek.shouldStay(facts))
        }
        // The inbox panel may be the key window; everything else needs the browser window key.
        var away = SidebarPeekFacts()
        away.windowIsKey = false
        away.pointerInside = true
        #expect(!SidebarPeek.shouldStay(away))
        away.inboxOpenFromTray = true
        #expect(SidebarPeek.shouldStay(away))
    }
}
