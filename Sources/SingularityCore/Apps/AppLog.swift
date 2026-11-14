import Foundation

/// An app's `worker.log`, in its data folder: what the Worker printed, its errors and why it
/// could not start. A file, so the agent that writes the app can read it (the native panel shows
/// the same lines to the owner). Kept short: when it passes `maxBytes` it is cut to its last
/// `keptLines` lines.
///
/// Every line goes through `scrub` first, which replaces the app's key values (see
/// `AppKeySubstitution.scrubLog`).
public final class AppLog: @unchecked Sendable {   // the file is only touched while holding `lock`
    public static let maxBytes = 256 * 1024
    public static let keptLines = 200

    public let file: URL
    private let scrub: @Sendable (String) -> String
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(file: URL, scrub: @escaping @Sendable (String) -> String = { $0 },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.scrub = scrub
        self.now = now
    }

    /// Adds one entry: "2026-11-14T20:41:05Z error message". Further lines of a multi-line
    /// message (a stack) follow indented, so an entry is easy to tell from the next.
    public func append(level: String, text: String) {
        let stamp = ISO8601DateFormatter().string(from: now())
        let lines = scrub(text).split(separator: "\n", omittingEmptySubsequences: false)
        var entry = "\(stamp) \(level == "error" ? "error" : "info") \(lines.first ?? "")\n"
        for line in lines.dropFirst() { entry += "    \(line)\n" }

        lock.withLock {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return }
            try? handle.write(contentsOf: Data(entry.utf8))
            if Int(end) + entry.utf8.count > Self.maxBytes { trim() }
        }
    }

    /// The last `count` lines, oldest first.
    public func lastLines(_ count: Int) -> [String] {
        lock.withLock { Array(readLines().suffix(count)) }
    }

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Rewrites the file with its last lines only (and at most half of `maxBytes`, in case a
    /// single entry was enormous).
    private func trim() {
        var kept = Array(readLines().suffix(Self.keptLines))
        while kept.count > 1, kept.reduce(0, { $0 + $1.utf8.count + 1 }) > Self.maxBytes / 2 { kept.removeFirst() }
        var text = kept.joined(separator: "\n") + "\n"
        if text.utf8.count > Self.maxBytes / 2 { text = String(text.suffix(Self.maxBytes / 2)) }
        try? Data(text.utf8).write(to: file, options: .atomic)
    }
}
