import Foundation

/// One line of `<space>/agent-log.jsonl`: one agent tool call (or artifact prompt).
public struct AgentLogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// Who acted: the MCP client's name ("claude-code") or "artifact page".
    public var client: String
    public var tool: String
    public var tabID: UUID?
    public var args: [String: String]
    /// auto, approved, approved_site, denied, timeout, readonly.
    public var decision: String
    public var ok: Bool
    /// The start of the result, or the error message.
    public var result: String
    public var milliseconds: Int

    public init(id: UUID = UUID(), date: Date = Date(), client: String, tool: String, tabID: UUID?,
                args: [String: String], decision: String, ok: Bool, result: String, milliseconds: Int) {
        self.id = id
        self.date = date
        self.client = client
        self.tool = tool
        self.tabID = tabID
        self.args = args
        self.decision = decision
        self.ok = ok
        self.result = AgentLogStore.clip(result)
        self.milliseconds = milliseconds
    }

    enum CodingKeys: String, CodingKey {
        case id, date = "ts", client, tool, tabID = "tab_id", args, decision, ok, result, milliseconds = "ms"
    }
}

public struct AgentLogStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Long values (typed text, results) are cut to this many characters in the log.
    public static let maxValueLength = 200

    public static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > maxValueLength ? String(flat.prefix(maxValueLength - 1)) + "…" : flat
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func append(_ entry: AgentLogEntry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: file)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// The last `limit` entries, oldest first. Unreadable lines are skipped.
    public func loadRecent(limit: Int = 200) -> [AgentLogEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let lines = data.split(separator: UInt8(ascii: "\n")).suffix(limit)
        return lines.compactMap { try? Self.decoder.decode(AgentLogEntry.self, from: Data($0)) }
    }
}
