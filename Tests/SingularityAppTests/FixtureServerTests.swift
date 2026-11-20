import Foundation
import Testing

extension AppTests {
/// The fixture servers leave no open files behind in the test process: a full run starts a few
/// hundred of them, and the test process may have only 256 files open (the launchd default).
/// Past that, WebKit can't open what a page load needs and every later load hangs.
@MainActor
@Suite(.serialized) struct FixtureServerTests {
    private func openFiles() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    @Test(.timeLimit(.minutes(1))) func serversLeaveNoOpenFiles() async throws {
        let before = openFiles()
        for _ in 0..<10 {
            let bench = try BenchServer.start()
            bench.stop()
            let title = try TitleFixtureServer.start()
            title.stop()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(openFiles() <= before + 2, "before \(before), after \(openFiles())")
    }
}
}
