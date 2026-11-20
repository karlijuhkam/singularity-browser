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

    // MARK: - Real clicks and keys

    @Test(.timeLimit(.minutes(1))) func clickIsTrusted() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("trusted.html")
        await rig.call("click", ["ref": try rig.ref("Check click")])
        #expect(await rig.result().contains("click trusted=true"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func doubleClick() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("trusted.html")
        await rig.call("click", ["ref": try rig.ref("Double me"), "double": .bool(true)])
        #expect(await rig.result().contains("double 2"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func aCoveredButtonIsNotClicked() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("overlay.html")
        let click = await rig.call("click", ["ref": try rig.ref("Buy now")])
        #expect(click.isError)
        #expect(click.text.contains("covered"), "\(click.text)")
        #expect(click.text.contains("Accept cookies"), "\(click.text)")
        #expect(await rig.result().contains("RESULT: none"))
        // Accepting the banner uncovers it.
        await rig.call("click", ["ref": try rig.ref("Accept cookies")])
        await rig.read()
        await rig.call("click", ["ref": try rig.ref("Buy now")])
        #expect(await rig.result().contains("buy clicked"))
    }

    @Test(.timeLimit(.minutes(1))) func aHiddenMenuItemStillWorks() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("hover.html")
        let found = await rig.call("find", ["query": "Settings"])
        let ref = try #require(found.text.firstMatch(of: /\[(\d+)\] link/).map { Int($0.1)! })
        let click = await rig.call("click", ["ref": .int(ref)])
        #expect(click.text.contains("not visible"), "\(click.text)")
        #expect(await rig.result().contains("settings via css hover"))
    }

    @Test(.timeLimit(.minutes(1))) func maskedInputGetsKeysWhenSlowly() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("inputs.html")
        let fields = rig.lastRead.split(separator: "\n").filter { $0.contains("] textbox") }
        try #require(fields.count >= 2)
        let masked = try #require(fields[1].firstMatch(of: /\[(\d+)\]/).map { Int($0.1)! })
        await rig.call("type", ["ref": .int(masked), "text": "bbb", "slowly": .bool(true)])
        #expect(await rig.read().contains("B=bbb"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func enterSubmitsSearch() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("keys.html")
        await rig.call("type", ["ref": try rig.ref("Search docs"), "text": "webkit", "submit": .bool(true)])
        #expect(await rig.result().contains("searched webkit"))
    }

    @Test(.timeLimit(.minutes(1))) func pressEscapeClosesPopover() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("keys.html")
        await rig.call("click", ["ref": try rig.ref("Open popover")])
        let press = await rig.call("press_key", ["key": "Escape"])
        #expect(!press.isError, "\(press.text)")
        #expect(await rig.result().contains("popover closed with Escape"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func pressControlK() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("keys.html")
        let press = await rig.call("press_key", ["key": "Control+k"])
        #expect(!press.isError, "\(press.text)")
        #expect(await rig.result().contains("ctrl+k"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func clipboardKeysAreRefused() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("keys.html")
        for key in ["Meta+v", "Meta+c", "Meta+x", "Shift+Insert"] {
            let press = await rig.call("press_key", ["key": .string(key)])
            #expect(press.isError, "\(key)")
            #expect(press.text.contains("clipboard"), "\(press.text)")
        }
        let bad = await rig.call("press_key", ["key": "Hyper+q"])
        #expect(bad.isError && bad.text.contains("Unknown modifier"), "\(bad.text)")
    }

    // MARK: - Dialogs and file choosers

    @Test(.timeLimit(.minutes(1))) func confirmIsReportedAndAccepted() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("dialogs.html")
        let click = await rig.call("click", ["ref": try rig.ref("Delete item")])
        #expect(click.text.hasPrefix("A dialog is waiting on this tab: confirm"), "\(click.text)")
        #expect(click.text.contains("Delete item?"))
        let answer = await rig.call("handle_dialog", ["accept": .bool(true)])
        #expect(!answer.isError, "\(answer.text)")
        #expect(await rig.result().contains("confirmed"))
    }

    @Test(.timeLimit(.minutes(1))) func alertAndPromptAnswers() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("dialogs.html")
        await rig.call("click", ["ref": try rig.ref("Show alert")])
        await rig.call("handle_dialog", ["accept": .bool(true)])
        #expect(await rig.result().contains("alert closed"))
        await rig.call("click", ["ref": try rig.ref("Ask name")])
        await rig.call("handle_dialog", ["accept": .bool(true), "prompt_text": "Ann"])
        #expect(await rig.result().contains("prompt: Ann"))
        await rig.call("click", ["ref": try rig.ref("Delete item")])
        await rig.call("handle_dialog", ["accept": .bool(false)])
        #expect(await rig.result().contains("cancelled"))
    }

    @Test(.timeLimit(.minutes(1))) func otherActionsWaitForTheDialog() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("dialogs.html")
        let ref = try rig.ref("Delete item")
        await rig.call("click", ["ref": ref])
        let again = await rig.call("click", ["ref": ref])
        #expect(again.isError)
        #expect(again.text.contains("A dialog is waiting"), "\(again.text)")
        let read = await rig.call("read_page")
        #expect(read.isError && read.text.contains("handle_dialog"), "\(read.text)")
        let none = await rig.call("file_upload", ["paths": .array([])])
        #expect(none.isError && none.text.contains("No file chooser"), "\(none.text)")
        await rig.call("handle_dialog", ["accept": .bool(true)])
        let stray = await rig.call("handle_dialog", ["accept": .bool(true)])
        #expect(stray.isError && stray.text.contains("No dialog"), "\(stray.text)")
    }

    @Test(.timeLimit(.minutes(1))) func aLateDialogIsReportedOnTheNextCall() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("late-dialog.html")
        await rig.call("click", ["ref": try rig.ref("Leave later")])
        try await Task.sleep(for: .milliseconds(700))
        let next = await rig.call("screenshot")
        #expect(next.text.contains("Really leave?"), "\(next.text)")
        await rig.call("handle_dialog", ["accept": .bool(true)])
        #expect(await rig.result().contains("left"))
    }

    @Test(.timeLimit(.minutes(1))) func anUnansweredDialogTimesOut() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        WebTabController.modalHoldLimit = .seconds(1)
        defer { WebTabController.modalHoldLimit = .seconds(120) }
        try await rig.open("dialogs.html")
        await rig.call("click", ["ref": try rig.ref("Delete item")])
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await rig.result().contains("cancelled"))
    }

    @Test(.timeLimit(.minutes(1))) func closingTheTabAnswersTheDialog() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("dialogs.html")
        await rig.call("click", ["ref": try rig.ref("Delete item")])
        let tabID = try #require(UUID(uuidString: rig.tab))
        let controller = try #require(rig.state.web.existingController(tabID))
        #expect(controller.pendingModal != nil)
        let close = await rig.call("close")
        #expect(!close.isError, "\(close.text)")
        #expect(controller.pendingModal == nil)
    }

    @Test(.timeLimit(.minutes(1))) func fileUploadAfterClick() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        var shown: [String] = []
        rig.state.approvals.presenter = { pending in shown.append(pending.request.detail); return .approved }
        try await rig.open("upload.html")
        let click = await rig.call("click", ["ref": try rig.ref("Invoice PDF")])
        #expect(click.text.hasPrefix("A file chooser is waiting on this tab"), "\(click.text)")
        let file = BenchServer.folder.appending(path: "invoice.pdf").resolvingSymlinksInPath().path
        let upload = await rig.call("file_upload", ["paths": .array([.string(file)])])
        #expect(!upload.isError, "\(upload.text)")
        #expect(shown.count == 1 && shown[0].contains(file), "the card names the file: \(shown)")
        #expect(await rig.waitForResult("file invoice.pdf").contains("bytes"))
    }

    @Test(.timeLimit(.minutes(1))) func fileUploadDeniedLeavesNothing() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.state.approvals.presenter = { _ in .denied }
        try await rig.open("upload.html")
        await rig.call("click", ["ref": try rig.ref("Invoice PDF")])
        let file = BenchServer.folder.appending(path: "invoice.pdf").path
        let upload = await rig.call("file_upload", ["paths": .array([.string(file)])])
        #expect(upload.isError, "\(upload.text)")
        let tabID = try #require(UUID(uuidString: rig.tab))
        #expect(rig.state.web.existingController(tabID)?.pendingModal != nil, "still waiting for an answer")
        await rig.call("file_upload", ["paths": .array([])]) // cancels: asks too
    }

    @Test(.timeLimit(.minutes(1))) func fileUploadWithoutChooserIsRefused() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("upload.html")
        let upload = await rig.call("file_upload", ["paths": .array([.string("/etc/hosts")])])
        #expect(upload.isError && upload.text.contains("No file chooser"), "\(upload.text)")
    }

    /// The owner's own tab, not on screen and not an agent's: its file chooser is cancelled at once,
    /// never an app-modal panel (that would block the whole app; a test would hang here).
    @Test(.timeLimit(.minutes(1))) func aChooserForATabWithNoWindowNeverOpensAPanel() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.state.openInNewTab(rig.server.url("upload.html"), spaceID: rig.spaceID, target: .nowhere)
        let tab = try #require(rig.state.space(rig.spaceID)?.tabs.last)
        #expect(!tab.openedByAgent)
        let controller = try #require(await rig.state.liveWebController(tabID: tab.id, spaceID: rig.spaceID))
        try await waitUntil("the page", limit: .seconds(10)) { !controller.webView.isLoading && controller.webView.url != nil }
        _ = try await controller.callPageAgent("snapshot(maxChars)", arguments: ["maxChars": 2000]) // ref 1: the file field
        struct Point: Decodable { let x: Double; let y: Double }
        let point = try JSONDecoder().decode(Point.self, from: Data(try await controller.callPageAgent("point(ref)", arguments: ["ref": 1]).utf8))
        AgentInput.click(controller.webView, at: CGPoint(x: point.x, y: point.y), double: false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.pendingModal == nil)
        #expect(NSApp.modalWindow == nil)
    }

    // MARK: - Snapshot detail, hover, drag, wait_for

    @Test(.timeLimit(.minutes(1))) func selectOptionsAreListed() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("select.html")
        #expect(rig.lastRead.contains("option \"Tallinn\""), "\(rig.lastRead)")
        #expect(rig.lastRead.contains("option \"Choose…\" selected"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func comboboxOptionsInReadPage() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("combobox.html")
        await rig.call("type", ["ref": try rig.ref("Country"), "text": "Fr"])
        try await Task.sleep(for: .milliseconds(600))
        await rig.read()
        let france = try rig.ref("France", role: "option")
        await rig.call("click", ["ref": france])
        #expect(await rig.result().contains("RESULT: France"))
    }

    @Test(.timeLimit(.minutes(1))) func tableRowsKeepTheirCells() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("spa.html")
        await rig.call("click", ["ref": try rig.ref("Orders")])
        await rig.call("wait_for", ["text": "Open #1042"])
        #expect(await rig.read().contains("row: \"#1042\" | \"17.50\""), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func sliderValueShown() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("form.html")
        await rig.call("type", ["ref": try rig.ref("Seats"), "text": "7"])
        #expect(await rig.read().contains("slider \"Seats\" value=\"7\""), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func hoverShowsAJsMenu() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("hover.html")
        #expect(!rig.lastRead.contains("Export"))
        let found = await rig.call("find", ["query": "Tools"])
        let tools = try #require(found.text.firstMatch(of: /\[(\d+)\] text/).map { Int($0.1)! }, "\(found.text)")
        let hover = await rig.call("hover", ["ref": .int(tools)])
        #expect(!hover.isError, "\(hover.text)")
        #expect(hover.text.contains("simulated"), "\(hover.text)")
        await rig.read()
        await rig.call("click", ["ref": try rig.ref("Export")])
        #expect(await rig.result().contains("export via js hover"))
    }

    @Test(.timeLimit(.minutes(1))) func dragReorders() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("drag.html")
        let drag = await rig.call("drag", ["start_ref": try rig.ref("Gamma"), "end_ref": try rig.ref("Alpha")])
        #expect(!drag.isError, "\(drag.text)")
        #expect(await rig.result().contains("order Gamma,Alpha,Beta"), "\(rig.lastRead)")
    }

    @Test(.timeLimit(.minutes(1))) func waitForText() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("spa.html")
        await rig.call("click", ["ref": try rig.ref("Orders")])
        let wait = await rig.call("wait_for", ["text": "Open #1042"])
        #expect(!wait.isError, "\(wait.text)")
        #expect(await rig.read().contains("Open #1042"))
    }

    @Test(.timeLimit(.minutes(1))) func waitForTextGone() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("spa.html")
        await rig.call("click", ["ref": try rig.ref("Orders")])
        let wait = await rig.call("wait_for", ["text_gone": "Loading…"])
        #expect(!wait.isError, "\(wait.text)")
        #expect(await rig.read().contains("Open #1042"))
    }

    @Test(.timeLimit(.minutes(1))) func waitForTimesOut() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("spa.html")
        let started = ContinuousClock.now
        let wait = await rig.call("wait_for", ["text": "Never here", "seconds": .int(1)])
        #expect(wait.isError, "\(wait.text)")
        #expect(wait.text.contains("Never here"))
        #expect(ContinuousClock.now - started < .seconds(4))
        let plain = await rig.call("wait_for", ["seconds": .int(1)])
        #expect(!plain.isError, "\(plain.text)")
    }

    @Test(.timeLimit(.minutes(1))) func lazyListLoadsOnScroll() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("lazy.html")
        for _ in 0..<5 where !(await rig.read()).contains("Item 50") {
            let last = rig.lastRead.split(separator: "\n").last { $0.contains("button \"Item ") }
            let ref = try #require(last?.firstMatch(of: /\[(\d+)\]/).map { Int($0.1)! })
            await rig.call("click", ["ref": .int(ref)])
            try await Task.sleep(for: .milliseconds(600))
        }
        #expect(rig.lastRead.contains("Item 50"))
    }

    // MARK: - Pop-ups

    @Test(.timeLimit(.minutes(1))) func agentPopupIsNotSelected() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("newtab.html")
        let selectedBefore = rig.state.space(rig.spaceID)?.selectedTabID
        let link = await rig.call("click", ["ref": try rig.ref("Open report in new tab")])
        #expect(link.text.contains("Opened a new tab tab_id"), "\(link.text)")
        let button = await rig.call("click", ["ref": try rig.ref("Popup report")])
        #expect(button.text.contains("Opened a new tab tab_id"), "\(button.text)")
        let space = try #require(rig.state.space(rig.spaceID))
        #expect(space.selectedTabID == selectedBefore)
        let popups = space.tabs.filter { $0.id.uuidString.lowercased() != rig.tab }
        #expect(popups.count == 2)
        #expect(popups.allSatisfy { $0.openedByAgent })
    }

    @Test(.timeLimit(.minutes(1))) func ownerPopupIsStillSelected() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("newtab.html")
        let source = try #require(UUID(uuidString: rig.tab))
        let controller = try #require(rig.state.web.existingController(source))
        _ = rig.state.openPopup(from: source, spaceID: rig.spaceID, configuration: controller.webView.configuration,
                                url: rig.server.url("target.html"))
        let space = try #require(rig.state.space(rig.spaceID))
        let popup = try #require(space.tabs.last)
        #expect(space.selectedTabID == popup.id)
        #expect(!popup.openedByAgent)
    }

    // MARK: - Final review fixes

    /// Keys pressed into a frame's password field are masked; Enter in a frame's form counts as a
    /// form submission (C2).
    @Test(.timeLimit(.minutes(1))) func pressKeyLooksIntoTheFocusedFrame() async throws {
        let rig = try Rig(policy: .ask)
        defer { rig.tearDown() }
        var actions: [String] = []
        rig.state.approvals.presenter = { pending in actions.append(pending.request.action); return .approved }
        try await rig.open("frame-login.html")
        await rig.call("click", ["ref": try rig.ref("Password")])
        actions.removeAll()
        let x = await rig.call("press_key", ["key": "x"])
        #expect(!x.isError, "\(x.text)")
        #expect(actions == ["press a key"], "\(actions)")
        let log = try String(contentsOf: rig.state.paths.agentLogFile("bench"), encoding: .utf8)
        #expect(!log.contains("\"key\":\"x\""), "the log names the key: \(log.suffix(400))")
        actions.removeAll()
        _ = await rig.call("press_key", ["key": "Enter"])
        #expect(actions.first?.contains("Enter in a form") == true, "\(actions)")
    }

    /// `slowly` would turn a newline into Enter and a tab into Tab: refused (I1).
    @Test(.timeLimit(.minutes(1))) func slowlyRefusesNewlinesAndTabs() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("keys.html")
        for text in ["a\nb", "a\tb"] {
            let typed = await rig.call("type", ["ref": try rig.ref("Search docs"), "text": .string(text), "slowly": .bool(true)])
            #expect(typed.isError && typed.text.contains("press_key"), "\(typed.text)")
        }
    }

    /// A real mouse down on a <select> would open a native menu in front of the owner (I2).
    @Test(.timeLimit(.minutes(1))) func clickingASelectUsesAScript() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("select.html")
        let started = ContinuousClock.now
        let click = await rig.call("click", ["ref": try rig.ref("City")])
        #expect(!click.isError, "\(click.text)")
        #expect(click.text.contains("script"), "\(click.text)")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A dialog that opens during an action ends the call at once with the dialog line (I5).
    @Test(.timeLimit(.minutes(1))) func aDialogDuringAnActionDoesNotHang() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("change-alert.html")
        let started = ContinuousClock.now
        let typed = await rig.call("type", ["ref": try rig.ref("Nick"), "text": "Ann", "submit": .bool(true)])
        #expect(ContinuousClock.now - started < .seconds(8))
        #expect(typed.text.hasPrefix("A dialog is waiting"), "\(typed.text)")
        #expect(typed.text.contains("changed to Ann"))
    }

    /// The file card names the site of the frame that asked for files (C3).
    @Test(.timeLimit(.minutes(1))) func fileUploadCardNamesTheFrameSite() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        var shown: [String] = []
        rig.state.approvals.presenter = { pending in shown.append(pending.request.detail + " " + (pending.request.url ?? "")); return .denied }
        try await rig.open("upload-frame.html")
        let click = await rig.call("click", ["ref": try rig.ref("Invoice PDF")])
        #expect(click.text.hasPrefix("A file chooser is waiting"), "\(click.text)")
        let file = BenchServer.folder.appending(path: "invoice.pdf").path
        _ = await rig.call("file_upload", ["paths": .array([.string(file)])])
        #expect(shown.count == 1 && shown[0].contains("127.0.0.1:\(rig.server.otherPort)"), "\(shown)")
    }

    /// Frames that never introduce themselves cost one short wait, not one per frame (I4).
    @Test(.timeLimit(.minutes(1))) func readPageHasAnOverallDeadline() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        AgentFrames.silentForTests = "silent-leaf"
        defer { AgentFrames.silentForTests = nil }
        try await rig.open("frames-deep.html")
        let started = ContinuousClock.now
        let page = await rig.read()
        #expect(ContinuousClock.now - started < .milliseconds(2500), "took \(ContinuousClock.now - started)")
        #expect(page.contains("\"Mid\""), "\(page.prefix(1500))")
    }

    /// A page can't fill the app with forged introductions (I3).
    @Test(.timeLimit(.minutes(1))) func forgedIntroductionsAreNotKept() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("flood.html")
        try await Task.sleep(for: .seconds(2))
        let tabID = try #require(UUID(uuidString: rig.tab))
        let controller = try #require(rig.state.web.existingController(tabID))
        #expect(controller.agentFrames.waitingIntroductions <= AgentFrames.maxWaitingIntroductions)
        #expect(await rig.read().contains("Code"))
    }

    /// A pop-up whose first load the guard refused doesn't keep the agent's guard (I6).
    @Test(.timeLimit(.minutes(1))) func aRefusedPopupDropsTheAgentsGuard() async throws {
        let rig = try Rig(policy: .ask)
        defer { rig.tearDown() }
        rig.state.approvals.presenter = { pending in pending.request.action == "go to another site" ? .denied : .approved }
        try await rig.open("newtab-other.html")
        await rig.call("click", ["ref": try rig.ref("Open elsewhere")])
        try await Task.sleep(for: .milliseconds(800))
        let popup = try #require(rig.state.space(rig.spaceID)?.tabs.first { $0.id.uuidString.lowercased() != rig.tab })
        let controller = try #require(rig.state.web.existingController(popup.id))
        #expect(controller.agentNavigationGuard == nil)
    }

    /// The owner's own dialog in a tab an agent only reads is the owner's, not held (M5).
    @Test(.timeLimit(.minutes(1))) func aReadDoesNotHoldTheOwnersDialog() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.state.openInNewTab(rig.server.url("auto-dialog.html"), spaceID: rig.spaceID, target: .nowhere)
        let tab = try #require(rig.state.space(rig.spaceID)?.tabs.last)
        rig.tab = tab.id.uuidString.lowercased()
        _ = await rig.call("wait_for", ["seconds": .int(3)])
        #expect(rig.state.web.existingController(tab.id)?.pendingModal == nil)
    }

    /// An off-screen point (a skip link) is not reported as clicked by a real click (M2).
    @Test(.timeLimit(.minutes(1))) func anOffscreenElementIsClickedWithAScript() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("offscreen.html")
        let click = await rig.call("click", ["ref": try rig.ref("Skip to content")])
        #expect(click.text.contains("script"), "\(click.text)")
        #expect(await rig.result().contains("skipped"))
    }

    /// Shutting down answers a dialog held for an agent: a page blocked by it would block its web
    /// process, which WebKit reuses for other pages of the site.
    @Test(.timeLimit(.minutes(1))) func shuttingDownAnswersHeldDialogs() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.open("dialogs.html")
        await rig.call("click", ["ref": try rig.ref("Delete item")])
        let tabID = try #require(UUID(uuidString: rig.tab))
        let controller = try #require(rig.state.web.existingController(tabID))
        #expect(controller.pendingModal != nil)
        TestAppState.shutDown(rig.state)
        #expect(controller.pendingModal == nil)
    }
}
}
