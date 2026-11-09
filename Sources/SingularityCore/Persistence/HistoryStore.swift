import Foundation

public struct HistoryEntry: Codable, Hashable, Sendable {
    public var date: Date
    public var url: URL
    public var title: String

    public init(date: Date = Date(), url: URL, title: String) {
        self.date = date
        self.url = url
        self.title = title
    }
}

/// Per-Space browsing history as an append-only JSON-lines file. It exists only to feed
/// the command palette, so it has no UI of its own.
public struct HistoryStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
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

    public func append(_ entry: HistoryEntry) throws {
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

    /// The most recent visit per URL, newest first, at most `limit` entries.
    /// Lines that fail to decode are skipped.
    public func load(limit: Int = 2000) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let entries = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? Self.decoder.decode(HistoryEntry.self, from: Data($0))
        }
        return Self.latestPerURL(entries, limit: limit)
    }

    /// Keeps only the newest entry for each URL, sorted newest first.
    public static func latestPerURL(_ entries: [HistoryEntry], limit: Int) -> [HistoryEntry] {
        var seen = Set<URL>()
        var result: [HistoryEntry] = []
        for entry in entries.sorted(by: { $0.date > $1.date }) where !seen.contains(entry.url) {
            seen.insert(entry.url)
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }
}
