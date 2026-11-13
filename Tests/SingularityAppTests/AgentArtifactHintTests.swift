import Foundation
import MCP
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// An agent asked for "an artifact" must be able to learn where one goes: `list_spaces` names the
/// Space's artifacts folder (a page written there gets a tab by itself).
@MainActor
@Suite(.serialized) struct AgentArtifactHintTests {
    @Test func listSpacesNamesTheArtifactsFolder() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        state.closeWelcome()

        let spaceID = try #require(state.selectedSpaceID)
        state.setAgentsEnabled(true, spaceID: spaceID)
        let slug = try #require(state.space(spaceID)?.slug)

        let result = await AgentToolbox(state: state).call(AgentToolName.listSpaces, arguments: [:], client: "test")
        #expect(result.isError != true)
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
        // JSONSerialization writes "/" as "\/".
        let folder = state.paths.artifactsDirectory(slug).path
        #expect(text.replacingOccurrences(of: "\\/", with: "/").contains("\"artifacts_folder\" : \"\(folder)\""), "got \(text)")
    }
}
}
