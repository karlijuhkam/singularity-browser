import Foundation

/// Any JSON value. Page messages and replies carry plugin-defined data, so the app passes it
/// through without knowing its shape.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Order matters: JSONDecoder will not read `true` as a number or `1` as a Bool, so each
        // attempt below only succeeds for its own JSON type.
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// One message between the app and a plugin's background process. On the wire each message is
/// one JSON object on one line (stdin: app to plugin, stdout: plugin to app), with a "kind" field
/// naming the case, e.g. `{"kind":"reply","requestID":3,"payload":{"ok":true}}`.
/// `Resources/plugin-host/host.ts` is the other end.
public enum PluginWire: Codable, Equatable, Sendable {
    // App to plugin
    /// A message from the plugin's page script in a tab; the plugin answers with `.reply`.
    case pageMessage(requestID: Int, tabID: UUID, frameHost: String, payload: JSONValue)
    /// The outcome of the plugin's `.runCommand` with the same `callID`.
    case commandResult(callID: Int, result: CommandResult)

    // Plugin to app
    case reply(requestID: Int, payload: JSONValue)
    /// Asks the app to run a declared command (see `PluginProcess`).
    case runCommand(callID: Int, command: String, arguments: [String])
    /// A line for the plugin's log (console output is turned into these by host.ts).
    case log(level: String, message: String)

    private enum Key: String, CodingKey {
        case kind, requestID, tabID, frameHost, payload, callID, result, command, arguments, level, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "pageMessage":
            self = .pageMessage(requestID: try c.decode(Int.self, forKey: .requestID),
                                tabID: try c.decode(UUID.self, forKey: .tabID),
                                frameHost: try c.decode(String.self, forKey: .frameHost),
                                payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        case "commandResult":
            self = .commandResult(callID: try c.decode(Int.self, forKey: .callID),
                                  result: try c.decode(CommandResult.self, forKey: .result))
        case "reply":
            // A missing payload (JS `undefined` is dropped by JSON.stringify) means null.
            self = .reply(requestID: try c.decode(Int.self, forKey: .requestID),
                          payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        case "runCommand":
            self = .runCommand(callID: try c.decode(Int.self, forKey: .callID),
                               command: try c.decode(String.self, forKey: .command),
                               arguments: try c.decode([String].self, forKey: .arguments))
        case "log":
            self = .log(level: try c.decode(String.self, forKey: .level),
                        message: try c.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .pageMessage(requestID, tabID, frameHost, payload):
            try c.encode("pageMessage", forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(tabID, forKey: .tabID)
            try c.encode(frameHost, forKey: .frameHost)
            try c.encode(payload, forKey: .payload)
        case let .commandResult(callID, result):
            try c.encode("commandResult", forKey: .kind)
            try c.encode(callID, forKey: .callID)
            try c.encode(result, forKey: .result)
        case let .reply(requestID, payload):
            try c.encode("reply", forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(payload, forKey: .payload)
        case let .runCommand(callID, command, arguments):
            try c.encode("runCommand", forKey: .kind)
            try c.encode(callID, forKey: .callID)
            try c.encode(command, forKey: .command)
            try c.encode(arguments, forKey: .arguments)
        case let .log(level, message):
            try c.encode("log", forKey: .kind)
            try c.encode(level, forKey: .level)
            try c.encode(message, forKey: .message)
        }
    }
}

/// Cuts a byte stream into lines ("\n"-separated, the "\n" removed). A line longer than
/// `maxLength` is reported once as `.tooLong` and its bytes are thrown away up to the next "\n",
/// so a plugin can't make the app buffer unlimited memory.
struct LineSplitter {
    enum Piece: Equatable { case line(Data), tooLong }

    let maxLength: Int
    private var pending = Data()
    private var discarding = false   // inside an over-long line: skip until the next "\n"

    init(maxLength: Int) { self.maxLength = maxLength }

    mutating func append(_ chunk: Data) -> [Piece] {
        var pieces: [Piece] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let part = rest[rest.startIndex..<newline]
            if discarding {
                discarding = false
            } else if pending.count + part.count > maxLength {
                pieces.append(.tooLong)
            } else {
                pieces.append(.line(pending + part))
            }
            pending = Data()
            rest = rest[rest.index(after: newline)...]
        }
        if !discarding {
            pending.append(contentsOf: rest)
            if pending.count > maxLength {
                pieces.append(.tooLong)
                pending = Data()
                discarding = true
            }
        }
        return pieces
    }

    /// At end of stream: the last line if it had no "\n".
    mutating func finish() -> [Piece] {
        defer { pending = Data(); discarding = false }
        return pending.isEmpty || discarding ? [] : [.line(pending)]
    }
}
