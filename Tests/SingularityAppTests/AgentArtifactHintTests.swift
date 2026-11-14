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

        let result = await AgentToolbox(state: state).call(AgentToolName.listSpaces, arguments: [:], client: "test", caller: .outside)
        #expect(result.isError != true)
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
        // JSONSerialization writes "/" as "\/".
        let folder = state.paths.artifactsDirectory(slug).path
        #expect(text.replacingOccurrences(of: "\\/", with: "/").contains("\"artifacts_folder\" : \"\(folder)\""), "got \(text)")
        // Where the Space's apps keep their databases, so an agent can write rows into one.
        let data = state.paths.appDataDirectory(slug).path
        #expect(text.replacingOccurrences(of: "\\/", with: "/").contains("\"app_data_folder\" : \"\(data)\""), "got \(text)")
        // No app bundle in a test run: no guide is named.
        #expect(!text.contains("app_guide"))
    }

    /// With the guide in the bundle's resources, `list_spaces` says where it is; a plugin's own
    /// connection (no file tools) is told no paths.
    @Test func listSpacesNamesTheAppGuideWhenItIsShipped() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "resources")
        try FileManager.default.createDirectory(at: resources.appending(path: "app-guide"), withIntermediateDirectories: true)
        try Data("# guide".utf8).write(to: resources.appending(path: "app-guide/AUTHORING.md"))
        let before = AgentToolbox.appGuideResources
        AgentToolbox.appGuideResources = resources
        defer { AgentToolbox.appGuideResources = before }

        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        state.closeWelcome()
        state.setAgentsEnabled(true, spaceID: try #require(state.selectedSpaceID))

        let result = await AgentToolbox(state: state).call(AgentToolName.listSpaces, arguments: [:], client: "test", caller: .outside)
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
        #expect(text.contains("app_guide: \(resources.path)/app-guide/AUTHORING.md"), "got \(text)")
    }
}
}
