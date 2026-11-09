import Foundation
import Testing
@testable import SingularityCore

@Suite struct ApprovalRuleTests {
    let shop = "https://shop.example.com"
    let other = "https://evil.example"

    func decide(_ kind: AgentActionKind, page: String? = nil, target: String? = nil, submit: Bool = false,
                _ policy: AgentPolicy, allowed: Set<String> = []) -> AgentDecision {
        AgentApprovalRules.decide(AgentActionContext(kind: kind, pageOrigin: page, targetOrigin: target, isFormSubmission: submit),
                                  policy: policy, allowedOrigins: allowed)
    }

    @Test func readsAreAlwaysAllowed() {
        for policy in AgentPolicy.allCases {
            for kind in [AgentActionKind.listTabs, .readPage, .find, .screenshot] {
                #expect(decide(kind, page: shop, policy) == .allow)
            }
        }
    }

    @Test func readOnlyDeniesEveryAction() {
        for kind in [AgentActionKind.open, .navigate, .close, .click, .type, .artifactPrompt] {
            #expect(decide(kind, page: shop, target: shop, .readOnly) == .deny(AgentApprovalRules.readOnlyReason))
        }
    }

    @Test func allowAllAllowsEverything() {
        #expect(decide(.click, page: shop, submit: true, .allowAll) == .allow)
        #expect(decide(.artifactPrompt, .allowAll) == .allow)
        #expect(decide(.open, target: other, .allowAll) == .allow)
    }

    @Test func askAsksUnlessTheSiteIsAllowed() {
        #expect(decide(.click, page: shop, .ask) == .ask(siteOrigin: shop))
        #expect(decide(.click, page: shop, .ask, allowed: [shop]) == .allow)
        #expect(decide(.type, page: shop, .ask, allowed: [shop]) == .allow)
        #expect(decide(.close, page: shop, .ask, allowed: [shop]) == .allow)
        // A link on an allowed page that leads to the same site.
        #expect(decide(.click, page: shop, target: shop, .ask, allowed: [shop]) == .allow)
    }

    @Test func formsAndPromptsAlwaysAskWithoutSiteOption() {
        #expect(decide(.type, page: shop, submit: true, .ask, allowed: [shop]) == .ask(siteOrigin: nil))
        #expect(decide(.click, page: shop, submit: true, .ask, allowed: [shop]) == .ask(siteOrigin: nil))
        #expect(decide(.artifactPrompt, page: "http://127.0.0.1:5000", .ask, allowed: ["http://127.0.0.1:5000"]) == .ask(siteOrigin: nil))
    }

    @Test func goingToAnotherSiteAsksEvenWhenThePageIsAllowed() {
        #expect(decide(.click, page: shop, target: other, .ask, allowed: [shop]) == .ask(siteOrigin: other))
        #expect(decide(.navigate, page: shop, target: other, .ask, allowed: [shop]) == .ask(siteOrigin: other))
        #expect(decide(.open, target: other, .ask, allowed: [shop]) == .ask(siteOrigin: other))
        #expect(decide(.open, target: shop, .ask, allowed: [shop]) == .allow)
    }

    @Test func origins() {
        #expect(AgentApprovalRules.origin(of: URL(string: "https://Shop.Example.com/a?b")) == "https://shop.example.com")
        #expect(AgentApprovalRules.origin(of: URL(string: "https://x.com:443/")) == "https://x.com")
        #expect(AgentApprovalRules.origin(of: URL(string: "http://127.0.0.1:54321/x.html")) == "http://127.0.0.1:54321")
        #expect(AgentApprovalRules.origin(of: URL(string: "about:blank")) == nil)
    }
}

@Suite struct AgentLogTests {
    @Test func appendLoadAndClip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AgentLogStore(file: file)
        for i in 0..<5 {
            try store.append(AgentLogEntry(client: "claude-code", tool: "work.click", tabID: nil, args: ["ref": "\(i)"],
                                           decision: "auto", ok: true, result: String(repeating: "x", count: 500), milliseconds: i))
        }
        let recent = store.loadRecent(limit: 3)
        #expect(recent.map { $0.args["ref"] } == ["2", "3", "4"])
        #expect(recent[0].result.count == AgentLogStore.maxValueLength)
        let line = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first.map(String.init) ?? ""
        #expect(line.contains("\"ts\":") && line.contains("\"ms\":0") && line.contains("\"decision\":\"auto\""))
    }

    @Test func oldFilesDecodeWithDefaults() throws {
        let space = try JSONDecoder().decode(Space.self, from: Data(##"{"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"W","slug":"w","colorHex":"#000000","tabs":[{"id":"10000000-0000-0000-0000-000000000001","kind":{"web":{"url":"https://a.test/"}},"title":"","isPinned":false}]}"##.utf8))
        #expect(space.agentPolicy == .ask)
        #expect(space.tabs[0].openedByAgent == false)
    }
}
