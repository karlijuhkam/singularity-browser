import Foundation

/// Where the values of apps' keys are kept. `space` is the Space's id, `app` the app's path
/// ("firma"), `name` the key's name ("MERIT_KEY").
///
/// A normal copy keeps them in the macOS keychain (`KeychainAppKeyStore`, in the app target): the
/// one place an agent in a terminal can't simply read. A copy started with `SINGULARITY_HOME`
/// uses `FileAppKeyStore`, so a test copy never touches the keychain; tests use `MemoryAppKeyStore`.
public protocol AppKeyStore: Sendable {
    func value(space: UUID, app: String, name: String) -> String?
    func set(_ value: String, space: UUID, app: String, name: String) throws
    func delete(space: UUID, app: String, name: String)
    /// Every key of one app, or of the whole Space when `app` is nil.
    func deleteAll(space: UUID, app: String?)
}

/// The store's key for one value. The app's path can contain "/", the name can't, and a Space id
/// has neither, so the three parts can't be confused ("firma" never matches "firma2").
public enum AppKeyAddress {
    public static func account(space: UUID, app: String, name: String) -> String {
        prefix(space: space, app: app) + name
    }

    /// What every account of one app (or one Space) starts with.
    public static func prefix(space: UUID, app: String?) -> String {
        guard let app else { return space.uuidString.lowercased() + "\n" }
        return space.uuidString.lowercased() + "\n" + app + "\n"
    }
}

/// Keys in memory only (tests).
public final class MemoryAppKeyStore: AppKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func value(space: UUID, app: String, name: String) -> String? {
        lock.withLock { values[AppKeyAddress.account(space: space, app: app, name: name)] }
    }

    public func set(_ value: String, space: UUID, app: String, name: String) throws {
        lock.withLock { values[AppKeyAddress.account(space: space, app: app, name: name)] = value }
    }

    public func delete(space: UUID, app: String, name: String) {
        lock.withLock { values[AppKeyAddress.account(space: space, app: app, name: name)] = nil }
    }

    public func deleteAll(space: UUID, app: String?) {
        let prefix = AppKeyAddress.prefix(space: space, app: app)
        lock.withLock { values = values.filter { !$0.key.hasPrefix(prefix) } }
    }

    /// How many values are stored (tests).
    public var count: Int { lock.withLock { values.count } }
}

/// Keys in one JSON file, readable only by the owner (mode 0600). Used instead of the keychain
/// in a copy started with `SINGULARITY_HOME` (a test or development copy), where the file is
/// inside that copy's own data folder.
public final class FileAppKeyStore: AppKeyStore, @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    public func value(space: UUID, app: String, name: String) -> String? {
        lock.withLock { load()[AppKeyAddress.account(space: space, app: app, name: name)] }
    }

    public func set(_ value: String, space: UUID, app: String, name: String) throws {
        try lock.withLock {
            var values = load()
            values[AppKeyAddress.account(space: space, app: app, name: name)] = value
            try save(values)
        }
    }

    public func delete(space: UUID, app: String, name: String) {
        lock.withLock {
            var values = load()
            guard values.removeValue(forKey: AppKeyAddress.account(space: space, app: app, name: name)) != nil else { return }
            try? save(values)
        }
    }

    public func deleteAll(space: UUID, app: String?) {
        let prefix = AppKeyAddress.prefix(space: space, app: app)
        lock.withLock {
            let values = load()
            let kept = values.filter { !$0.key.hasPrefix(prefix) }
            guard kept.count != values.count else { return }
            try? save(kept)
        }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Written to a temporary file that is already 0600, then renamed over the old one: the
    /// values are never on disk in a file others can read, not even for a moment.
    private func save(_ values: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard fm.createFile(atPath: temp.path, contents: try encoder.encode(values), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // rename(2) replaces the old file in one step (and works when there is none yet).
        guard rename(temp.path, file.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// One key as the app needs it while a Worker runs: the stored value and the stand-in the
/// Worker's code gets instead of it.
public struct AppKeyMaterial: Equatable, Sendable {
    public var name: String
    public var host: String
    public var value: String
    /// What `env.NAME` is in the Worker when the key is not readable. New at every start.
    public var placeholder: String
    public var readable: Bool

    public init(name: String, host: String, value: String, placeholder: String, readable: Bool) {
        self.name = name
        self.host = host
        self.value = value
        self.placeholder = placeholder
        self.readable = readable
    }
}

/// Keeps key values out of the Worker: its code is written as on Cloudflare
/// (`Authorization: Bearer ${env.MERIT_KEY}`), but `env.MERIT_KEY` is a placeholder, and the
/// real value is put in only here, outside the sandbox, into a request for that key's host.
///
/// Every replacement is plain text replacement (no patterns), so a value may contain any
/// characters.
public enum AppKeySubstitution {
    /// "sgkey_" and 32 hex digits: long and odd enough never to appear in ordinary text.
    public static func makePlaceholder() -> String {
        "sgkey_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// `^[A-Za-z_][A-Za-z0-9_]*$`, at most 64 characters: a name usable as `env.NAME`.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64 else { return false }
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy(rest.contains)
    }

    /// What the Worker gets as `env`: the real value only for keys its code may read.
    public static func environment(_ keys: [AppKeyMaterial]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in keys { environment[key.name] = key.readable ? key.value : key.placeholder }
        return environment
    }

    /// A key's value has at least this many characters. A shorter one would be found by
    /// accident in ordinary answers and log lines ("12345" inside "9123456"), and replaced there.
    public static let minValueLength = 8

    /// An outside request on its way out: placeholders become values in the address, the header
    /// values and the body, but only for keys that belong to `host`. A placeholder in a request
    /// for any other host stays a placeholder, so a key can't be sent elsewhere.
    ///
    /// The value is written the way its place needs it, so a value with any characters keeps
    /// the request well-formed: percent-encoded in the address and in a form body, with JSON's
    /// escapes in a JSON body (by the request's `Content-Type`), as it is anywhere else.
    public static func outgoing(url: String, headers: [(String, String)], body: Data?, host: String,
                                keys: [AppKeyMaterial]) -> (url: String, headers: [(String, String)], body: Data?) {
        let pairs = keys.filter { !$0.readable && $0.host == host && !$0.value.isEmpty }
            .map { (from: $0.placeholder, to: $0.value) }
        guard !pairs.isEmpty else { return (url, headers, body) }
        let contentType = headers.first { $0.0.lowercased() == "content-type" }?.1.lowercased() ?? ""
        let bodyPairs: [(from: String, to: String)]
        if contentType.contains("json") {
            bodyPairs = pairs.map { ($0.from, jsonEscaped($0.to)) }
        } else if contentType.contains("x-www-form-urlencoded") {
            bodyPairs = pairs.map { ($0.from, percentEncoded($0.to)) }
        } else {
            bodyPairs = pairs
        }
        return (replace(in: url, pairs.map { ($0.from, percentEncoded($0.to)) }),
                headers.map { ($0.0, replace(in: $0.1, pairs)) },
                replace(in: body, bodyPairs))
    }

    /// The answer on its way back: a real value the server echoed becomes the placeholder again
    /// before the Worker sees it, also where it comes back percent-encoded or with JSON's
    /// escapes. Keys the code may read are left alone (it has them anyway).
    public static func incoming(headers: [(String, String)], body: Data?, keys: [AppKeyMaterial])
        -> (headers: [(String, String)], body: Data?) {
        let pairs = hiding(keys.filter { !$0.readable }) { $0.placeholder }
        guard !pairs.isEmpty else { return (headers, body) }
        return (headers.map { ($0.0, replace(in: $0.1, pairs)) }, replace(in: body, pairs))
    }

    /// An address the outside gave us (a redirect's `Location`), before the Worker may see it as
    /// `response.url` and before it is used for the next hop: a real value in it becomes the
    /// placeholder again. The next hop then gets the value back only if its host is the key's.
    public static func scrubURL(_ url: String, keys: [AppKeyMaterial]) -> String {
        replace(in: url, hiding(keys.filter { !$0.readable }) { $0.placeholder })
    }

    /// A line for `worker.log`, which agents read: every key value, readable or not, becomes
    /// `[key NAME]`, as do its percent-encoded and JSON-escaped forms and, for a value of several
    /// lines (a PEM key), each of its lines. A key the code may read can still be printed in
    /// another form (base64, cut in two), which the owner accepted by making it readable.
    public static func scrubLog(_ line: String, keys: [AppKeyMaterial]) -> String {
        var pairs = hiding(keys) { "[key \($0.name)]" }
        for key in keys {
            pairs.append((key.placeholder, "[key \(key.name)]"))
            let lines = key.value.split(whereSeparator: \.isNewline).map(String.init)
            if lines.count > 1 {
                for part in lines where part.count >= minValueLength { pairs.append((part, "[key \(key.name)]")) }
            }
        }
        return replace(in: line, pairs)
    }

    /// For each key, the forms its value can turn up in, each to be replaced by `with(key)`.
    private static func hiding(_ keys: [AppKeyMaterial], with: (AppKeyMaterial) -> String) -> [(from: String, to: String)] {
        var pairs: [(from: String, to: String)] = []
        for key in keys where !key.value.isEmpty {
            for form in Set([key.value, percentEncoded(key.value), jsonEscaped(key.value)]) {
                pairs.append((form, with(key)))
            }
        }
        return pairs
    }

    /// The text between the quotes of `value` as a JSON string.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let quoted = String(data: data, encoding: .utf8),
              quoted.count >= 2 else { return value }
        // JSONEncoder writes "/" as "\/"; both are valid JSON, the plain one is what people write.
        return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }

    /// `value` as one query (or form) value.
    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }

    /// Longest first, so a value that contains another value is replaced whole. Plain text
    /// replacement (no patterns): a value may contain any characters.
    private static func replace(in text: String, _ pairs: [(from: String, to: String)]) -> String {
        var text = text
        for pair in pairs.sorted(by: { $0.from.count > $1.from.count }) where !pair.from.isEmpty {
            text = text.replacingOccurrences(of: pair.from, with: pair.to, options: .literal)
        }
        return text
    }

    /// In a body the replacement is done on bytes, not on text: the body may be in any encoding,
    /// or not text at all (an echoed key in a Latin-1 page is still the same bytes), and every
    /// other byte must stay exactly as it was.
    private static func replace(in body: Data?, _ pairs: [(from: String, to: String)]) -> Data? {
        guard var data = body, !data.isEmpty else { return body }
        for pair in pairs.sorted(by: { $0.from.utf8.count > $1.from.utf8.count }) where !pair.from.isEmpty {
            let from = Data(pair.from.utf8), to = Data(pair.to.utf8)
            var searchFrom = data.startIndex
            while searchFrom < data.endIndex, let found = data.range(of: from, in: searchFrom..<data.endIndex) {
                data.replaceSubrange(found, with: to)
                searchFrom = found.lowerBound + to.count
            }
        }
        return data
    }

    /// Characters that need no escaping inside a query value.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()
}
