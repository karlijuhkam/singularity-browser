import Testing
@testable import SingularityCore

/// The command palette is centred over the page, beside the sidebar and the plugin panel.
@Suite struct PaletteLayoutTests {
    private func frame(_ window: Double, _ leading: Double, _ trailing: Double) -> PaletteLayout.Frame {
        PaletteLayout.frame(windowWidth: window, pageLeading: leading, pageTrailing: trailing)
    }

    @Test func centredOverThePageBesideTheSidebar() {
        // 1400 window, 260 sidebar, 8 pt margin at the right: the page is 1132 wide, from 260.
        let f = frame(1400, 260, 8)
        #expect(f.width == 640)
        #expect(f.x == 260 + (1132 - 640) / 2)
        // Its middle is the page's middle, not the window's.
        #expect(f.x + f.width / 2 == 260 + 1132 / 2)
    }

    @Test func centredOverTheWholeWindowWhenTheSidebarIsHidden() {
        let f = frame(1400, 8, 8)
        #expect(f.x + f.width / 2 == 700)
    }

    @Test func thePanelAtTheRightCountsToo() {
        // Sidebar 260, panel 380 plus the page's 8 pt margin.
        let f = frame(1600, 260, 388)
        #expect(f.x + f.width / 2 == 260 + (1600 - 260 - 388) / 2)
    }

    @Test func aNarrowPageGetsANarrowerPaletteWithItsMargins() {
        // Page 500 wide: 16 pt on each side.
        let f = frame(760, 252, 8)
        #expect(f.width == 500 - 32)
        #expect(f.x == 252 + 16)
    }

    @Test func aPageTooNarrowToCentreOverUsesTheWindow() {
        // Page 300 wide: less than the palette's minimum plus margins.
        let f = frame(560, 252, 8)
        #expect(f.width == 560 - 32)
        #expect(f.x == 16)
    }

    @Test func nonsenseInputStillGivesAFrame() {
        #expect(frame(.nan, 0, 0) == PaletteLayout.Frame(x: 0, width: 640))
        #expect(frame(0, 0, 0) == PaletteLayout.Frame(x: 0, width: 640))
        #expect(frame(20, 0, 0).width == 0)
    }
}
