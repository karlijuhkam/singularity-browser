import AppKit
import MCP
import SingularityCore
import WebKit

/// The MCP tools: their definitions (names, descriptions, JSON schemas) and implementations.
///
/// Everything here runs on the main thread, because it touches AppState and WKWebView.
/// Anything that came from a web page is wrapped with `UntrustedContent.wrap` before it is returned.
///
/// Every list and call is for one `AgentCaller`. An outside agent gets the Spaces with agents on,
/// exactly as before. A plugin's own connection gets the Spaces switched on for that plugin, checked
/// again at every call, and never a tab or address on a site the owner switched the plugin off for
/// (checked against where the tab is at the time of the call).
@MainActor
final class AgentToolbox {
    // Internal (not private) for the terminal tools in AgentToolbox+Terminals.swift.
    weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Tool definitions

    /// - Parameter program: for a plugin's connection, the pid of the plugin's program it came from
    ///   (seen when it was accepted). Once that program is no longer the plugin's running one, the
    ///   connection gets no Space (`isOpen`).
    func listTools(for caller: AgentCaller, program: pid_t? = nil) -> [Tool] {
        guard state != nil else { return [] }
        var tools = [
            Tool(
                name: AgentToolName.listSpaces,
                description: "List the browser Spaces you may use. Each Space has its own tabs and logins; "
                    + "its tools are named <slug>.<tool>, e.g. work.list_tabs.",
                inputSchema: Self.schema([:]),
                annotations: .init(readOnlyHint: true)
            ),
        ]
        // A plugin with `terminals`: the overview, and the per-Space terminal tools of each Space
        // whose Terminals switch counts. Outside agents never get these.
        if terminalsPermitted(caller, program: program) { tools.append(terminalsTool()) }
        for space in spaces(for: caller, program: program) {
            tools += spaceTools(space)
            if terminalsOpen(space, for: caller, program: program) { tools += terminalTools(space) }
        }
        return tools
    }

    private func spaceTools(_ space: Space) -> [Tool] {
        let name = { (tool: String) in AgentToolName.make(slug: space.slug, tool: tool) }
        let inSpace = "In the “\(space.name)” Space: "
        let tabID: Value = .object(["type": "string", "description": "A tab_id from list_tabs or open."])
        let ref: Value = .object(["type": ["integer", "string"], "description": "An element ref from read_page or find: 12 for [12], or \"f2:5\" for [f2:5] (inside a frame)."])
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
                 description: inSpace + "click the element with the given ref with a real mouse click (scrolls it into view first). "
                    + "Fails if another element (a banner, a dialog) covers it. Waits for any page load it causes.",
                 inputSchema: Self.schema(["tab_id": tabID, "ref": ref,
                                           "double": .object(["type": "boolean", "description": "Double-click. Default false."])],
                                          required: ["tab_id", "ref"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("type"),
                 description: inSpace + "replace the contents of a text field (or pick a <select> option by value or label). "
                    + "With slowly=true, types one real key press per character (for fields that react to each key, "
                    + "such as masked or autocomplete inputs). With submit=true, presses Enter afterwards.",
                 inputSchema: Self.schema([
                     "tab_id": tabID, "ref": ref,
                     "text": .object(["type": "string", "description": "The text to put in the field."]),
                     "slowly": .object(["type": "boolean", "description": "Type one key at a time. Default false."]),
                     "submit": .object(["type": "boolean", "description": "Press Enter afterwards. Default false."]),
                 ], required: ["tab_id", "ref", "text"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("press_key"),
                 description: inSpace + "press a key in the page, as a real key press to the focused element: a key name "
                    + "(Enter, Escape, Tab, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, F1-F12) "
                    + "or one character, with modifiers like Shift+Tab or Control+k. Click a field first to focus it.",
                 inputSchema: Self.schema([
                     "tab_id": tabID,
                     "key": .object(["type": "string", "description": "The key, e.g. \"Escape\", \"ArrowDown\", \"Control+k\"."]),
                 ], required: ["tab_id", "key"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("hover"),
                 description: inSpace + "point the mouse at an element (to open a menu or tooltip that appears on hover). "
                    + "Simulated with script events; menus made with CSS :hover alone don't open this way.",
                 inputSchema: Self.schema(["tab_id": tabID, "ref": ref], required: ["tab_id", "ref"]),
                 annotations: .init(readOnlyHint: true)),
            Tool(name: name("drag"),
                 description: inSpace + "drag one element onto another (both in the same frame). Simulated with script events.",
                 inputSchema: Self.schema(["tab_id": tabID,
                                           "start_ref": .object(["type": ["integer", "string"], "description": "The element to drag."]),
                                           "end_ref": .object(["type": ["integer", "string"], "description": "Where to drop it."])],
                                          required: ["tab_id", "start_ref", "end_ref"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("wait_for"),
                 description: inSpace + "wait until text appears (text) or disappears (text_gone) on the page, at most 30 seconds, "
                    + "or just wait a number of seconds. Use it when a page is still loading what you need.",
                 inputSchema: Self.schema([
                     "tab_id": tabID,
                     "text": .object(["type": "string", "description": "Text to wait for."]),
                     "text_gone": .object(["type": "string", "description": "Text to wait to disappear."]),
                     "seconds": .object(["type": "number", "description": "How long to wait at most (1-30; default 30, or this many seconds when no text is given)."]),
                 ], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: true)),
            Tool(name: name("handle_dialog"),
                 description: inSpace + "answer the alert, confirm or prompt dialog waiting on a tab (tool answers say when one is). "
                    + "accept=true is OK, false is Cancel; prompt_text is the answer to a prompt.",
                 inputSchema: Self.schema([
                     "tab_id": tabID,
                     "accept": .object(["type": "boolean", "description": "OK (true) or Cancel (false)."]),
                     "prompt_text": .object(["type": "string", "description": "For a prompt dialog: the text to answer with."]),
                 ], required: ["tab_id", "accept"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("file_upload"),
                 description: inSpace + "give files to the file chooser waiting on a tab (click the page's file field first; tool answers "
                    + "say when a chooser is waiting). Absolute paths of files on this Mac; an empty list cancels the chooser. "
                    + "The user always confirms which files go to the page.",
                 inputSchema: Self.schema([
                     "tab_id": tabID,
                     "paths": .object(["type": "array", "items": .object(["type": "string"]),
                                       "description": "Absolute file paths, at most \(UploadFiles.maxFiles)."]),
                 ], required: ["tab_id", "paths"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true)),
            Tool(name: name("screenshot"),
                 description: inSpace + "take a PNG screenshot of the visible part of the page in a tab.",
                 inputSchema: Self.schema(["tab_id": tabID], required: ["tab_id"]),
                 annotations: .init(readOnlyHint: true)),
        ]
    }

    static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ])
    }

    // MARK: - Calling tools

    /// Book-keeping for one call: who, what, which tab, and the approval decision (for the log).
    final class CallRecord {
        let started = Date()
        let caller: AgentCaller
        /// The tool's full name as called (`work.read_page`), for the refusal of a Space closed mid-call.
        let tool: String
        /// For a plugin's connection: the program it came from (see `listTools(for:program:)`).
        let program: pid_t?
        /// For the log and the inbox card: the plugin's title, or the name the agent introduced itself with.
        let client: String
        var spaceID: UUID?
        var tabID: UUID?
        var args: [String: String] = [:]
        var decision = "auto"
        /// When set, the log keeps this instead of the result (console and network content is never logged).
        var logResult: String?

        init(tool: String, client: String, caller: AgentCaller, program: pid_t?) {
            self.tool = tool
            self.caller = caller
            self.program = program
            self.client = caller.clientName(introducedAs: client)
        }
    }

    /// Runs one tool call: checks the approval policy, marks the tab as busy while it runs,
    /// and appends the call to the Space's agent log.
    func call(_ name: String, arguments: [String: Value], client: String, caller: AgentCaller,
              program: pid_t? = nil) async -> CallTool.Result {
        let record = CallRecord(tool: name, client: client, caller: caller, program: program)
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
        // A dialog or file chooser waiting for the agent on this tab: every answer starts with it.
        if let tabID = record.tabID, let spaceID = record.spaceID, let line = modalLine(tabID, spaceID: spaceID, record: record),
           !(result.isError == true && result.content.contains { if case .text(let text, _, _) = $0 { return text.hasPrefix(line) }; return false }) {
            return .init(content: [.plain(line)] + result.content, isError: result.isError)
        }
        return result
    }

    private func perform(_ name: String, arguments: [String: Value], record: CallRecord) async throws -> CallTool.Result {
        if name == AgentToolName.listSpaces {
            return .init(content: [.plain(try listSpaces(record.caller, program: record.program))])
        }
        if name == AgentToolName.terminals {
            return .init(content: [.plain(try listTerminals(record))])
        }
        guard let state, let (slug, tool) = AgentToolName.parse(name),
              let space = state.spaces.first(where: { $0.slug == slug }) else {
            throw Self.unknownTool(name)
        }
        // The terminal tools: only on a plugin's connection, in a Space whose Terminals switch
        // counts now. Anything else (an outside agent, a Space off for terminals) gets exactly the
        // answer for a tool that doesn't exist, before the Space's own checks and before anything
        // is logged, so neither a Space's name nor its agents switch is given away.
        if AgentToolName.terminalTools.contains(tool) {
            guard terminalsOpen(space, for: record.caller, program: record.program) else { throw Self.unknownTool(name) }
            record.spaceID = space.id
            return .init(content: [.plain(try await performTerminalTool(tool, space: space, arguments: arguments, record: record))])
        }
        switch record.caller {
        case .outside:
            guard space.agentsEnabled else {
                throw ToolError("Agents are not allowed in the “\(space.name)” Space.")
            }
        case .plugin:
            // The switch as it is now: a tool name remembered from before is refused once it is off.
            // Exactly as for a Space that doesn't exist, so a guessed slug tells it nothing.
            guard isOpen(space, for: record.caller, program: record.program) else {
                throw Self.unknownTool(name)
            }
        }
        record.spaceID = space.id
        let args = Arguments(arguments)
        record.args = args.forLog()

        switch tool {
        case "list_tabs": return .init(content: [.plain(try listTabs(space, record: record))])
        case "open": return .init(content: [.plain(try await open(space, url: args.url("url"), record: record))])
        case "navigate":
            return .init(content: [.plain(try await navigate(space, tabID: args.tabID(), url: args.url("url"), record: record))])
        case "close": return .init(content: [.plain(try await close(space, tabID: args.tabID(), record: record))])
        case "read_page": return .init(content: [.plain(try await readPage(space, tabID: args.tabID(), record: record))])
        case "find":
            return .init(content: [.plain(try await find(space, tabID: args.tabID(), query: args.string("query"), record: record))])
        case "click":
            return .init(content: [.plain(try await click(space, tabID: args.tabID(), ref: args.ref(), double: args.bool("double") ?? false,
                                                         record: record))])
        case "type":
            return .init(content: [.plain(try await type(space, tabID: args.tabID(), ref: args.ref(),
                                                        text: args.string("text"), slowly: args.bool("slowly") ?? false,
                                                        submit: args.bool("submit") ?? false, record: record))])
        case "hover":
            return .init(content: [.plain(try await hover(space, tabID: args.tabID(), ref: args.ref(), record: record))])
        case "drag":
            return .init(content: [.plain(try await drag(space, tabID: args.tabID(), from: args.ref("start_ref"), to: args.ref("end_ref"),
                                                        record: record))])
        case "wait_for":
            return .init(content: [.plain(try await waitFor(space, tabID: args.tabID(), text: try? args.string("text"),
                                                           gone: try? args.string("text_gone"), seconds: args.number("seconds"),
                                                           record: record))])
        case "handle_dialog":
            return .init(content: [.plain(try await handleDialog(space, tabID: args.tabID(), accept: args.bool("accept") ?? false,
                                                                text: try? args.string("prompt_text"), record: record))])
        case "file_upload":
            return .init(content: [.plain(try await fileUpload(space, tabID: args.tabID(), paths: args.strings("paths"), record: record))])
        case "press_key":
            return .init(content: [.plain(try await pressKey(space, tabID: args.tabID(), key: args.string("key"), record: record))])
        case "screenshot": return .init(content: [try await screenshot(space, tabID: args.tabID(), record: record)])
        case "read_console", "read_network":
            return .init(content: [.plain(try readCapture(space, tabID: args.tabID(), since: try? args.int("since"),
                                                          network: tool == "read_network", record: record))])
        default: throw ToolError("Unknown tool \(name).")
        }
    }

    // MARK: - Tools

    /// The folder whose `app-guide/` holds the guide for apps: the app bundle's resources. A
    /// variable so a test can point it at a folder of its own (a test run has no app bundle).
    nonisolated(unsafe) static var appGuideResources: URL? = Bundle.main.resourceURL

    private func listSpaces(_ caller: AgentCaller, program: pid_t?) throws -> String {
        guard let state else { throw ToolError("Browser is shutting down.") }
        let spaces = spaces(for: caller, program: program).map { space -> [String: Any] in
            var entry: [String: Any] = [
                "slug": space.slug, "name": space.name,
                "tabs": space.tabs.filter { tabIsVisible($0, in: space, to: caller) }.count,
                "policy": space.agentPolicy.rawValue,
                "example_tool": AgentToolName.make(slug: space.slug, tool: "list_tabs")]
            // Where an agent writes an artifact: a new HTML page here gets a tab by itself. Only for
            // outside agents: a plugin's connection has no file tools, and isn't told paths on this Mac.
            if caller == .outside {
                entry["artifacts_folder"] = state.paths.artifactsDirectory(space.slug).path
                // Where the Space's apps keep their data: <app>/<BINDING>.sqlite and worker.log.
                entry["app_data_folder"] = state.paths.appDataDirectory(space.slug).path
            }
            return entry
        }
        if spaces.isEmpty {
            if case .plugin(_, let title) = caller { return AgentCaller.noSpaces(title: title) }
            return "No Spaces are open to agents. The user can allow agents per Space in the Space's settings (right-click the Space → Edit Space…)."
        }
        var note = "policy: readOnly = you may only look; ask = the user confirms each action (open, navigate, close, click, type, press_key, handle_dialog, drag) in a dialog; allowAll = no confirmation. file_upload always asks."
        // Where an agent learns to build an app (an artifact with a Worker and a database).
        if caller == .outside, let guide = ArtifactApps.guideFile(resources: Self.appGuideResources) {
            note += "\napp_guide: \(guide.path) (read it before building an app; a starter is in the template folder next to it)"
        }
        return try Self.json(spaces) + "\n" + note
    }

    private func listTabs(_ space: Space, record: CallRecord) throws -> String {
        // A plugin's own page is not for agents: its tab is left out here and refused everywhere else.
        // For a plugin's connection, so are tabs on a site the owner switched that plugin off for.
        let tabs = space.tabsInSidebarOrder.filter { tabIsVisible($0, in: space, to: record.caller) }.map { tab -> [String: Any] in
            // While its page loads another address, the stored title may still be the old page's.
            let titleIsCurrent = state?.web.existingController(tab.id)?.titleIsCurrent ?? true
            var entry: [String: Any] = ["tab_id": tab.id.uuidString.lowercased(),
                                        "title": titleIsCurrent ? tab.displayTitle : tab.untitledDisplayTitle]
            switch tab.kind {
            case .web(let url): entry["kind"] = "web"; entry["url"] = url.absoluteString
            case .terminal(let directory): entry["kind"] = "terminal"; entry["directory"] = directory
            case .artifact(let path): entry["kind"] = "artifact"; entry["path"] = path
            case .plugin, .note, .home: break // filtered out above
            }
            switch tab.section {
            case .pinned: entry["section"] = "pinned"
            case .open: entry["section"] = "open"
            case .folder(let id): entry["section"] = "folder: " + space.folderPath(id) // "Outer / Inner" for a nested folder
            }
            // Selected in some window (in a window that shows this Space), or the Space's last
            // selected tab when no window shows it, as with one window.
            if tab.id == space.selectedTabID || state?.isTabSelectedInAnyWindow(tab.id, spaceID: space.id) == true {
                entry["selected"] = true
            }
            // On screen right now in any browser window: a selected tab, or any pane of its split.
            if state?.isTabShownInAnyWindow(tab.id) == true { entry["visible"] = true }
            // A plugin's connection learns only that a terminal is there: its title, folder and
            // project carry folders and commands (a plugin with `terminals` gets them from the
            // `terminals` tool, under its own switch; `front` withholds them too).
            if tab.isTerminal, record.caller.pluginID != nil {
                return entry.filter { ["tab_id", "kind", "section", "selected", "visible"].contains($0.key) }
            }
            if let project = space.projectName(of: tab) { entry["project"] = project } // terminals only
            if tab.openedByAgent { entry["opened_by_agent"] = true }
            return entry
        }
        // Titles come from pages, so the whole list counts as page content.
        return UntrustedContent.wrap(try Self.json(tabs), source: "tab list of Space \(space.slug)")
    }

    private func open(_ space: Space, url: URL, record: CallRecord) async throws -> String {
        try refuseAddress(url, space, record) // before anything is asked
        try await authorize(
            AgentActionContext(kind: .open, targetOrigin: AgentApprovalRules.origin(of: url)), space, record,
            request(record, space, action: "open a page", detail: url.absoluteString))
        guard let state, let (tab, controller) = state.agentOpenTab(url: url, spaceID: space.id) else {
            throw ToolError("Could not open a tab.")
        }
        record.tabID = tab.id
        state.beginAgentWork(on: tab.id)
        await controller.waitUntilLoaded()
        try refuseIfSpaceClosed(space, record) // switched off while the page loaded
        return "Opened tab_id \(tab.id.uuidString.lowercased()).\n" + pageSummary(controller, space, record)
    }

    private func navigate(_ space: Space, tabID: UUID, url: URL, record: CallRecord) async throws -> String {
        try refuseAddress(url, space, record) // before the tab is loaded or anything is asked
        let controller = try await webController(space, tabID, record)
        try await authorize(
            AgentActionContext(kind: .navigate, pageOrigin: AgentApprovalRules.origin(of: controller.webView.url),
                               targetOrigin: AgentApprovalRules.origin(of: url)), space, record,
            request(record, space, action: "go to a page", detail: url.absoluteString, tabTitle: controller.webView.title))
        controller.load(url)
        await controller.waitUntilLoaded()
        try refuseIfSpaceClosed(space, record)
        return pageSummary(controller, space, record)
    }

    private func close(_ space: Space, tabID: UUID, record: CallRecord) async throws -> String {
        guard let state, let tab = space.tab(tabID) else { throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space.") }
        guard !tab.isTerminal else { throw ToolError("Terminal tabs cannot be closed by agents.") }
        guard !tab.isHiddenFromAgents else { throw Self.notAWebPage(tabID) }
        try refuseOffSite(tab, space, record)
        let origin = AgentApprovalRules.origin(of: tab.url ?? state.artifacts.host(space.id)?.origin)
        try await authorize(
            AgentActionContext(kind: .close, pageOrigin: origin), space, record,
            request(record, space, action: "close a tab", detail: tab.displayTitle, url: tab.url))
        // Where the tab is after the owner was asked (`authorize` only re-checks tabs it marked).
        if let now = state.space(space.id)?.tab(tabID) { try refuseOffSite(now, space, record) }
        state.closeTab(tabID, in: space.id, confirmIfBusy: false)
        return "Closed tab_id \(tabID.uuidString.lowercased())."
    }

    private func readPage(_ space: Space, tabID: UUID, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let outline = try await controller.agentFrames.snapshot(controller, maxChars: 15_000, allows: frameAllowed(space, record))
        try refuseIfNowOff(controller, space, record) // the page may have moved while it was read
        return UntrustedContent.wrap(outline, source: controller.webView.url?.absoluteString ?? "")
    }

    private func find(_ space: Space, tabID: UUID, query: String, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let matches = try await controller.agentFrames.find(controller, query: query, allows: frameAllowed(space, record))
        try refuseIfNowOff(controller, space, record)
        return UntrustedContent.wrap(matches, source: controller.webView.url?.absoluteString ?? "")
    }

    private func click(_ space: Space, tabID: UUID, ref: AgentRef, double: Bool, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let target = try refTarget(ref, controller, space, record)
        // Look before acting: does this click submit a form or follow a link elsewhere?
        let info = try await target.inspect(controller)
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        let linkOrigin = AgentApprovalRules.origin(of: info.href.flatMap { URL(string: $0) })
        try await authorize(
            AgentActionContext(kind: .click, pageOrigin: pageOrigin, targetOrigin: linkOrigin, isFormSubmission: info.submits),
            space, record,
            request(record, space, action: info.submits ? "click a button that submits a form" : "click",
                    detail: info.description + (info.href.map { " → \($0)" } ?? ""),
                    url: controller.webView.url, tabTitle: controller.webView.title))

        let cancellation = ApprovalCancellation()
        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin, linkOrigin].compactMap { $0 }), submissionApproved: info.submits,
                               cancellation: cancellation)
        defer { controller.agentNavigationGuard = nil }

        let tabsBefore = Set(state?.space(space.id)?.tabs.map(\.id) ?? [])
        return try await whileNotCancelled(cancellation) {
            // Stopped after it was allowed but before it acts: it doesn't act.
            try self.refuseIfCancelled(cancellation, record)
            controller.agentActions += 1
            defer { controller.agentActions -= 1 }
            let result: String
            switch try await self.clickTarget(target, controller) {
            case .point(let point):
                AgentInput.click(controller.webView, at: point, double: double)
                result = "Clicked \(info.description)."
            case .script(let why):
                // No real click there (hidden, off screen, or a control whose real click opens a
                // native menu in front of the user): the old script click.
                let clicked = try await controller.callPageAgentUnlessModal("click(ref)", arguments: ["ref": target.local],
                                                                             frame: target.frame, key: target.key)
                result = target.shown(clicked ?? "Clicked \(info.description).") + " (\(why); it was clicked with a script.)"
            }
            // If the click started a navigation, wait for it so the next read sees the new page.
            try? await Task.sleep(for: .milliseconds(300))
            await controller.waitUntilLoaded()
            try self.refuseIfSpaceClosed(space, record)
            return UntrustedContent.wrap(result, source: self.shownAddress(controller, space, record)) + "\n"
                + self.pageSummary(controller, space, record) + self.newTabsNote(space, before: tabsBefore, record: record)
        }
    }

    /// "Opened a new tab tab_id …" for each tab an action opened (a link with target=_blank, a
    /// `window.open`): they open in the background, so the agent must be told where they are.
    private func newTabsNote(_ space: Space, before: Set<UUID>, record: CallRecord) -> String {
        guard let tabs = state?.space(space.id)?.tabs else { return "" }
        let new = tabs.filter { !before.contains($0.id) && tabIsVisible($0, in: space, to: record.caller) }
        return new.map { "\nOpened a new tab tab_id \($0.id.uuidString.lowercased()) (\($0.url?.absoluteString ?? "loading"))." }.joined()
    }

    private func type(_ space: Space, tabID: UUID, ref: AgentRef, text: String, slowly: Bool, submit: Bool,
                      record: CallRecord) async throws -> String {
        if slowly, text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            throw ToolError("With slowly, newlines and tabs are not typed (they would press Enter or Tab). "
                + "Type each line separately and use press_key for Enter or Tab, or submit=true.")
        }
        let controller = try await webController(space, tabID, record)
        let target = try refTarget(ref, controller, space, record)
        let info = try await target.inspect(controller)
        // Never show or log what goes into a password field.
        let shownText = info.isPassword ? "•••• (\(text.count) characters, password field)" : text
        record.args["text"] = info.isPassword ? "•••• (\(text.count) characters)" : AgentLogStore.clip(text)
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        try await authorize(
            AgentActionContext(kind: .type, pageOrigin: pageOrigin, isFormSubmission: submit), space, record,
            request(record, space, action: submit ? "type into a field and submit the form" : "type into a field",
                    detail: info.description, url: controller.webView.url, tabTitle: controller.webView.title, text: shownText))

        let cancellation = ApprovalCancellation()
        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin].compactMap { $0 }), submissionApproved: submit,
                               cancellation: cancellation)
        defer { controller.agentNavigationGuard = nil }

        return try await whileNotCancelled(cancellation) {
            try self.refuseIfCancelled(cancellation, record)
            controller.agentActions += 1
            defer { controller.agentActions -= 1 }
            var result: String
            if slowly {
                // Real key presses: focus the field with a real click, select what is in it, type.
                if case .point(let point) = try await self.clickTarget(target, controller) {
                    AgentInput.click(controller.webView, at: point, double: false)
                }
                _ = try await controller.callPageAgent("focusAndSelect(ref)", arguments: ["ref": target.local],
                                                       frame: target.frame, key: target.key)
                await AgentInput.typeSlowly(text, in: controller.webView)
                result = "Typed into \(info.description) one key at a time."
            } else {
                let typed = try await controller.callPageAgentUnlessModal("type(ref, text, submit)",
                                                                           arguments: ["ref": target.local, "text": text, "submit": false],
                                                                           frame: target.frame, key: target.key)
                result = target.shown(typed ?? "Typed into \(info.description).")
            }
            if submit {
                // A real Enter in the field (it needs the keyboard focus a real click gives).
                if !slowly, case .point(let point) = try await self.clickTarget(target, controller) {
                    AgentInput.click(controller.webView, at: point, double: false)
                }
                AgentInput.press(try KeyChord.parse("Enter"), in: controller.webView)
                result = String(result.dropLast(result.hasSuffix(".") ? 1 : 0)) + " and pressed Enter."
            }
            try? await Task.sleep(for: .milliseconds(submit ? 300 : 50))
            await controller.waitUntilLoaded()
            try self.refuseIfSpaceClosed(space, record)
            return UntrustedContent.wrap(result, source: self.shownAddress(controller, space, record)) + "\n"
                + self.pageSummary(controller, space, record)
        }
    }

    /// "A dialog is waiting on this tab: …" for a tab with a dialog or chooser held for agents.
    ///
    /// Never for a plugin's connection that may not know of it now: its Space switched off (the
    /// answer is then the plain "Unknown tool", which must carry nothing from the page), the tab on a
    /// site switched off for it, or the dialog from a frame of such a site.
    private func modalLine(_ tabID: UUID, spaceID: UUID, record: CallRecord) -> String? {
        guard let state, let space = state.space(spaceID), let modal = state.web.existingController(tabID)?.pendingModal else { return nil }
        if case .plugin = record.caller {
            guard isOpen(space, for: record.caller, program: record.program),
                  let tab = space.tab(tabID), !tabIsOff(tab, space, record.caller),
                  !siteIsOff(modal.origin, space, record.caller) else { return nil }
        }
        let tool = { AgentToolName.make(slug: space.slug, tool: $0) }
        let source = state.web.existingController(tabID)?.webView.url?.absoluteString ?? ""
        func dialog(_ kind: String, _ message: String) -> String {
            "A dialog is waiting on this tab: \(kind). Answer it with \(tool("handle_dialog")) before anything else on this tab.\n"
                + UntrustedContent.wrap("Dialog message: \(message)", source: source)
        }
        switch modal.kind {
        case .alert(let message): return dialog("alert", message)
        case .confirm(let message): return dialog("confirm", message)
        case .prompt(let message, _): return dialog("prompt", message)
        case .fileChooser(let multiple, _):
            return "A file chooser is waiting on this tab (\(multiple ? "several files" : "one file")). "
                + "Answer it with \(tool("file_upload")) (an empty list cancels it) before anything else on this tab."
        }
    }

    private func handleDialog(_ space: Space, tabID: UUID, accept: Bool, text: String?, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record, allowModal: true)
        guard let modal = controller.pendingModal, modal.kind.isDialog else { throw ToolError("No dialog is waiting on this tab.") }
        try refuseModalSite(modal, space, record)
        let message: String
        switch modal.kind {
        case .alert(let m), .confirm(let m), .prompt(let m, _): message = m
        case .fileChooser: message = ""
        }
        if let text { record.args["prompt_text"] = AgentLogStore.clip(text) }
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        try await authorize(
            AgentActionContext(kind: .dialog, pageOrigin: pageOrigin), space, record,
            request(record, space, action: accept ? "answer OK to a page's dialog" : "answer Cancel to a page's dialog",
                    detail: message, url: modal.origin ?? controller.webView.url, tabTitle: controller.webView.title, text: text))
        guard controller.pendingModal === modal else { throw ToolError("The dialog is gone (the page moved on or it timed out).") }

        let cancellation = ApprovalCancellation()
        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin].compactMap { $0 }), submissionApproved: false, cancellation: cancellation)
        defer { controller.agentNavigationGuard = nil }
        return try await whileNotCancelled(cancellation) {
            try self.refuseIfCancelled(cancellation, record)
            controller.agentActions += 1
            defer { controller.agentActions -= 1 }
            modal.answer(accept ? .accept(text: text) : .dismiss)
            try? await Task.sleep(for: .milliseconds(300))
            await controller.waitUntilLoaded()
            try self.refuseIfSpaceClosed(space, record)
            return (accept ? "Answered OK to the dialog.\n" : "Answered Cancel to the dialog.\n") + self.pageSummary(controller, space, record)
        }
    }

    private func fileUpload(_ space: Space, tabID: UUID, paths: [String], record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record, allowModal: true)
        guard let modal = controller.pendingModal, case .fileChooser(let multiple, _) = modal.kind else {
            throw ToolError("No file chooser is waiting on this tab. Click the page's file field first.")
        }
        try refuseModalSite(modal, space, record)
        let files: [URL]
        do { files = try UploadFiles.check(paths, multiple: multiple) } catch let refusal as UploadFiles.Refusal {
            throw ToolError(refusal.description)
        }
        record.args["paths"] = AgentLogStore.clip(files.map(\.path).joined(separator: ", "))
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        try await authorize(
            AgentActionContext(kind: .fileUpload, pageOrigin: pageOrigin), space, record,
            request(record, space, action: files.isEmpty ? "cancel a page's file chooser" : "give files from this Mac to a page",
                    detail: files.isEmpty ? "No files." : files.map(\.path).joined(separator: "\n"),
                    url: modal.origin ?? controller.webView.url, tabTitle: controller.webView.title))
        guard controller.pendingModal === modal else { throw ToolError("The file chooser is gone (the page moved on or it timed out).") }
        // A page may submit its form as soon as the files arrive: checked like a click's navigations.
        let cancellation = ApprovalCancellation()
        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin].compactMap { $0 }), submissionApproved: false, cancellation: cancellation)
        defer { controller.agentNavigationGuard = nil }
        return try await whileNotCancelled(cancellation) {
            try self.refuseIfCancelled(cancellation, record)
            controller.agentActions += 1
            defer { controller.agentActions -= 1 }
            modal.answer(files.isEmpty ? .dismiss : .files(files))
            try? await Task.sleep(for: .milliseconds(200))
            await controller.waitUntilLoaded()
            try self.refuseIfSpaceClosed(space, record)
            let what = files.isEmpty ? "Cancelled the file chooser." : "Gave \(files.count == 1 ? "1 file" : "\(files.count) files") to the page."
            return what + "\n" + self.pageSummary(controller, space, record)
        }
    }

    private func hover(_ space: Space, tabID: UUID, ref: AgentRef, record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let target = try refTarget(ref, controller, space, record)
        controller.agentActions += 1
        defer { controller.agentActions -= 1 }
        let result = try await controller.callPageAgentUnlessModal("hover(ref)", arguments: ["ref": target.local],
                                                                   frame: target.frame, key: target.key)
        try? await Task.sleep(for: .milliseconds(150))
        try refuseIfNowOff(controller, space, record)
        return UntrustedContent.wrap(target.shown(result ?? "Pointed at it") + " (simulated with script events).",
                                     source: shownAddress(controller, space, record))
    }

    private func drag(_ space: Space, tabID: UUID, from: AgentRef, to: AgentRef, record: CallRecord) async throws -> String {
        guard from.frame == to.frame else { throw ToolError("Both elements must be in the same frame.") }
        let controller = try await webController(space, tabID, record)
        let target = try refTarget(from, controller, space, record)
        let info = try await target.inspect(controller)
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        try await authorize(
            AgentActionContext(kind: .drag, pageOrigin: pageOrigin), space, record,
            request(record, space, action: "drag an element", detail: info.description,
                    url: controller.webView.url, tabTitle: controller.webView.title))
        let cancellation = ApprovalCancellation()
        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin].compactMap { $0 }), submissionApproved: false, cancellation: cancellation)
        defer { controller.agentNavigationGuard = nil }
        return try await whileNotCancelled(cancellation) {
            try self.refuseIfCancelled(cancellation, record)
            controller.agentActions += 1
            defer { controller.agentActions -= 1 }
            let result = try await controller.callPageAgentUnlessModal("drag(from, to)", arguments: ["from": target.local, "to": to.local],
                                                                       frame: target.frame, key: target.key)
            try? await Task.sleep(for: .milliseconds(200))
            await controller.waitUntilLoaded()
            try self.refuseIfSpaceClosed(space, record)
            return UntrustedContent.wrap(target.shown(result ?? "Dragged it") + " (simulated with script events).",
                                         source: self.shownAddress(controller, space, record)) + "\n" + self.pageSummary(controller, space, record)
        }
    }

    /// Polls the page (and its frames) until `text` is there or `gone` is not, or the time is up.
    private func waitFor(_ space: Space, tabID: UUID, text: String?, gone: String?, seconds: Double?,
                         record: CallRecord) async throws -> String {
        let controller = try await webController(space, tabID, record)
        let limit = min(max(seconds ?? 30, 0.25), 30)
        let deadline = ContinuousClock.now + .milliseconds(Int(limit * 1000))
        guard text != nil || gone != nil else {
            try? await Task.sleep(until: deadline)
            try refuseIfNowOff(controller, space, record)
            return "Waited \(Self.secondsText(limit))."
        }
        let allows = frameAllowed(space, record)
        func present(_ needle: String) async -> Bool? {
            guard controller.pendingModal == nil,
                  let found = try? await controller.agentFrames.find(controller, query: needle, allows: allows) else { return nil }
            return !found.hasPrefix("No matches")
        }
        while true {
            try Task.checkCancellation()
            if controller.pendingModal != nil { throw ToolError("Stopped waiting.") }
            var done = true
            if let text, await present(text) != true { done = false }
            if done, let gone, await present(gone) != false { done = false }
            try refuseIfNowOff(controller, space, record)
            if done {
                return text.map { "Found “\($0)” on the page." } ?? "“\(gone ?? "")” is gone from the page."
            }
            guard ContinuousClock.now < deadline else {
                let what = text.map { "“\($0)” is still not on the page" } ?? "“\(gone ?? "")” is still on the page"
                throw ToolError("\(what) after \(Self.secondsText(limit)).")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func secondsText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) seconds" : String(format: "%.1f seconds", value)
    }

    /// A plugin never sees or answers a dialog or chooser from a frame of a site switched off for it.
    private func refuseModalSite(_ modal: PendingModal, _ space: Space, _ record: CallRecord) throws {
        guard case .plugin(_, let title) = record.caller, siteIsOff(modal.origin, space, record.caller) else { return }
        throw ToolError(AgentCaller.siteOff(title: title))
    }

    private struct FocusInfo: Decodable {
        let description: String
        let inForm: Bool
        let isPassword: Bool
        let frameToken: String?
    }

    /// The focused element, looked for inside frames (focus in a frame shows as the iframe in its
    /// parent). A plugin is refused when focus is in a frame of a site switched off for it. A frame
    /// that doesn't answer counts as a password field in a form: masked, and Enter asks.
    private func focusedElement(_ controller: WebTabController, _ space: Space, _ record: CallRecord) async throws -> FocusInfo {
        // The introductions answer the focusInfo calls themselves: the whole search is one read.
        try await controller.agentFrames.reading { try await focusedElementInFrames(controller, space, record) }
    }

    private func focusedElementInFrames(_ controller: WebTabController, _ space: Space, _ record: CallRecord) async throws -> FocusInfo {
        var info = try JSONDecoder().decode(FocusInfo.self, from: Data(try await controller.callPageAgent("focusInfo()", arguments: [:]).utf8))
        var parent: AgentFrames.Entry?
        var depth = 0
        while let token = info.frameToken {
            depth += 1
            let found = await controller.agentFrames.resolve([token], parent: parent?.number)
            guard depth <= AgentFrames.maxDepth + 1, let entry = found[token] else {
                // A plugin can't be shown to stay off switched-off sites here: refused.
                if case .plugin = record.caller {
                    throw ToolError("The keyboard focus is in a frame that can't be checked. Click a field first, then press the key.")
                }
                return FocusInfo(description: info.description, inForm: true, isPassword: true, frameToken: nil)
            }
            if case .plugin(_, let title) = record.caller, siteIsOff(AgentFrames.origin(of: entry.frame), space, record.caller) {
                throw ToolError(AgentCaller.siteOff(title: title))
            }
            let json = try await controller.callPageAgent("focusInfo()", arguments: [:], frame: entry.frame, key: entry.key)
            let inner = try JSONDecoder().decode(FocusInfo.self, from: Data(json.utf8))
            info = FocusInfo(description: AgentFrames.prefixRefs(inner.description, frame: entry.number), inForm: inner.inForm,
                             isPassword: inner.isPassword, frameToken: inner.frameToken)
            parent = entry
        }
        return info
    }

    private func pressKey(_ space: Space, tabID: UUID, key: String, record: CallRecord) async throws -> String {
        let chord: KeyChord
        do { chord = try KeyChord.parse(key) } catch let error as KeyChord.ParseError { throw ToolError(error.description) }
        guard !chord.isClipboard else {
            throw ToolError("\(key) would use the clipboard, which agents can't reach. Use type to put text in a field.")
        }
        let controller = try await webController(space, tabID, record)
        let focus = try await focusedElement(controller, space, record)
        // Never show or log which key goes into a password field.
        let shownKey = focus.isPassword && chord.characters.count == 1 && !chord.control && !chord.command ? "a key" : key
        record.args["key"] = shownKey
        let submits = chord.key == "Enter" && focus.inForm
        let pageOrigin = AgentApprovalRules.origin(of: controller.webView.url)
        try await authorize(
            AgentActionContext(kind: .pressKey, pageOrigin: pageOrigin, isFormSubmission: submits), space, record,
            request(record, space, action: submits ? "press Enter in a form (it may submit it)" : "press \(shownKey)",
                    detail: focus.description, url: controller.webView.url, tabTitle: controller.webView.title))

        let cancellation = ApprovalCancellation()
        installNavigationGuard(on: controller, space: space, record: record, pageOrigin: pageOrigin,
                               approved: Set([pageOrigin].compactMap { $0 }), submissionApproved: submits,
                               cancellation: cancellation)
        defer { controller.agentNavigationGuard = nil }

        let tabsBefore = Set(state?.space(space.id)?.tabs.map(\.id) ?? [])
        return try await whileNotCancelled(cancellation) {
            try self.refuseIfCancelled(cancellation, record)
            controller.agentActions += 1
            defer { controller.agentActions -= 1 }
            AgentInput.press(chord, in: controller.webView)
            try? await Task.sleep(for: .milliseconds(chord.key == "Enter" ? 300 : 100))
            await controller.waitUntilLoaded()
            try self.refuseIfSpaceClosed(space, record)
            return "Pressed \(shownKey).\n" + self.pageSummary(controller, space, record)
                + self.newTabsNote(space, before: tabsBefore, record: record)
        }
    }

    private struct PointInfo: Decodable {
        let visible: Bool
        let x: Double?
        let y: Double?
        let covered: String?
        let reason: String?
    }

    enum ClickTarget {
        /// A real click there (main frame CSS px).
        case point(CGPoint)
        /// A script click, and why (said in the answer).
        case script(String)
    }

    /// Where to click an element with a real click: its centre in the main frame's CSS px, with
    /// each frame's offset added; or a script click when it has no box, is off screen, or is a
    /// control whose real click opens a native menu or picker. Throws when something else covers
    /// it there (a banner, a dialog), as Playwright does.
    func clickTarget(_ target: RefTarget, _ controller: WebTabController) async throws -> ClickTarget {
        let json = try await controller.callPageAgent("point(ref)", arguments: ["ref": target.local], frame: target.frame, key: target.key)
        let info = try JSONDecoder().decode(PointInfo.self, from: Data(json.utf8))
        guard info.visible, let x = info.x, let y = info.y else {
            switch info.reason {
            case "menu": return .script("a real click would open a menu in front of the user")
            case "offscreen": return .script("The element is not on screen")
            default: return .script("The element is not visible")
            }
        }
        if let covered = info.covered { throw Self.covered(target.shown(covered)) }
        var point = CGPoint(x: x, y: y)
        var number = target.number
        while let current = number, let entry = controller.agentFrames.entry(current) {
            let parent = entry.parent.flatMap { controller.agentFrames.entry($0) }
            let json = try await controller.callPageAgent("frameOffset(token, x, y)",
                                                          arguments: ["token": entry.token, "x": point.x, "y": point.y],
                                                          frame: parent?.frame, key: parent?.key)
            let offset = try JSONDecoder().decode(PointInfo.self, from: Data(json.utf8))
            if let covered = offset.covered {
                throw Self.covered(parent.map { AgentFrames.prefixRefs(covered, frame: $0.number) } ?? covered)
            }
            point = CGPoint(x: offset.x ?? point.x, y: offset.y ?? point.y)
            number = entry.parent
        }
        return .point(point)
    }

    private static func covered(_ what: String) -> ToolError {
        ToolError("The element is covered by \(what), which would get the click. Close or answer that first, then click again.")
    }

    /// Runs a click's or type's action and wait. Cancelling the call (Stop, or the connection
    /// closing) cancels `cancellation`: the navigation guard then withdraws what it is waiting for
    /// and refuses every further navigation, so a stopped call never navigates on a late Allow.
    private func whileNotCancelled<T>(_ cancellation: ApprovalCancellation,
                                      _ work: () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await work()
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
    }

    private func screenshot(_ space: Space, tabID: UUID, record: CallRecord) async throws -> Tool.Content {
        let controller = try await webController(space, tabID, record)
        let image = try await controller.webView.takeSnapshot(configuration: nil)
        try refuseIfNowOff(controller, space, record)
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
        guard !tab.isHiddenFromAgents else { throw Self.notAWebPage(tabID) }
        guard case .web = tab.kind else {
            throw ToolError("Console and network can only be read for web tabs, not terminals or artifacts.")
        }
        try refuseOffSite(tab, current, record)
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
        // A plugin's switches may have changed while the owner was asked: they count as they are now.
        if case .plugin(_, let title) = record.caller {
            let now = state.space(space.id)
            guard let now, isOpen(now, for: record.caller, program: record.program) else {
                throw ToolError(AgentCaller.spaceOff(title: title, space: space.name))
            }
            if let tabID = record.tabID, let tab = now.tab(tabID) { try refuseOffSite(tab, now, record) }
        }
    }

    private func request(_ record: CallRecord, _ space: Space, action: String, detail: String,
                         url: URL? = nil, tabTitle: String? = nil, text: String? = nil) -> AgentApprovals.Request {
        // A plugin's card names it by its title, exactly; an outside agent by its client name, tidied.
        let actor = record.caller.pluginID != nil ? record.client : AgentApprovals.displayName(forClient: record.client)
        var request = AgentApprovals.Request(actor: actor, action: action,
                                             detail: detail, url: url?.absoluteString, spaceName: space.name,
                                             tabTitle: tabTitle, text: text)
        request.pluginID = record.caller.pluginID
        // "Show Tab" on the inbox entry: agent tabs load in the background, so the user may not
        // have seen the page. The entry carries the tab: closing it denies the request.
        if let tabID = record.tabID {
            request.showTab = { [weak state] in state?.showTab(tabID, in: space.id) }
            request.tabID = tabID
        }
        return request
    }

    /// While a click or type runs, checks every navigation of the page: the origins the user
    /// already approved for this action pass, anything else goes through the policy again.
    private func installNavigationGuard(on controller: WebTabController, space: Space, record: CallRecord,
                                        pageOrigin: String?, approved: Set<String>, submissionApproved: Bool,
                                        cancellation: ApprovalCancellation) {
        controller.agentNavigationGuard = { [weak self] url, isFormSubmission in
            guard let self, let state = self.state, let current = state.space(space.id) else { return false }
            // The call was stopped: nothing it started may move the page any more.
            if cancellation.isCancelled {
                record.decision += "+nav_cancelled"
                return false
            }
            // A plugin's Space switched off while its click or type ran: nothing it started moves the page.
            if !self.isOpen(current, for: record.caller, program: record.program) {
                record.decision += "+nav_space_off"
                return false
            }
            // A plugin's action never carries a tab onto a site the owner switched it off for.
            if self.siteIsOff(url, current, record.caller) {
                record.decision += "+nav_site_off"
                return false
            }
            let target = AgentApprovalRules.origin(of: url)
            if let target, approved.contains(target), !isFormSubmission || submissionApproved {
                return true
            }
            let context = AgentActionContext(kind: .navigate, pageOrigin: pageOrigin, targetOrigin: target,
                                             isFormSubmission: isFormSubmission && !submissionApproved)
            var request = self.request(record, current, action: isFormSubmission ? "submit a form" : "go to another site",
                                       detail: url.absoluteString, url: controller.webView.url, tabTitle: controller.webView.title)
            request.cancellation = cancellation
            let outcome = await state.approvals.check(context, space: current, request: request)
            record.decision += "+nav_" + outcome.logValue
            // And as it is after the policy answered (the switch may have gone off meanwhile).
            if outcome.isAllowed, !(state.space(space.id).map { self.isOpen($0, for: record.caller, program: record.program) } ?? false) {
                record.decision += "+nav_space_off"
                return false
            }
            return outcome.isAllowed
        }
    }

    func log(_ tool: String, record: CallRecord, result: CallTool.Result, spaceID: UUID) {
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
    private func webController(_ space: Space, _ tabID: UUID, _ record: CallRecord, allowModal: Bool = false) async throws -> WebTabController {
        guard let state else { throw ToolError("Browser is shutting down.") }
        guard let tab = space.tab(tabID) else {
            throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space. Call \(AgentToolName.make(slug: space.slug, tool: "list_tabs")).")
        }
        guard !tab.isTerminal else { throw ToolError("Tab \(tabID.uuidString.lowercased()) is a terminal, not a web page.") }
        guard !tab.isHiddenFromAgents else { throw Self.notAWebPage(tabID) }
        // Before the tab is loaded or marked: where it is now (live page and stored address).
        try refuseOffSite(tab, space, record)
        if record.tabID == nil {
            record.tabID = tabID
            state.beginAgentWork(on: tabID)
        }
        guard let controller = await state.liveWebController(tabID: tabID, spaceID: space.id) else {
            throw ToolError("Could not load tab \(tabID.uuidString.lowercased()).")
        }
        // A dialog or file chooser waits for the agent: only its answer may touch the page (while a
        // dialog waits, the page's scripts are blocked). The answer starts with what waits (`call`).
        if controller.pendingModal != nil, !allowModal {
            throw ToolError("This tab can't be used until that is answered.")
        }
        await controller.waitUntilLoaded()
        // And again once loaded: the page may have ended up elsewhere (a redirect).
        try refuseIfNowOff(controller, space, record)
        return controller
    }

    // MARK: - Frames

    /// Where a ref points: the main frame, or a frame of this tab's page that was introduced
    /// (`AgentFrames`). Results from a frame show its refs as `[f<N>:<ref>]`.
    struct RefTarget {
        let frame: WKFrameInfo?
        let key: String?
        let number: Int?
        let local: Int

        func inspect(_ controller: WebTabController) async throws -> WebTabController.ElementInfo {
            let info = try await controller.inspect(ref: local, frame: frame, key: key)
            return WebTabController.ElementInfo(description: shown(info.description), submits: info.submits,
                                                href: info.href, isPassword: info.isPassword)
        }

        func shown(_ text: String) -> String {
            number.map { AgentFrames.prefixRefs(text, frame: $0) } ?? text
        }
    }

    func refTarget(_ ref: AgentRef, _ controller: WebTabController, _ space: Space, _ record: CallRecord) throws -> RefTarget {
        guard let number = ref.frame else { return RefTarget(frame: nil, key: nil, number: nil, local: ref.local) }
        guard let entry = controller.agentFrames.entry(number) else {
            throw ToolError("No element with ref \(ref.text) on the current page (it may have changed). Call read_page again.")
        }
        // A plugin never acts in a frame of a site the owner switched it off for.
        if case .plugin(_, let title) = record.caller, siteIsOff(AgentFrames.origin(of: entry.frame), space, record.caller) {
            throw ToolError(AgentCaller.siteOff(title: title))
        }
        return RefTarget(frame: entry.frame, key: entry.key, number: number, local: ref.local)
    }

    /// For reads across frames: a plugin's connection doesn't see into frames of sites the owner
    /// switched it off for; an outside agent sees every frame.
    private func frameAllowed(_ space: Space, _ record: CallRecord) -> (WKFrameInfo) -> Bool {
        { [weak self] frame in
            guard let self else { return false }
            return !self.siteIsOff(AgentFrames.origin(of: frame), space, record.caller)
        }
    }

    // MARK: - Who may see what

    /// The Spaces `caller` gets tools for: agents on (outside), or switched on for the plugin now.
    private func spaces(for caller: AgentCaller, program: pid_t?) -> [Space] {
        AgentCaller.spaces(state?.spaces ?? [], caller: caller, isOpenForPlugin: { self.isOpen($0, for: caller, program: program) })
    }

    /// For a plugin's connection: the connection still comes from the plugin's running program
    /// (the one seen when it was accepted: a launcher left behind by an ended program gets nothing,
    /// also once the plugin runs a new one), and the Space is switched on for that plugin now
    /// (approved with `browser`, Space in its switches). Outside agents: always true (their gate is
    /// `agentsEnabled`).
    func isOpen(_ space: Space, for caller: AgentCaller, program: pid_t?) -> Bool {
        guard case .plugin(let id, _) = caller else { return true }
        guard let plugins = state?.plugins, let program, plugins.programPID(of: id) == program else { return false }
        return plugins.browserSpaceIsOpen(id, space: space)
    }

    /// Where a web or artifact tab is now: its live page's address (an artifact tab's page can leave
    /// the artifact server and stay an artifact tab) and a web tab's stored address (which follows
    /// the page). Empty for terminals and plugin tabs, which the site switch doesn't cover.
    private func currentAddresses(of tab: BrowserTab) -> [URL] {
        switch tab.kind {
        case .web, .artifact: return [state?.web.existingController(tab.id)?.webView.url, tab.url].compactMap { $0 }
        case .terminal, .plugin, .note, .home: return []
        }
    }

    /// For a plugin's connection: the tab is on a site the owner switched that plugin off for.
    private func tabIsOff(_ tab: BrowserTab, _ space: Space, _ caller: AgentCaller) -> Bool {
        currentAddresses(of: tab).contains { siteIsOff($0, space, caller) }
    }

    /// For a plugin's connection: the owner switched that plugin off for the site of `url` in the
    /// Space (as the Space is now). Never for an outside agent.
    private func siteIsOff(_ url: URL?, _ space: Space, _ caller: AgentCaller) -> Bool {
        guard case .plugin(let id, _) = caller, let url else { return false }
        return PluginReach.siteIsOff(state?.space(space.id) ?? space, pluginID: id, url: url)
    }

    /// A tab `caller` may know about: never a plugin's page; for a plugin, nothing on a switched-off site.
    private func tabIsVisible(_ tab: BrowserTab, in space: Space, to caller: AgentCaller) -> Bool {
        !tab.isHiddenFromAgents && !tabIsOff(tab, space, caller)
    }

    private func refuseOffSite(_ tab: BrowserTab, _ space: Space, _ record: CallRecord) throws {
        guard case .plugin(_, let title) = record.caller, tabIsOff(tab, space, record.caller) else { return }
        throw ToolError(AgentCaller.siteOff(title: title))
    }

    /// For a plugin's connection, after a wait: refuses when the Space is no longer switched on
    /// for it (`refuseIfSpaceClosed`), or the tab's live page is on a switched-off site now.
    private func refuseIfNowOff(_ controller: WebTabController, _ space: Space, _ record: CallRecord) throws {
        try refuseIfSpaceClosed(space, record)
        guard case .plugin(_, let title) = record.caller, siteIsOff(controller.webView.url, space, record.caller) else { return }
        throw ToolError(AgentCaller.siteOff(title: title))
    }

    /// For a plugin's connection: the owner switched the Space off for it (or its program ended)
    /// while the call waited (a page loading, a click's wait). The call then ends as a call to a
    /// closed Space does, with nothing from the page. Outside agents: never.
    private func refuseIfSpaceClosed(_ space: Space, _ record: CallRecord) throws {
        guard case .plugin = record.caller else { return }
        guard let now = state?.space(space.id), isOpen(now, for: record.caller, program: record.program) else {
            throw Self.unknownTool(record.tool)
        }
    }

    /// A click or type whose call was stopped (Stop, or the connection closing) after it was
    /// allowed but before it acts: it doesn't act, and ends as a withdrawn request does.
    private func refuseIfCancelled(_ cancellation: ApprovalCancellation, _ record: CallRecord) throws {
        guard Task.isCancelled || cancellation.isCancelled else { return }
        let outcome = AgentApprovals.Outcome.cancelled
        record.decision = outcome.logValue
        throw ToolError(outcome.refusal ?? "The request was withdrawn.")
    }

    private func refuseAddress(_ url: URL, _ space: Space, _ record: CallRecord) throws {
        guard case .plugin(_, let title) = record.caller, siteIsOff(url, space, record.caller) else { return }
        throw ToolError(AgentCaller.siteOff(title: title))
    }

    /// The page's address for a result, or "" when a plugin's action ended on a site it is
    /// switched off for (a click or redirect can carry a tab there; it isn't told where).
    private func shownAddress(_ controller: WebTabController, _ space: Space, _ record: CallRecord) -> String {
        siteIsOff(controller.webView.url, space, record.caller) ? "" : controller.webView.url?.absoluteString ?? ""
    }

    /// The answer for a tool that doesn't exist, also given for one that isn't open to the caller.
    static func unknownTool(_ name: String) -> ToolError {
        ToolError("Unknown tool \(name). Call list_spaces to see what is available.")
    }

    /// A plugin's tab: agents can neither read nor act on a plugin's own page.
    private static func notAWebPage(_ tabID: UUID) -> ToolError {
        ToolError("Tab \(tabID.uuidString.lowercased()) is not a web page.")
    }

    /// "Now at: <url>" plus the page title, with the title marked as page content. For a plugin's
    /// connection on a site it is switched off for: only that it is there.
    private func pageSummary(_ controller: WebTabController, _ space: Space, _ record: CallRecord) -> String {
        if case .plugin(_, let title) = record.caller, siteIsOff(controller.webView.url, space, record.caller) {
            return "Now at a site \(title) is switched off for."
        }
        let url = controller.webView.url?.absoluteString ?? "(no URL)"
        let title = controller.webView.title ?? ""
        return "Now at: \(url)\n" + UntrustedContent.wrap("Page title: \(title)", source: url)
    }

    static func json(_ value: Any) throws -> String {
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
struct Arguments {
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

    /// The `ref` argument: `12`, `"12"`, `"[12]"` or a frame ref `"f2:5"`.
    func ref(_ key: String = "ref") throws -> AgentRef {
        try AgentRef.parse(values[key])
    }

    func tabID() throws -> UUID {
        let text = try string("tab_id")
        guard let id = UUID(uuidString: text) else { throw AgentToolbox.ToolError("\"\(text)\" is not a valid tab_id.") }
        return id
    }

    func number(_ key: String) -> Double? {
        values[key]?.doubleValue ?? values[key]?.intValue.map(Double.init) ?? values[key]?.stringValue.flatMap(Double.init)
    }

    /// A list of strings (`file_upload`'s `paths`).
    func strings(_ key: String) throws -> [String] {
        guard case .array(let items)? = values[key] else { throw AgentToolbox.ToolError("Missing list argument \"\(key)\".") }
        return try items.map {
            guard let text = $0.stringValue else { throw AgentToolbox.ToolError("\"\(key)\" must be a list of strings.") }
            return text
        }
    }

    func url(_ key: String) throws -> URL {
        let text = try string(key)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
            throw AgentToolbox.ToolError("\"\(text)\" is not an absolute http(s) URL.")
        }
        return url
    }
}

extension Tool.Content {
    /// Plain text content without annotations.
    static func plain(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }
}
