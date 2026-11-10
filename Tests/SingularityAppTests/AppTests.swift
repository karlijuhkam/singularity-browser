import Foundation
import Testing

/// The parent of every suite in this target, so that all of them run one test at a time: they
/// share one `NSApplication` (windows, sheets, web views). `.serialized` on the parent covers
/// the nested suites too. New suites go in an `extension AppTests { … }`.
@MainActor
@Suite(.serialized) struct AppTests {}

/// Keeps the test process alive when AppKit stops the main run loop.
///
/// In the test runner the main thread sits in one plain `CFRunLoopRun()`, and when that returns
/// the process quits quietly with status 0, half-way through the tests. AppKit stops "the current
/// run loop" in a few places, ending an alert sheet among them; in the real app that only wakes
/// `NSApplication`'s own loop. So tests that show windows call `MainRunLoopGuard.start` first:
/// it parks a loop of its own on the main thread, inside the runner's, which takes those stops
/// and simply runs again. Main-actor work keeps flowing: a nested run loop serves the main queue.
enum MainRunLoopGuard {
    static let start: Void = {
        // As a run-loop block, not `DispatchQueue.main.async`: inside a main-queue block the
        // main queue is busy, and nothing else queued on it would run.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            while true { CFRunLoopRunInMode(.defaultMode, 3600, false) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }()
}
