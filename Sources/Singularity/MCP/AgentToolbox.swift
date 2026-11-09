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

        return [
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

    func call(_ name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
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
            let args = Arguments(arguments)
            switch tool {
            case "list_tabs": return .init(content: [.plain(try listTabs(space))])
            case "open": return .init(content: [.plain(try await open(space, url: args.url("url")))])
            case "navigate": return .init(content: [.plain(try await navigate(space, tabID: args.tabID(), url: args.url("url")))])
            case "close": return .init(content: [.plain(try close(space, tabID: args.tabID()))])
            case "read_page": return .init(content: [.plain(try await readPage(space, tabID: args.tabID()))])
            case "find": return .init(content: [.plain(try await find(space, tabID: args.tabID(), query: args.string("query")))])
            case "click": return .init(content: [.plain(try await click(space, tabID: args.tabID(), ref: args.int("ref")))])
            case "type":
                return .init(content: [.plain(try await type(space, tabID: args.tabID(), ref: args.int("ref"),
                                                            text: args.string("text"), submit: args.bool("submit") ?? false))])
            case "screenshot": return .init(content: [try await screenshot(space, tabID: args.tabID())])
            default: throw ToolError("Unknown tool \(name).")
            }
        } catch let error as ToolError {
            return .init(content: [.plain(error.message)], isError: true)
        } catch {
            return .init(content: [.plain(Self.message(for: error))], isError: true)
        }
    }

    // MARK: - Tools

    private func listSpaces() throws -> String {
        guard let state else { throw ToolError("Browser is shutting down.") }
        let spaces = state.spaces.filter(\.agentsEnabled).map { space -> [String: Any] in
            ["slug": space.slug, "name": space.name, "tabs": space.tabs.count,
             "example_tool": AgentToolName.make(slug: space.slug, tool: "list_tabs")]
        }
        if spaces.isEmpty {
            return "No Spaces are open to agents. The user can allow agents per Space in the Space's settings (right-click the Space → Edit Space…)."
        }
        return try Self.json(spaces)
    }

    private func listTabs(_ space: Space) throws -> String {
        let folders = Dictionary(uniqueKeysWithValues: space.folders.map { ($0.id, $0.name) })
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
            case .folder(let id): entry["section"] = "folder: " + (folders[id] ?? "?")
            }
            if tab.id == space.selectedTabID { entry["selected"] = true }
            // On screen right now: the selected tab, or any pane of its split (in the Space being shown).
            if state?.selectedSpaceID == space.id, space.visibleTabIDs.contains(tab.id) { entry["visible"] = true }
            return entry
        }
        // Titles come from pages, so the whole list counts as page content.
        return UntrustedContent.wrap(try Self.json(tabs), source: "tab list of Space \(space.slug)")
    }

    private func open(_ space: Space, url: URL) async throws -> String {
        guard let state, let (tab, controller) = state.agentOpenTab(url: url, spaceID: space.id) else {
            throw ToolError("Could not open a tab.")
        }
        await controller.waitUntilLoaded()
        return "Opened tab_id \(tab.id.uuidString.lowercased()).\n" + pageSummary(controller)
    }

    private func navigate(_ space: Space, tabID: UUID, url: URL) async throws -> String {
        let controller = try await webController(space, tabID)
        controller.load(url)
        await controller.waitUntilLoaded()
        return pageSummary(controller)
    }

    private func close(_ space: Space, tabID: UUID) throws -> String {
        guard let state, let tab = space.tab(tabID) else { throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space.") }
        guard !tab.isTerminal else { throw ToolError("Terminal tabs cannot be closed by agents.") }
        state.closeTab(tabID, in: space.id, confirmIfBusy: false)
        return "Closed tab_id \(tabID.uuidString.lowercased())."
    }

    private func readPage(_ space: Space, tabID: UUID) async throws -> String {
        let controller = try await webController(space, tabID)
        let outline = try await controller.callPageAgent("snapshot(maxChars)", arguments: ["maxChars": 15_000])
        return UntrustedContent.wrap(outline, source: controller.webView.url?.absoluteString ?? "")
    }

    private func find(_ space: Space, tabID: UUID, query: String) async throws -> String {
        let controller = try await webController(space, tabID)
        let matches = try await controller.callPageAgent("find(query, 25)", arguments: ["query": query])
        return UntrustedContent.wrap(matches, source: controller.webView.url?.absoluteString ?? "")
    }

    private func click(_ space: Space, tabID: UUID, ref: Int) async throws -> String {
        let controller = try await webController(space, tabID)
        let result = try await controller.callPageAgent("click(ref)", arguments: ["ref": ref])
        // If the click started a navigation, wait for it so the next read sees the new page.
        try? await Task.sleep(for: .milliseconds(300))
        await controller.waitUntilLoaded()
        return UntrustedContent.wrap(result, source: controller.webView.url?.absoluteString ?? "") + "\n" + pageSummary(controller)
    }

    private func type(_ space: Space, tabID: UUID, ref: Int, text: String, submit: Bool) async throws -> String {
        let controller = try await webController(space, tabID)
        let result = try await controller.callPageAgent("type(ref, text, submit)",
                                                        arguments: ["ref": ref, "text": text, "submit": submit])
        if submit {
            try? await Task.sleep(for: .milliseconds(300))
            await controller.waitUntilLoaded()
        }
        return UntrustedContent.wrap(result, source: controller.webView.url?.absoluteString ?? "") + "\n" + pageSummary(controller)
    }

    private func screenshot(_ space: Space, tabID: UUID) async throws -> Tool.Content {
        let controller = try await webController(space, tabID)
        let image = try await controller.webView.takeSnapshot(configuration: nil)
        guard let png = Self.pngData(image, maxWidth: 1280) else { throw ToolError("Could not encode the screenshot.") }
        return .image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)
    }

    // MARK: - Helpers

    /// A live web view for a web or artifact tab, loading it first if it hasn't been shown yet.
    private func webController(_ space: Space, _ tabID: UUID) async throws -> WebTabController {
        guard let state else { throw ToolError("Browser is shutting down.") }
        guard let tab = space.tab(tabID) else {
            throw ToolError("No tab \(tabID.uuidString.lowercased()) in this Space. Call \(AgentToolName.make(slug: space.slug, tool: "list_tabs")).")
        }
        guard !tab.isTerminal else { throw ToolError("Tab \(tabID.uuidString.lowercased()) is a terminal, not a web page.") }
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
        if let value = values[key]?.doubleValue, value == value.rounded() { return Int(value) }
        if let text = values[key]?.stringValue, let value = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) { return value }
        throw AgentToolbox.ToolError("Missing integer argument \"\(key)\".")
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
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
