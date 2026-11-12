import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The updater's wiring in the app. Never builds `AppUpdates` with `.available`: that would
/// start Sparkle, which reads the feed over the network.
@MainActor
@Suite(.serialized) struct UpdateStateTests {
    @Test func aTestRunIsNotAReleaseBuild() {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }

        // The test runner's Info.plist has no Sparkle keys.
        #expect(state.updates.availability == .unavailable(.notAReleaseBuild))
        #expect(state.updates.hasUpdater == false)
        #expect(state.updates.canCheck == false)
    }

    @Test func anUnavailableUpdaterDoesNothing() {
        MainRunLoopGuard.start
        let updates = AppUpdates(availability: .unavailable(.separateDataFolder), checksAutomatically: true)
        #expect(updates.hasUpdater == false)
        updates.checkNow()
        updates.setChecksAutomatically(false)
        updates.setChecksAutomatically(true)
        #expect(updates.canCheck == false)
    }

    @Test func theSettingIsSaved() {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }

        #expect(state.settings.checksForUpdates)
        state.updateSettings { $0.checksForUpdates = false }
        #expect(state.settings.checksForUpdates == false)
        state.flushSaves()
        #expect(SpaceStore(paths: Paths(root: root)).loadSettings().checksForUpdates == false)
    }

    @Test func thePaletteListsCheckForUpdates() {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }

        let titles = PaletteResults.items(for: "", mode: .newTab, state: state).map(\.title)
        #expect(titles.contains("Check for Updates…"))
    }
}
}
