import Foundation

/// The console problems and failed network calls of one tab, kept in memory for agents to read
/// (`read_console`, `read_network`). Filled from messages of the capture script that runs in the
/// page, so **everything in here is untrusted page content**: a page can put anything it likes
/// into these entries. Nothing is ever written to disk.
public struct PageCapture: Sendable {
    public struct ConsoleEntry: Equatable, Sendable {
        public var seq: Int
        /// "error", "warning", "exception" (uncaught), "rejection" (unhandled promise) or
        /// "resource" (an image, script or stylesheet that failed to load).
        public var level: String
        public var text: String
        public var source: String?
        public var line: Int?
        public var date: Date
    }

    public struct NetworkEntry: Equatable, Sendable {
        public var seq: Int
        /// "fetch" or "xhr".
        public var kind: String
        public var method: String
        public var url: String
        /// The HTTP status, or nil when the request failed without an answer.
        public var status: Int?
        /// Why it failed, when there was no answer.
        public var error: String?
        public var requestHeaders: [(name: String, value: String)]
        public var requestBody: String?
        public var responseHeaders: [(name: String, value: String)]
        public var responseBody: String?
        public var date: Date

        public static func == (a: NetworkEntry, b: NetworkEntry) -> Bool {
            a.seq == b.seq && a.url == b.url && a.status == b.status && a.method == b.method
        }

        /// Roughly how much memory the entry holds (for the per-tab cap).
        var size: Int {
            url.utf8.count + (requestBody?.utf8.count ?? 0) + (responseBody?.utf8.count ?? 0)
                + (requestHeaders + responseHeaders).reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
        }
    }

    public static let maxConsoleEntries = 200
    public static let maxNetworkEntries = 100
    /// Each payload, each body and each console text is cut here.
    public static let maxTextBytes = 64 * 1024
    /// All network entries of a tab together; the oldest go first.
    public static let maxTotalBytes = 4 * 1024 * 1024

    public private(set) var console: [ConsoleEntry] = []
    public private(set) var network: [NetworkEntry] = []
    /// Counters that only grow; an entry's `seq` is its cursor.
    private var consoleSeq = 0
    private var networkSeq = 0

    public init() {}

    public var isEmpty: Bool { console.isEmpty && network.isEmpty }

    /// Forgets everything (the site was switched off, or the tab went to another site). The
    /// counters keep growing, so an old cursor never matches new entries.
    public mutating func clear() {
        console.removeAll()
        network.removeAll()
    }

    // MARK: - Recording

    /// Takes one message from the capture script: a JSON object, as text. Anything that isn't
    /// shaped as expected is dropped; nothing in it is trusted.
    public mutating func record(json: String, date: Date = Date()) {
        guard json.utf8.count <= 4 * Self.maxTextBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        switch object["t"] as? String {
        case "console":
            guard let text = object["text"] as? String else { return }
            let level = object["level"] as? String ?? "error"
            guard ["error", "warning", "exception", "rejection", "resource"].contains(level) else { return }
            consoleSeq += 1
            console.append(ConsoleEntry(
                seq: consoleSeq, level: level, text: Self.cut(text),
                source: (object["source"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2000)) },
                line: object["line"] as? Int, date: date))
            if console.count > Self.maxConsoleEntries { console.removeFirst(console.count - Self.maxConsoleEntries) }
        case "net":
            guard let url = object["url"] as? String else { return }
            networkSeq += 1
            network.append(NetworkEntry(
                seq: networkSeq,
                kind: (object["kind"] as? String) == "xhr" ? "xhr" : "fetch",
                method: String((object["method"] as? String ?? "GET").uppercased().prefix(20)),
                url: String(url.prefix(4000)),
                status: object["status"] as? Int,
                error: (object["error"] as? String).map { String($0.prefix(2000)) },
                requestHeaders: Self.headers(object["reqHeaders"]),
                requestBody: (object["reqBody"] as? String).map(Self.cut),
                responseHeaders: Self.headers(object["resHeaders"]),
                responseBody: (object["resBody"] as? String).map(Self.cut),
                date: date))
            if network.count > Self.maxNetworkEntries { network.removeFirst(network.count - Self.maxNetworkEntries) }
            var total = network.reduce(0) { $0 + $1.size }
            while total > Self.maxTotalBytes, network.count > 1 {
                total -= network.removeFirst().size
            }
        default:
            return
        }
    }

    /// Cuts a text at the limit and says so.
    static func cut(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        // Cut on a character boundary at or below the byte limit.
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxTextBytes)
        while end.samePosition(in: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "\n[cut: \(text.utf8.count) bytes in all, the first \(maxTextBytes / 1024) KB are shown]"
    }

    /// Header values that are logins. Their values are replaced before anything is kept.
    public static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["authorization", "cookie", "set-cookie", "proxy-authorization"].contains(lower) { return true }
        return lower.contains("token") || lower.contains("secret") || lower.contains("key")
    }

    /// `{"name": "value"}` from the script → a sorted list with secret values hidden.
    static func headers(_ value: Any?) -> [(name: String, value: String)] {
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.keys.sorted().prefix(100).compactMap { name in
            guard let value = dictionary[name] as? String else { return nil }
            return (String(name.prefix(200)), isSecretHeader(name) ? "[hidden]" : String(value.prefix(4000)))
        }
    }

    // MARK: - Reading

    /// What a read answers: the text for the agent and the cursor to pass as `since` next time.
    public struct Report: Equatable, Sendable {
        public var text: String
        public var cursor: Int
        public var count: Int
    }

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Console problems newer than `since` (a cursor from an earlier answer; nil or 0 = all kept).
    public func consoleReport(since: Int?) -> Report {
        let since = max(0, since ?? 0)
        let entries = console.filter { $0.seq > since }
        var lines: [String] = []
        if let note = Self.droppedNote(since: since, firstKept: console.first?.seq, counter: consoleSeq) { lines.append(note) }
        for entry in entries {
            var line = "[\(entry.seq)] \(Self.timeFormat.string(from: entry.date)) \(entry.level): \(entry.text)"
            if let source = entry.source { line += "\n    at \(source)" + (entry.line.map { ":\($0)" } ?? "") }
            lines.append(line)
        }
        if entries.isEmpty { lines.append(since > 0 ? "Nothing new in the console." : "No console errors or warnings were captured.") }
        lines.append("cursor: \(consoleSeq) (pass it as `since` to get only what is newer)")
        return Report(text: lines.joined(separator: "\n"), cursor: consoleSeq, count: entries.count)
    }

    /// Failed requests newer than `since`.
    public func networkReport(since: Int?) -> Report {
        let since = max(0, since ?? 0)
        let entries = network.filter { $0.seq > since }
        var lines: [String] = []
        if let note = Self.droppedNote(since: since, firstKept: network.first?.seq, counter: networkSeq) { lines.append(note) }
        for entry in entries {
            let outcome = entry.status.map { "\($0)" } ?? "failed" + (entry.error.map { " (\($0))" } ?? "")
            lines.append("[\(entry.seq)] \(Self.timeFormat.string(from: entry.date)) \(entry.method) \(entry.url) → \(outcome) (\(entry.kind))")
            func block(_ title: String, _ headers: [(name: String, value: String)]) {
                guard !headers.isEmpty else { return }
                lines.append("    \(title):")
                for header in headers { lines.append("      \(header.name): \(header.value)") }
            }
            block("request headers", entry.requestHeaders)
            if let body = entry.requestBody, !body.isEmpty { lines.append("    request payload:\n" + Self.indent(body)) }
            block("response headers", entry.responseHeaders)
            if let body = entry.responseBody, !body.isEmpty { lines.append("    response body:\n" + Self.indent(body)) }
        }
        if entries.isEmpty { lines.append(since > 0 ? "No new failed requests." : "No failed requests were captured.") }
        lines.append("cursor: \(networkSeq) (pass it as `since` to get only what is newer)")
        return Report(text: lines.joined(separator: "\n"), cursor: networkSeq, count: entries.count)
    }

    /// "N earlier entries were dropped", when entries newer than the cursor are no longer kept.
    static func droppedNote(since: Int, firstKept: Int?, counter: Int) -> String? {
        // Entries since+1 … counter exist(ed); those below the first kept one are gone.
        let firstKept = firstKept ?? counter + 1
        let dropped = firstKept - 1 - since
        guard dropped > 0 else { return nil }
        return "\(dropped) earlier \(dropped == 1 ? "entry was" : "entries were") dropped (only the newest are kept)."
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n")
    }
}
