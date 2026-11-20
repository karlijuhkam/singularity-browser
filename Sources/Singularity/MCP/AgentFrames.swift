import Foundation
import MCP
import WebKit

/// A ref as an agent writes it: `12` (main frame) or `f2:5` (element 5 of frame 2).
struct AgentRef: Equatable {
    /// The frame's number (`AgentFrames`), nil for the main frame.
    let frame: Int?
    let local: Int

    var text: String { frame.map { "f\($0):\(local)" } ?? String(local) }

    /// Accepts 12, "12", "[12]", "f2:5", "[f2:5]".
    static func parse(_ value: Value?) throws -> AgentRef {
        if let number = value?.intValue { return AgentRef(frame: nil, local: number) }
        if let number = value?.doubleValue, let exact = Int(exactly: number) { return AgentRef(frame: nil, local: exact) }
        guard let raw = value?.stringValue else { throw AgentToolbox.ToolError("Missing argument \"ref\" (a ref from read_page, e.g. 12 or f2:5).") }
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let number = Int(text) { return AgentRef(frame: nil, local: number) }
        if let match = text.wholeMatch(of: /f(\d+):(\d+)/), let frame = Int(match.1), let local = Int(match.2) {
            return AgentRef(frame: frame, local: local)
        }
        throw AgentToolbox.ToolError("\"\(raw)\" is not a ref. Use a ref from read_page, e.g. 12 or f2:5.")
    }
}

/// Receives the frames' introductions (see `PageAgentScript`) and hands each to the `AgentFrames`
/// of the web view it came from. One for the app; it holds the frame registries weakly.
@MainActor
final class AgentFrameRelay: NSObject, WKScriptMessageHandler {
    static let shared = AgentFrameRelay()

    private final class Weak { weak var frames: AgentFrames?; init(_ frames: AgentFrames) { self.frames = frames } }
    private var registries: [ObjectIdentifier: Weak] = [:]

    func attach(_ frames: AgentFrames, to webView: WKWebView) {
        registries = registries.filter { $0.value.frames != nil }
        registries[ObjectIdentifier(webView)] = Weak(frames)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only from our own world (the handler isn't in the page's), and never from the main frame:
        // it is never introduced.
        guard !message.frameInfo.isMainFrame, let webView = message.webView,
              let body = message.body as? [String: Any],
              let token = body["token"] as? String, let key = body["key"] as? String,
              token.count <= 100, key.count <= 100 else { return }
        registries[ObjectIdentifier(webView)]?.frames?.introduced(token: token, key: key, frame: message.frameInfo)
    }
}

/// The frames of one tab that agents have seen, numbered for refs (`f<N>:`). A frame keeps its
/// number for the life of its document; a frame that loads another document gets a new number,
/// so a ref from the old document can never reach the new one. Forgotten when the main frame
/// commits a new page.
@MainActor
final class AgentFrames {
    struct Entry {
        let number: Int
        /// The frame's document key (its refs are valid only while this is still its key).
        let key: String
        let frame: WKFrameInfo
        /// The parent frame's number; nil for a child of the main frame.
        let parent: Int?
        /// The token the parent knows its iframe element by (for positions, `AgentInput`).
        let token: String
    }

    /// How long a read waits for frames to introduce themselves, at each level.
    static let introductionWait: Duration = .milliseconds(300)
    /// A whole `read_page` or `find` across frames: frames not read by then are listed "(not read)".
    static let readLimit: Duration = .milliseconds(1200)
    /// Frames below the main frame that are read (a frame's frames' frames are not).
    static let maxDepth = 2

    /// Tests: introductions from frames whose address contains this are ignored (a frame that never answers).
    nonisolated(unsafe) static var silentForTests: String?
    /// At most this many introductions wait to be claimed by a read (oldest dropped first).
    static let maxWaitingIntroductions = 200
    var waitingIntroductions: Int { introductions.count }

    private var introductions: [String: (key: String, frame: WKFrameInfo)] = [:]
    /// Tokens in the order they arrived, for dropping the oldest.
    private var arrivals: [String] = []
    /// Reads under way. Introductions are only taken while one is: a page posting its own
    /// "introductions" at any other time costs nothing.
    private var reads = 0
    private var numbers: [String: Int] = [:]
    private var entries: [Int: Entry] = [:]
    private var next = 1

    func introduced(token: String, key: String, frame: WKFrameInfo) {
        guard reads > 0 else { return }
        if let silent = Self.silentForTests, frame.request.url?.absoluteString.contains(silent) == true { return }
        if introductions[token] == nil { arrivals.append(token) }
        introductions[token] = (key, frame)
        while introductions.count > Self.maxWaitingIntroductions, !arrivals.isEmpty {
            introductions.removeValue(forKey: arrivals.removeFirst())
        }
        if arrivals.count > Self.maxWaitingIntroductions * 4 { arrivals.removeAll { introductions[$0] == nil } }
    }

    /// Runs a read that takes introductions; when the last one ends, what is left is dropped.
    func reading<T>(_ work: () async throws -> T) async rethrows -> T {
        reads += 1
        defer {
            reads -= 1
            if reads == 0 { introductions = [:]; arrivals = [] }
        }
        return try await work()
    }

    /// A new page in the main frame: every frame number from before is gone.
    func reset() {
        introductions = [:]
        arrivals = []
        numbers = [:]
        entries = [:]
    }

    func entry(_ number: Int) -> Entry? { entries[number] }

    /// Waits (at most `introductionWait`, never past `deadline`) for the frames behind `tokens` to
    /// introduce themselves, then numbers them. Tokens nobody answered for are left out. Call it
    /// inside `reading`.
    func resolve(_ tokens: [String], parent: Int?, deadline: ContinuousClock.Instant = .now + .seconds(60)) async -> [String: Entry] {
        let until = min(ContinuousClock.now + Self.introductionWait, deadline)
        while tokens.contains(where: { introductions[$0] == nil }), ContinuousClock.now < until {
            try? await Task.sleep(for: .milliseconds(15))
        }
        var result: [String: Entry] = [:]
        for token in tokens {
            guard let introduction = introductions.removeValue(forKey: token) else { continue }
            let number = numbers[introduction.key] ?? { defer { next += 1 }; return next }()
            numbers[introduction.key] = number
            let entry = Entry(number: number, key: introduction.key, frame: introduction.frame, parent: parent, token: token)
            entries[number] = entry
            result[token] = entry
        }
        return result
    }

    /// A page-agent call in a frame that gives up (nil) at `deadline`: a frame whose scripts are
    /// busy, or whose web process hangs, doesn't hold up the whole read.
    private func call(_ controller: WebTabController, _ function: String, _ arguments: [String: Any], in entry: Entry?,
                      before deadline: ContinuousClock.Instant) async -> String? {
        guard ContinuousClock.now < deadline else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var done = false
            Task { @MainActor in
                let result = try? await controller.callPageAgent(function, arguments: arguments, frame: entry?.frame, key: entry?.key)
                if !done { done = true; continuation.resume(returning: result) }
            }
            Task { @MainActor in
                try? await Task.sleep(until: deadline)
                if !done { done = true; continuation.resume(returning: nil) }
            }
        }
    }

    /// The origin of a frame's document, as a URL ("https://pay.example:8443"), for the per-site switches.
    static func origin(of frame: WKFrameInfo) -> URL? {
        let origin = frame.securityOrigin
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return frame.request.url }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        return components.url
    }

    // MARK: - Reading across frames

    /// `read_page` over the main frame and its frames: each `@@frame <token>@@ "<label>"` line the
    /// script left becomes the frame's own outline, indented, with its refs written `[f<N>:<ref>]`.
    /// `allows` decides per frame (a plugin's site switches); a frame it refuses is only named.
    /// Frames not read within `readLimit` are listed as "(not read)".
    func snapshot(_ controller: WebTabController, maxChars: Int, allows: (WKFrameInfo) -> Bool) async throws -> String {
        try await reading {
            let deadline = ContinuousClock.now + Self.readLimit
            let main = try await controller.callPageAgent("snapshot(maxChars)", arguments: ["maxChars": maxChars])
            let text = await expand(main, controller: controller, parent: nil, depth: 1, maxChars: maxChars,
                                    deadline: deadline, allows: allows)
            let limit = maxChars + maxChars / 2
            guard text.count > limit else { return text }
            return String(text.prefix(limit)) + "\n… truncated. Use find(tab_id, query) to locate specific elements.\n"
        }
    }

    private func expand(_ text: String, controller: WebTabController, parent: Int?, depth: Int, maxChars: Int,
                        deadline: ContinuousClock.Instant, allows: (WKFrameInfo) -> Bool) async -> String {
        let lines = text.components(separatedBy: "\n")
        let placeholders = lines.compactMap { $0.firstMatch(of: /^(\s*)@@frame (\S+)@@ (.*)$/) }
        guard !placeholders.isEmpty else { return text }
        // Too deep, or out of time: named, not read (and not waited for).
        let found = depth > Self.maxDepth || ContinuousClock.now >= deadline
            ? [:] : await resolve(placeholders.map { String($0.2) }, parent: parent, deadline: deadline)
        var out: [String] = []
        for line in lines {
            guard let match = line.firstMatch(of: /^(\s*)@@frame (\S+)@@ (.*)$/) else { out.append(line); continue }
            let indent = String(match.1), label = String(match.3)
            guard let entry = found[String(match.2)] else {
                out.append("\(indent)iframe \(label) (not read)")
                continue
            }
            guard allows(entry.frame) else {
                out.append("\(indent)iframe (switched off)")
                continue
            }
            guard let child = await call(controller, "snapshot(maxChars)", ["maxChars": maxChars / 2], in: entry, before: deadline) else {
                out.append("\(indent)iframe \(label) (not read)")
                continue
            }
            let expanded = await expand(child, controller: controller, parent: entry.number, depth: depth + 1,
                                        maxChars: maxChars / 2, deadline: deadline, allows: allows)
            var body = expanded.components(separatedBy: "\n")
            // The child's own header lines: its address goes on the iframe line.
            let url = body.first { $0.hasPrefix("URL: ") }.map { String($0.dropFirst(5)) } ?? ""
            body.removeAll { $0.hasPrefix("Title: ") || $0.hasPrefix("URL: ") || $0.isEmpty }
            out.append("\(indent)iframe \(label)\(url.isEmpty ? "" : " url=\"\(url)\""):")
            for childLine in body {
                out.append(indent + "  " + Self.prefixRefs(childLine, frame: entry.number))
            }
        }
        return out.joined(separator: "\n")
    }

    /// `[12]` → `[f3:12]`; refs already written for a deeper frame (`[f4:2]`) stay as they are.
    nonisolated static func prefixRefs(_ text: String, frame: Int) -> String {
        text.replacing(/\[(\d+)\]/) { "[f\(frame):\($0.1)]" }
    }

    /// `find` over the main frame and its readable frames (within `readLimit`).
    func find(_ controller: WebTabController, query: String, allows: (WKFrameInfo) -> Bool) async throws -> String {
        try await reading {
            let deadline = ContinuousClock.now + Self.readLimit
            var results: [String] = []
            let main = try await controller.callPageAgent("find(query, 25)", arguments: ["query": query])
            if !main.hasPrefix("No matches") { results.append(main) }
            await findInFrames(controller, in: nil, depth: 1, query: query, deadline: deadline, allows: allows, into: &results)
            return results.isEmpty ? "No matches for \"\(query.replacingOccurrences(of: "\"", with: "'"))\"." : results.joined(separator: "\n")
        }
    }

    private func findInFrames(_ controller: WebTabController, in parent: Entry?, depth: Int, query: String,
                              deadline: ContinuousClock.Instant, allows: (WKFrameInfo) -> Bool, into results: inout [String]) async {
        guard depth <= Self.maxDepth,
              let json = await call(controller, "listFrames()", [:], in: parent, before: deadline),
              let tokens = try? JSONDecoder().decode([String].self, from: Data(json.utf8)), !tokens.isEmpty else { return }
        let found = await resolve(tokens, parent: parent?.number, deadline: deadline)
        for token in tokens {
            guard let entry = found[token], allows(entry.frame) else { continue }
            if let matches = await call(controller, "find(query, 25)", ["query": query], in: entry, before: deadline),
               !matches.hasPrefix("No matches") {
                results.append(Self.prefixRefs(matches, frame: entry.number))
            }
            await findInFrames(controller, in: entry, depth: depth + 1, query: query, deadline: deadline, allows: allows, into: &results)
        }
    }
}
