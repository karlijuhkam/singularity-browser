import Testing
@testable import SingularityCore

/// The palette's search row sits right after the concrete matches, above the loose ones.
@Suite struct PaletteRankingTests {
    @Test func aPieceOfTheTextIsConcrete() {
        #expect(PaletteRanking.isConcrete("hub", in: ["GitHub", "https://github.com/"]))
        #expect(PaletteRanking.isConcrete("GITHUB", in: ["GitHub"]))
        #expect(PaletteRanking.isConcrete("rust book", in: ["The Rust Programming Language", "https://doc.rust-lang.org/book/"]))
    }

    @Test func initialsAreConcrete() {
        #expect(PaletteRanking.isConcrete("ns", in: ["New Space", ""]))
        #expect(PaletteRanking.isConcrete("gh", in: ["GitHub"]))
        #expect(PaletteRanking.isConcrete("nt", in: ["new-terminal"]))
    }

    @Test func lettersScatteredAcrossAnAddressAreNot() {
        let fields = ["Pull requests · acme/widgets", "https://github.com/acme/widgets/pulls?q=is%3Aopen+sort%3Aupdated-desc"]
        #expect(!PaletteRanking.isConcrete("weather", in: fields))
        #expect(!PaletteRanking.isConcrete("swift concurrency", in: fields))
        // Every word must be there, not just one of them.
        #expect(!PaletteRanking.isConcrete("widgets weather", in: fields))
        #expect(!PaletteRanking.isConcrete("   ", in: fields))
    }

    @Test func searchComesFirstWithoutConcreteMatches() {
        let order = PaletteRanking.placingSearch("search", among: ["loose1", "loose2"]) { $0.hasPrefix("concrete") }
        #expect(order == ["search", "loose1", "loose2"])
    }

    @Test func searchComesAfterTheConcreteMatchesAndBeforeTheLooseOnes() {
        let order = PaletteRanking.placingSearch("search", among: ["loose1", "concrete1", "loose2", "concrete2"]) { $0.hasPrefix("concrete") }
        #expect(order == ["concrete1", "concrete2", "search", "loose1", "loose2"])
    }

    @Test func searchIsLastWhenEverythingIsConcrete() {
        let order = PaletteRanking.placingSearch("search", among: ["concrete1"]) { $0.hasPrefix("concrete") }
        #expect(order == ["concrete1", "search"])
    }
}
