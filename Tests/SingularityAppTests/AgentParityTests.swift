import AppKit
import Foundation
import MCP
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// The agent door against the bench pages (`Fixtures/bench`): what an agent can read and do on
/// hard pages (frames, dialogs, file choosers, keys, drag…), measured against Playwright MCP on
/// 2026-11-20. Agent tabs load in the background: no window, never on screen, never key.
@MainActor
@Suite(.serialized) struct AgentParityTests {
    @MainActor final class Rig {
        let root = TestAppState.makeRoot()
        let server: BenchServer
        let state: AppState
        let spaceID: UUID
        let toolbox: AgentToolbox
        var tab = ""
        /// The last `read_page` answer, for `ref(_:)`.
        var lastRead = ""

        init(policy: AgentPolicy = .allowAll) throws {
            MainRunLoopGuard.start
            server = try BenchServer.start()
            let store = SpaceStore(paths: Paths(root: root))
            let space = Space(name: "Bench", slug: "bench", colorHex: "#3366CC", agentsEnabled: true, agentPolicy: policy)
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
            state = TestAppState.make(root: root)
            spaceID = space.id
            toolbox = AgentToolbox(state: state)
        }

        func tearDown() {
            TestAppState.shutDown(state)
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func call(_ tool: String, _ arguments: [String: Value] = [:], client: String = "bench") async -> (text: String, isError: Bool) {
            var args = arguments
            if args["tab_id"] == nil, !tab.isEmpty, tool != "open" { args["tab_id"] = .string(tab) }
            let result = await toolbox.call("bench.\(tool)", arguments: args, client: client, caller: .outside)
            let text = result.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
            return (text, result.isError ?? false)
        }

        /// Opens a bench page in a new agent tab and reads it.
        func open(_ page: String, query: String = "") async throws {
            let answer = await call("open", ["url": .string(server.url(page, query: query).absoluteString)])
            let id = try #require(answer.text.firstMatch(of: /tab_id ([0-9a-f-]{36})/)?.1)
            tab = String(id)
            _ = await read()
        }

        @discardableResult
        func read() async -> String {
            lastRead = await call("read_page").text
            return lastRead
        }

        /// The ref of the first line in the last read that mentions `name` (with `role` if given),
        /// as the agent would write it: "12" or "f1:3".
        func ref(_ name: String, role: String? = nil) throws -> Value {
            for line in lastRead.split(separator: "\n") where line.contains("\"\(name)") {
                if let role, !line.contains("] \(role) ") { continue }
                if let match = line.firstMatch(of: /\[((?:f\d+:)?\d+)\]/) {
                    let text = String(match.1)
                    return Int(text).map { .int($0) } ?? .string(text)
                }
            }
            Issue.record("no ref for \(name) in:\n\(lastRead)")
            throw CancellationError()
        }

        /// Every ref whose line mentions `name`, in page order.
        func refs(_ name: String) -> [Value] {
            lastRead.split(separator: "\n").filter { $0.contains("\"\(name)") }.compactMap { line in
                guard let match = line.firstMatch(of: /\[((?:f\d+:)?\d+)\]/) else { return nil }
                let text = String(match.1)
                return Int(text).map { .int($0) } ?? .string(text)
            }
        }

        /// The page's `RESULT:` line (main frame), read fresh.
        func result() async -> String {
            let page = await read()
            return page.split(separator: "\n").last { $0.contains("RESULT:") }.map(String.init) ?? ""
        }

        func waitForResult(_ expected: String, limit: Duration = .seconds(5)) async -> String {
            let deadline = ContinuousClock.now + limit
            var last = ""
            while ContinuousClock.now < deadline {
                last = await result()
                if last.contains(expected) { return last }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return last
        }
    }

    // MARK: - What already worked on 2026-11-20

    @Test(.timeLimit(.minutes(1))) func selectByType() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("select.html")
        await rig.call("type", ["ref": try rig.ref("City"), "text": "Tallinn"])
        #expect(await rig.result().contains("RESULT: Tallinn"))
    }

    @Test(.timeLimit(.minutes(1))) func modalDialog() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("modal.html")
        await rig.call("click", ["ref": try rig.ref("Rename project")])
        await rig.read()
        await rig.call("type", ["ref": try rig.ref("New name"), "text": "Atlas"])
        await rig.call("click", ["ref": try rig.ref("Save")])
        #expect(await rig.result().contains("renamed to Atlas"))
    }

    @Test(.timeLimit(.minutes(1))) func openShadowRoot() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("shadow.html")
        await rig.call("type", ["ref": try rig.ref("Coupon"), "text": "SAVE10"])
        await rig.call("click", ["ref": try rig.ref("Apply coupon")])
        #expect(await rig.result().contains("coupon SAVE10"))
    }

    @Test(.timeLimit(.minutes(1))) func formFieldsAndSubmit() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("form.html")
        await rig.call("type", ["ref": try rig.ref("Name"), "text": "Karli"])
        await rig.call("click", ["ref": try rig.ref("Newsletter")])
        await rig.call("click", ["ref": try rig.ref("Pro")])
        await rig.call("type", ["ref": try rig.ref("Start"), "text": "2026-12-01"])
        await rig.call("type", ["ref": try rig.ref("Seats"), "text": "7"])
        await rig.call("click", ["ref": try rig.ref("Create account")])
        let result = await rig.waitForResult("submitted")
        #expect(result.contains("name=Karli"))
        #expect(result.contains("news=yes"))
        #expect(result.contains("plan=pro"))
        #expect(result.contains("seats=7"))
    }

    @Test(.timeLimit(.minutes(1))) func scrollBoxButton() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("scrollbox.html")
        await rig.call("click", ["ref": try rig.ref("Deep button")])
        #expect(await rig.result().contains("deep button"))
    }

    @Test(.timeLimit(.minutes(1))) func spaRouteEventually() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("spa.html")
        await rig.call("click", ["ref": try rig.ref("Orders")])
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline, !(await rig.read()).contains("Open #1042") {
            try await Task.sleep(for: .milliseconds(200))
        }
        await rig.call("click", ["ref": try rig.ref("Open #1042")])
        #expect(await rig.result().contains("order 1042 opened"))
    }

    // MARK: - Frames

    @Test(.timeLimit(.minutes(1))) func sameOriginFrameIsReadAndClicked() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("iframe.html")
        let codes = rig.refs("Code")
        try #require(codes.count == 2, "\(rig.lastRead)")
        let type = await rig.call("type", ["ref": codes[0], "text": "XO"])
        #expect(!type.isError, "\(type.text)")
        let apply = rig.refs("Apply")
        try #require(apply.count == 2)
        await rig.call("click", ["ref": apply[0]])
        #expect(await rig.read().contains("frame got XO at \(rig.server.port)"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func crossOriginFrameIsReadAndClicked() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("iframe.html")
        let codes = rig.refs("Code")
        try #require(codes.count == 2, "\(rig.lastRead)")
        await rig.call("type", ["ref": codes[1], "text": "XO"])
        await rig.call("click", ["ref": rig.refs("Apply")[1]])
        #expect(await rig.read().contains("frame got XO at \(rig.server.otherPort)"), "\(rig.lastRead)")
        #expect(rig.lastRead.contains("iframe"))
    }

    @Test(.timeLimit(.minutes(1))) func nestedFramesTwoDeep() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("nested.html")
        let click = await rig.call("click", ["ref": try rig.ref("Leaf button")])
        #expect(!click.isError, "\(click.text)")
        #expect(await rig.read().contains("leaf clicked"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func findSearchesFrames() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("iframe.html")
        let found = await rig.call("find", ["query": "Apply"])
        #expect(found.text.contains("[f"), "\(found.text)")
    }

    @Test(.timeLimit(.minutes(1))) func manyFramesStayBounded() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("frames-many.html")
        let started = ContinuousClock.now
        let page = await rig.read()
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(page.contains("not read"), "\(page.prefix(2000))")
    }

    @Test(.timeLimit(.minutes(1))) func aStaleFrameRefIsRefused() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("iframe.html")
        let code = rig.refs("Code")[0]
        let tabID = try #require(UUID(uuidString: rig.tab))
        let controller = try #require(rig.state.web.existingController(tabID))
        _ = try await controller.webView.evaluateJavaScript("document.querySelector('iframe').src = 'frame-inner.html?again=1'; 1")
        try await Task.sleep(for: .milliseconds(800))
        let type = await rig.call("type", ["ref": code, "text": "late"])
        #expect(type.isError)
        #expect(type.text.contains("read_page again"), "\(type.text)")
    }

    @Test(.timeLimit(.minutes(1))) func pageScriptsNeverSeeTheHandshake() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("messages.html")
        await rig.read()
        await rig.read()
        #expect(rig.lastRead.contains("Inner"), "\(rig.lastRead)")
        #expect(await rig.result().contains("RESULT: none"), "\(rig.lastRead)")
    }
}
}
