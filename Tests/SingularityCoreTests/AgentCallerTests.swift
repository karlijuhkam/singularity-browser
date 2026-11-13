import Foundation
import Testing
@testable import SingularityCore

@Suite struct AgentCallerTests {
    private let work = Space(name: "Work", slug: "work", colorHex: "#000000", agentsEnabled: true)
    private let home = Space(name: "Home", slug: "home", colorHex: "#000000", agentsEnabled: false)
    private let shop = Space(name: "Shop", slug: "shop", colorHex: "#000000", agentsEnabled: true)

    private var assistant: AgentCaller { .plugin(id: "assistant", title: "Assistant") }

    @Test func anOutsideAgentGetsTheSpacesWithAgentsOn() {
        // The plugin's switches don't matter to an outside agent.
        let spaces = AgentCaller.spaces([work, home, shop], caller: .outside, isOpenForPlugin: { _ in true })
        #expect(spaces.map(\.slug) == ["work", "shop"])
    }

    @Test func aPluginGetsOnlyTheSpacesSwitchedOnForIt() {
        // Home has agents off but is switched on for the plugin; Work has agents on but isn't.
        let open: Set<UUID> = [home.id, shop.id]
        let spaces = AgentCaller.spaces([work, home, shop], caller: assistant, isOpenForPlugin: { open.contains($0.id) })
        #expect(spaces.map(\.slug) == ["home", "shop"])
        // Nothing switched on: nothing.
        #expect(AgentCaller.spaces([work, home, shop], caller: assistant, isOpenForPlugin: { _ in false }).isEmpty)
    }

    @Test func aDeletedSpaceIsGoneForThePlugin() {
        // The switch may still name the deleted Space's id: it isn't among the Spaces any more.
        let open: Set<UUID> = [home.id]
        #expect(AgentCaller.spaces([work, shop], caller: assistant, isOpenForPlugin: { open.contains($0.id) }).isEmpty)
    }

    @Test func theClientNameIsThePluginsTitle() {
        #expect(assistant.clientName(introducedAs: "claude-code") == "Assistant")
        #expect(AgentCaller.outside.clientName(introducedAs: "claude-code") == "claude-code")
        #expect(assistant.pluginID == "assistant")
        #expect(AgentCaller.outside.pluginID == nil)
    }

    @Test func theTitleIsThePanelTitleElseTheName() throws {
        func manifest(_ panel: String) throws -> PluginManifest {
            try JSONDecoder().decode(PluginManifest.self, from: Data("""
                {"id": "m", "name": "Helper", "version": "1.0.0", "description": "", "author": "A",
                 "background": "background.ts", "permissions": {"browser": true, "programs": ["x"]} \(panel)}
                """.utf8))
        }
        #expect(AgentCaller.title(of: try manifest(#", "panel": {"page": "p.html", "title": "Assistant"}"#)) == "Assistant")
        #expect(AgentCaller.title(of: try manifest("")) == "Helper")
    }

    @Test func theRefusalTexts() {
        #expect(AgentCaller.spaceOff(title: "Assistant", space: "Work") == "Assistant is switched off in the “Work” Space.")
        #expect(AgentCaller.siteOff(title: "Assistant") == "Assistant is switched off for this site.")
        #expect(AgentCaller.noSpaces(title: "Assistant")
                == "No Spaces are open to Assistant. The user can switch it on for a Space with the button under the chat, or in Settings → Plugins.")
    }
}
