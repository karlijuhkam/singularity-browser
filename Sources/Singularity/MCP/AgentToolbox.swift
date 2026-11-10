import AppKit
import MCP
import SingularityCore
import WebKit

/// The MCP tools: their definitions (names, descriptions, JSON schemas) and implementations.
///
/// Everything here runs on the main thread, because it touches AppState and WKWebView.
/// Anything that came from a web page is wrapped with `UntrustedContent.wrap` before it is returned.
@MainActor
final class AgentToolbox {
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Tool definitions

    func listTools() -> [Tool] {
        guard let state else { return [] }
        var tools = [
            Tool(
                name: AgentToolName.listSpaces,
                description: "List the browser Spaces you may use. Each Space has its own tabs and logins; "
                    + "its tools are named <slug>.<tool>, e.g. work.list_tabs.",
                inputSchema: Self.schema([:]),
                annotations: .init(readOnlyHint: true)
            ),
        ]
        for space in state.spaces where space.agentsEnabled {
            tools += spaceTools(space)
        }
        return tools
    }

    private func spaceTools(_ space: Space) -> [Tool] {
        let name = { (tool: String) in AgentToolName.make(slug: space.slug, tool: tool) }
        let inSpace = "In the “\(space.name)” Space: "
        let tabID: Value = .object(["type": "string", "description": "A tab_id from list_tabs or open."])
        let ref: Value = .object(["type": "integer", "description": "An element ref from read_page or find, e.g. 12 for [12]."])
        let url: Value = .object(["type": "string", "description": "An absolute http(s) URL."])

        // Console and network: only listed while the Space's switch is on (a site needs its own as well).
        let since: Value = .object(["type": "integer", "description": "The cursor from an earlier answer, to get only what is newer."])
        let inspection = !InspectionRules.isSpaceOn(space) ? [] : [
            Tool(name: name("read_console"),
                 description: inSpace + "read the console problems of the page in a web tab: errors, warnings, uncaught exceptions, "
                    + "unhandled promise rejections and resources that failed to load. Only for sites the user switched on in site settings; "
                    + "collected from the page's next load after that.",
                 inputSchema: Self.schema(["tab_id": tabID, "since": since], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: true)),
            Tool(name: name("read_network"),
                 description: inSpace + "read the failed network calls of the page in a web tab: fetch and XMLHttpRequest calls that got "
                    + "status 400 or higher, or no answer, with request payload, response body and headers (logins hidden). "
                    + "Only for sites the user switched on in site settings.",
                 inputSchema: Self.schema(["tab_id": tabID, "since": since], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: true)),
        ]

        return inspection + [
            Tool(name: name("list_tabs"),
                 description: inSpace + "list all tabs (web pages, terminals, artifacts) with their tab_id, title and URL.",
                 inputSchema: Self.schema([:]),
                 annotations: .init(readOnlyHint: true)),
            Tool(name: name("open"),
                 description: inSpace + "open a URL in a new background tab and wait for it to load. Returns the new tab_id.",
                 inputSchema: Self.schema(["url": url], required: ["url"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)),
            Tool(name: name("navigate"),
                 description: inSpace + "load a URL in an existing web tab and wait for it to load.",
                 inputSchema: Self.schema(["tab_id": tabID, "url": url], required: ["tab_id", "url"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)),
            Tool(name: name("close"),
                 description: inSpace + "close a web or artifact tab. Terminal tabs cannot be closed by agents.",
                 inputSchema: Self.schema(["tab_id": tabID], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true)),
            Tool(name: name("read_page"),
                 description: inSpace + "get an outline of the page in a tab: headings, text, and interactive elements "
                    + "marked with refs like [12] button \"Add to cart\". Use the refs with click and type. "
                    + "Long pages are truncated; use find to search them.",
                 inputSchema: Self.schema(["tab_id": tabID], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: true)),
            Tool(name: name("find"),
                 description: inSpace + "search the page in a tab for text or element names; returns matching elements with refs and context.",
                 inputSchema: Self.schema(["tab_id": tabID, "query": .object(["type": "string", "description": "Text to look for (case-insensitive)."])],
                                          required: ["tab_id", "query"]),
                 annotations: .init(readOnlyHint: true)),
            Tool(name: name("click"),
                 description: inSpace + "click the element with the given ref (scrolls it into view first). Waits for any page load it causes.",
                 inputSchema: Self.schema(["tab_id": tabID, "ref": ref], required: ["tab_id", "ref"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("type"),
                 description: inSpace + "replace the contents of a text field (or pick a <select> option by value or label). "
                    + "With submit=true, also presses Enter / submits the form.",
                 inputSchema: Self.schema([
                     "tab_id": tabID, "ref": ref,
                     "text": .object(["type": "string", "description": "The text to put in the field."]),
                     "submit": .object(["type": "boolean", "description": "Press Enter / submit the form afterwards. Default false."]),
                 ], required: ["tab_id", "ref", "text"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("screenshot"),
                 description: inSpace + "take a PNG screenshot of the visible part of the page in a tab.",
                 inputSchema: Self.schema(["tab_id": tabID], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: true)),
        ]
    }

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ])
    }

    // MARK: - Calling tools

    /// Book-keeping for one call: who, what, which tab, and the approval decision (for the log).
    private final class CallRecord {
        let started = Date()
        let client: String
        var spaceID: UUID?
        var tabID: UUID?
        var args: [String: String] = [:]
        var decision = "auto"
        /// When set, the log keeps this instead of the result (console and network content is never logged).
        var logResult: String?

        init(client: String) {
            self.client = client
        }
    }

    /// Runs one tool call: checks the approval policy, marks the tab as busy while it runs,
    /// and appends the call to the Space's agent log.
    func call(_ name: String, arguments: [String: Value], client: String) async -> CallTool.Result {
        let record = CallRecord(client: client)
        let result: CallTool.Result
        do {
            result = try await perform(name, arguments: arguments, record: record)
        } catch let error as ToolError {
            result = .init(content: [.plain(error.message)], isError: true)
        } catch {
            result = .init(content: [.plain(Self.message(for: error))], isError: true)
        }
        if let tabID = record.tabID { state?.endAgentWork(on: tabID) }
        if let spaceID = record.spaceID { log(name, record: record, result: result, spaceID: spaceID) }
        return result
    }

    private func perform(_ name: String, arguments: [String: Value], record: CallRecord) async throws -> CallTool.Result {
        if name == AgentToolName.listSpaces {
            return .init(content: [.plain(try listSpaces())])
        }
        guard let state, let (slug, tool) = AgentToolName.parse(name),
              let space = state.spaces.first(where: { $0.slug == slug }) else {
            throw ToolError("Unknown tool \(name). Call list_spaces to see what is available.")
        }
        guard space.agentsEnabled else {
            throw ToolError("Agents are not allowed in the “\(space.name)” Space.")
        }
        record.spaceID = space.id
        let args = Arguments(arguments)
        record.args = args.forLog()

        switch tool {
        case "list_tabs": return .init(content: [.plain(try listTabs(space))])
        case "open": return .init(content: [.plain(try await open(space, url: args.url("url"), record: record))])
        case "navigate":
            return .init(content: [.plain(try await navigate(space, tabID: args.tabID(), url: args.url("url"), record: record))])
        case "close": return .init(content: [.plain(try await close(space, tabID: args.tabID(), record: record))])
        case "read_page": return .init(content: [.plain(try await readPage(space, tabID: args.tabID(), record: record))])
        case "find":
            return .init(content: [.plain(try await find(space, tabID: args.tabID(), query: args.string("query"), record: record))])
        case "click": return .init(content: [.plain(try await click(space, tabID: args.tabID(), ref: args.int("ref"), record: record))])
        case "type":
            return .init(content: [.plain(try await type(space, tabID: args.tabID(), ref: args.int("ref"),
                                                        text: args.string("text"), submit: args.bool("submit") ?? false,
                                                        record: record))])
        case "screenshot": return .init(content: [try await screenshot(space, tabID: args.tabID(), record: record)])
        case "read_console", "read_network":
            return .init(content: [.plain(try readCapture(space, tabID: args.tabID(), since: try? args.int("since"),
                                                          network: tool == "read_network", record: record))])
        default: throw ToolError("Unknown tool \(name).")
        }
    }

    // MARK: - Tools

    private func listSpaces() throws -> String {
        guard let state else { throw ToolError("Browser is shutting down.") }
        let spaces = state.spaces.filter(\.agentsEnabled).map { space -> [String: Any] in
            ["slug": space.slug, "name": space.name, "tabs": space.tabs.count,
             "policy": space.agentPolicy.rawValue,
             "example_tool": AgentToolName.make(slug: space.slug, tool: "list_tabs")]
        }
        if spaces.isEmpty {
            return "No Spaces are open to agents. The user can allow agents per Space in the Space's settings (right-click the Space → Edit Space…)."
        }
        let note = "policy: readOnly = you may only look; ask = the user confirms each action (open, navigate, close, click, type) in a dialog; allowAll = no confirmation."
        return try Self.json(spaces) + "\n" + note
    }

    private func listTabs(_ space: Space) throws -> String {
        let tabs = space.tabsInSidebarOrder.map { tab -> [String: Any] in
            var entry: [String: Any] = ["tab_id": tab.id.uuidString.lowercased(), "title": tab.displayTitle]
            switch tab.kind {
            case .web(let url): entry["kind"] = "web"; entry["url"] = url.absoluteString
            case .terminal(let directory): entry["kind"] = "terminal"; entry["directory"] = directory
            case .artifact(let path): entry["kind"] = "artifact"; entry["path"] = path
            }
            switch tab.section {
            case .pinned: entry["section"] = "pinned"
            case .open: entry["section"] = "open"
            case .folder(let id): entry["section"] = "folder: " + space.folderPath(id) // "Outer / Inner" for a nested folder
            }
            if tab.id == space.selectedTabID { entry["selected"] = true }
            // On screen right now: the selected tab, or any pane of its split (in the Space being shown).
            if state?.selectedSpaceID == space.id, space.visibleTabIDs.contains(tab.id) { entry["visible"] = true }
            if tab.openedByAgent { entry["opened_by_agent"] = true }
            return entry
        }
        // Titles come from pages, so the whole list counts as page content.
        return UntrustedContent.wrap(try Self.json(tabs), source: "tab list of Space \(space.slug)")
    }

    private func open(_ space: Space, url: URL, record: CallRecord) async throws -> String {
        try await authorize(
            AgentActionContext(kind: .open, targetOrigin: AgentApprovalRules.origin(of: url)), space, record,
            request(record, space, action: "open a page", detail: url.absoluteString))
        guard let state, let (tab, controller) = state.agentOpenTab(url: url, spaceID: space.id) else {
            throw ToolError("Could not open a tab.")
        }
        record.tabID = tab.id
        state.beginAgentWork(on: tab.id)
        await controller.waitUntilLoaded()
        return "Opened tab_id \(tab.id.uuidString.lowercased()).\n" + pageSummary(controller)
    }

    private func navigate(_ space: Space, tabID: UUID, url: URL, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        try await authorize(
            AgentActionContext(kind: .navigate, pageOrigin: AgentApprovalRules.origin(of: controller.webView.url),
                               targetOrigin: AgentApprovalRules.origin(of: url)), space, record,
            request(record, space, action: "go to a page", detail: url.absoluteString, tabTitle: controller.webView.title))
        controller.load(url)
        await controller.waitUntilLoaded()
        return pageSummary(controller)
    }

    private func close(_ space: Space, tabID: UUID, record: CallRecord) async throws -> String {
        guard let state, let tab = space.tab(tabID) else { throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space.") }
        guard !tab.isTerminal else { throw ToolError("Terminal tabs cannot be closed by agents.") }
        let origin = AgentApprovalRules.origin(of: tab.url ?? state.artifacts.host(space.id)?.origin)
        try await authorize(
            AgentActionContext(kind: .close, pageOrigin: origin), space, record,
            request(record, space, action: "close a tab", detail: tab.displayTitle, url: tab.url))
        state.closeTab(tabID, in: space.id, confirmIfBusy: false)
        return "Closed tab_id \(tabID.uuidString.lowercased())."
    }

    private func readPage(_ space: Space, tabID: UUID, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let outline = try await controller.callPageAgent("snapshot(maxChars)", arguments: ["maxChars": 15_000])
        return UntrustedContent.wrap(outline, source: controller.webView.url?.absoluteString ?? "")
    }

    private func find(_ space: Space, tabID: UUID, query: String, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let matches = try await controller.callPageAgent("find(query, 25)", arguments: ["query": query])
        return UntrustedContent.wrap(matches, source: controller.webView.url?.absoluteString ?? "")
    }

    private func click(_ space: Space, tabID: UUID, ref: Int, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        // Look before acting: does this click submit a form or follow a link elsewhere?
        let info = try await controller.inspect(ref: ref)
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        let linkOrigin = AgentApprovalRules.origin(of: info.href.flatMap { URL(string: $0) })
        try await authorize(
            AgentActionContext(kind: .click, pageOrigin: pageOrigin, targetOrigin: linkOrigin, isFormSubmission: info.submits),
            space, record,
            request(record, space, action: info.submits ? "click a button that submits a form" : "click",
                    detail: info.description + (info.href.map { " → \($0)" } ?? ""),
                    url: controller.webView.url, tabTitle: controller.webView.title))

        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin, linkOrigin].compactMap { $0 }), submissionApproved: info.submits)
        defer { controller.agentNavigationGuard = nil }

        let result = try await controller.callPageAgent("click(ref)", arguments: ["ref": ref])
        // If the click started a navigation, wait for it so the next read sees the new page.
        try? await Task.sleep(for: .milliseconds(300))
        await controller.waitUntilLoaded()
        return UntrustedContent.wrap(result, source: controller.webView.url?.absoluteString ?? "") + "\n" + pageSummary(controller)
    }

    private func type(_ space: Space, tabID: UUID, ref: Int, text: String, submit: Bool, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let info = try await controller.inspect(ref: ref)
        // Never show or log what goes into a password field.
        let shownText = info.isPassword ? "•••• (\(text.count) characters, password field)" : text
        record.args["text"] = info.isPassword ? "•••• (\(text.count) characters)" : AgentLogStore.clip(text)
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        try await authorize(
            AgentActionContext(kind: .type, pageOrigin: pageOrigin, isFormSubmission: submit), space, record,
            request(record, space, action: submit ? "type into a field and submit the form" : "type into a field",
                    detail: info.description, url: controller.webView.url, tabTitle: controller.webView.title, text: shownText))

        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin].compactMap { $0 }), submissionApproved: submit)
        defer { controller.agentNavigationGuard = nil }

        let result = try await controller.callPageAgent("type(ref, text, submit)",
                                                        arguments: ["ref": ref, "text": text, "submit": submit])
        try? await Task.sleep(for: .milliseconds(submit ? 300 : 50))
        await controller.waitUntilLoaded()
        return UntrustedContent.wrap(result, source: controller.webView.url?.absoluteString ?? "") + "\n" + pageSummary(controller)
    }

    private func screenshot(_ space: Space, tabID: UUID, record: CallRecord) async throws -> Tool.Content {
        let controller = try await webController(space, tabID, record)
        let image = try await controller.webView.takeSnapshot(configuration: nil)
        guard let png = Self.pngData(image, maxWidth: 1280) else { throw ToolError("Could not encode the screenshot.") }
        return .image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)
    }

    /// `read_console` / `read_network`: what the capture script collected for the tab's page. A
    /// read, so it passes under every policy; the gate is the owner's two switches (Space and
    /// site), checked here as they are now. Refuses whole, never returns part of the data.
    private func readCapture(_ space: Space, tabID: UUID, since: Int?, network: Bool, record: CallRecord) throws -> String {
        guard let state else { throw ToolError("Browser is shutting down.") }
        let current = state.space(space.id) ?? space
        guard let tab = current.tab(tabID) else {
            throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space. Call \(AgentToolName.make(slug: space.slug, tool: "list_tabs")).")
        }
        record.tabID = tabID
        guard case .web = tab.kind else {
            throw ToolError("Console and network can only be read for web tabs, not terminals or artifacts.")
        }
        let controller = state.web.existingController(tabID)
        let url = controller?.webView.url ?? tab.url
        let site = SiteInfo.site(of: url)
        guard InspectionRules.isAllowed(current, site: site), let site else {
            record.logResult = "refused: not switched on"
            throw ToolError(InspectionRules.refusal(space: current, site: site))
        }
        guard let controller else {
            record.logResult = "tab not loaded"
            return "This tab hasn't been loaded since Singularity started, so nothing was collected. Use read_page to load it first."
        }
        let capture = controller.capture(forSite: site)
        let report = network ? capture.networkReport(since: since) : capture.consoleReport(since: since)
        // The log records that a read happened, never what was read.
        record.logResult = "\(report.count) \(network ? "failed requests" : "console entries")"
        return UntrustedContent.wrap(report.text, source: url?.absoluteString ?? site)
    }

    // MARK: - Approvals and logging

    /// Asks the policy (and maybe the user). Throws, with a message for the agent, if not allowed.
    private func authorize(_ context: AgentActionContext, _ space: Space, _ record: CallRecord,
                           _ request: AgentApprovals.Request) async throws {
        guard let state else { throw ToolError("Browser is shutting down.") }
        // Use the Space as it is now (the policy may have changed since the call started).
        let current = state.space(space.id) ?? space
        let outcome = await state.approvals.check(context, space: current, request: request)
        record.decision = outcome.logValue
        if let refusal = outcome.refusal { throw ToolError(refusal) }
    }

    private func request(_ record: CallRecord, _ space: Space, action: String, detail: String,
                         url: URL? = nil, tabTitle: String? = nil, text: String? = nil) -> AgentApprovals.Request {
        var request = AgentApprovals.Request(actor: AgentApprovals.displayName(forClient: record.client), action: action,
                                             detail: detail, url: url?.absoluteString, spaceName: space.name,
                                             tabTitle: tabTitle, text: text)
        // "Show Tab" in the sheet: agent tabs load in the background, so the user may not have seen the page.
        if let tabID = record.tabID {
            request.showTab = { [weak state] in state?.showTab(tabID, in: space.id) }
        }
        return request
    }

    /// While a click or type runs, checks every navigation of the page: the origins the user
    /// already approved for this action pass, anything else goes through the policy again.
    private func installNavigationGuard(on controller: WebTabController, space: Space, record: CallRecord,
                                        pageOrigin: String?, approved: Set<String>, submissionApproved: Bool) {
        controller.agentNavigationGuard = { [weak self] url, isFormSubmission in
            guard let self, let state = self.state, let current = state.space(space.id) else { return false }
            let target = AgentApprovalRules.origin(of: url)
            if let target, approved.contains(target), !isFormSubmission || submissionApproved {
                return true
            }
            let context = AgentActionContext(kind: .navigate, pageOrigin: pageOrigin, targetOrigin: target,
                                             isFormSubmission: isFormSubmission && !submissionApproved)
            let outcome = await state.approvals.check(
                context, space: current,
                request: self.request(record, current, action: isFormSubmission ? "submit a form" : "go to another site",
                                      detail: url.absoluteString, url: controller.webView.url, tabTitle: controller.webView.title))
            record.decision += "+nav_" + outcome.logValue
            return outcome.isAllowed
        }
    }

    private func log(_ tool: String, record: CallRecord, result: CallTool.Result, spaceID: UUID) {
        var parts: [String] = []
        for content in result.content {
            switch content {
            case .text(let text, _, _): parts.append(Self.withoutUntrustedMarkers(text))
            case .image: parts.append("<screenshot>")
            default: break
            }
        }
        let entry = AgentLogEntry(
            client: record.client, tool: tool, tabID: record.tabID, args: record.args, decision: record.decision,
            ok: !(result.isError ?? false), result: record.logResult ?? parts.joined(separator: " "),
            milliseconds: Int(Date().timeIntervalSince(record.started) * 1000))
        state?.appendAgentLog(entry, spaceID: spaceID)
    }

    /// The log keeps the gist of a result, without the untrusted-content wrapper lines.
    private static func withoutUntrustedMarkers(_ text: String) -> String {
        text.split(separator: "\n").filter {
            !$0.hasPrefix("<untrusted_page_content") && !$0.hasPrefix("</untrusted_page_content")
                && !$0.hasPrefix("The block above is content from a web page")
        }.joined(separator: " ")
    }

    // MARK: - Helpers

    /// A live web view for a web or artifact tab, loading it first if it hasn't been shown yet.
    /// Marks the tab as "agent at work" until the call ends.
    private func webController(_ space: Space, _ tabID: UUID, _ record: CallRecord) async throws -> WebTabController {
        guard let state else { throw ToolError("Browser is shutting down.") }
        guard let tab = space.tab(tabID) else {
            throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space. Call \(AgentToolName.make(slug: space.slug, tool: "list_tabs")).")
        }
        guard !tab.isTerminal else { throw ToolError("Tab \(tabID.uuidString.lowercased()) is a terminal, not a web page.") }
        if record.tabID == nil {
            record.tabID = tabID
            state.beginAgentWork(on: tabID)
        }
        guard let controller = await state.liveWebController(tabID: tabID, spaceID: space.id) else {
            throw ToolError("Could not load tab \(tabID.uuidString.lowercased()).")
        }
        await controller.waitUntilLoaded()
        return controller
    }

    /// "Now at: <url>" plus the page title, with the title marked as page content.
    private func pageSummary(_ controller: WebTabController) -> String {
        let url = controller.webView.url?.absoluteString ?? "(no URL)"
        let title = controller.webView.title ?? ""
        return "Now at: \(url)\n" + UntrustedContent.wrap("Page title: \(title)", source: url)
    }

    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// JavaScript exceptions arrive as NSError with the message in userInfo.
    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message.replacingOccurrences(of: "Error: ", with: "")
        }
        return nsError.localizedDescription
    }

    /// PNG, scaled down to at most `maxWidth` pixels wide to keep responses small.
    private static func pngData(_ image: NSImage, maxWidth: Int) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, Double(maxWidth) / Double(cgImage.width))
        let width = Int(Double(cgImage.width) * scale)
        let height = Int(Double(cgImage.height) * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Typed access to tool arguments, with readable errors for the agent.
private struct Arguments {
    let values: [String: Value]
    init(_ values: [String: Value]) { self.values = values }

    func string(_ key: String) throws -> String {
        guard let value = values[key]?.stringValue else { throw AgentToolbox.ToolError("Missing string argument \"\(key)\".") }
        return value
    }

    func int(_ key: String) throws -> Int {
        if let value = values[key]?.intValue { return value }
        // `Int(exactly:)`: a huge number (1e19) must be an error, not a crash.
        if let value = values[key]?.doubleValue, let exact = Int(exactly: value) { return exact }
        if let text = values[key]?.stringValue, let value = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) { return value }
        throw AgentToolbox.ToolError("Missing integer argument \"\(key)\".")
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }

    /// The arguments as short strings for the agent log.
    func forLog() -> [String: String] {
        values.mapValues { value in
            switch value {
            case .string(let text): return AgentLogStore.clip(text)
            case .int(let number): return String(number)
            case .double(let number): return String(number)
            case .bool(let flag): return String(flag)
            default: return AgentLogStore.clip(String(describing: value))
            }
        }
    }

    func tabID() throws -> UUID {
        let text = try string("tab_id")
        guard let id = UUID(uuidString: text) else { throw AgentToolbox.ToolError("\"\(text)\" is not a valid tab_id.") }
        return id
    }

    func url(_ key: String) throws -> URL {
        let text = try string(key)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
            throw AgentToolbox.ToolError("\"\(text)\" is not an absolute http(s) URL.")
        }
        return url
    }
}

private extension Tool.Content {
    /// Plain text content without annotations.
    static func plain(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }
}
