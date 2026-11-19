import Foundation
import Testing
@testable import SingularityCore

@Suite struct HerdrShownTests {
    @Test func theOwnRowIsHighlightedOnlyWhileItsOwnTerminalIsShown() {
        #expect(HerdrShown.ownIsHighlighted(isSelected: true, shownChild: nil))
        #expect(!HerdrShown.ownIsHighlighted(isSelected: true, shownChild: "t3"))
        #expect(!HerdrShown.ownIsHighlighted(isSelected: false, shownChild: nil))
        #expect(!HerdrShown.ownIsHighlighted(isSelected: false, shownChild: "t3"))
    }

    @Test func aChildRowIsHighlightedWhileItIsOnScreen() {
        #expect(HerdrShown.childIsHighlighted(tabIsOnScreen: true, shownChild: "t3", address: "t3"))
        #expect(!HerdrShown.childIsHighlighted(tabIsOnScreen: true, shownChild: "t4", address: "t3"))
        #expect(!HerdrShown.childIsHighlighted(tabIsOnScreen: true, shownChild: nil, address: "t3"))
        #expect(!HerdrShown.childIsHighlighted(tabIsOnScreen: false, shownChild: "t3", address: "t3"))
    }

    @Test func anOwnClickClearsOnlyThatTab() {
        let one = UUID(), two = UUID(), three = UUID()
        let shown = [one: "t3", two: "t7"]
        #expect(HerdrShown.afterOwnClick(shown, tabID: one) == [two: "t7"])
        // A tab with no child shown: nothing changes.
        #expect(HerdrShown.afterOwnClick(shown, tabID: three) == shown)
        #expect(HerdrShown.afterOwnClick([:], tabID: one).isEmpty)
    }
}
