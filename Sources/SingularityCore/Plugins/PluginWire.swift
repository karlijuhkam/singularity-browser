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
    /// A message from the plugin's own page (its panel or tab); the plugin answers with `.reply`.
    case panelMessage(requestID: Int, payload: JSONValue)
    /// The program asked for with `.startProgram` is running.
    case programStarted(programID: Int)
    /// The program was not started (`reason` says why), or could not be.
    case programFailed(programID: Int, reason: String)
    /// Bytes the program wrote to its stdout, base64, at most 48 KB of bytes a message.
    case programOutput(programID: Int, data: String)
    /// The program has ended and all its output has been sent. `status` is its exit status when
    /// it exited, `signal` the signal's name (e.g. "SIGTERM") when a signal ended it.
    case programExit(programID: Int, status: Int32?, signal: String?)
    /// The tab in front changed: a `FrontTab` as JSON, or null when there is none to show.
    case frontChanged(payload: JSONValue)

    // Plugin to app
    case reply(requestID: Int, payload: JSONValue)
    /// Asks the app to run a declared command (see `PluginProcess`).
    case runCommand(callID: Int, command: String, arguments: [String])
    /// A line for the plugin's log (console output is turned into these by host.ts).
    case log(level: String, message: String)
    /// Asks the app to start a program from `permissions.programs` and keep it running. The plugin
    /// picks `programID`; every later message about this program carries it.
    case startProgram(programID: Int, program: String, arguments: [String], environment: [String: String])
    /// Bytes for the program's stdin, base64.
    case programInput(programID: Int, data: String)
    /// Closes the program's stdin (after the input sent before it).
    case closeProgramInput(programID: Int)
    /// Ends the program: "SIGTERM", "SIGKILL" or "SIGINT" (anything else counts as "SIGTERM").
    case killProgram(programID: Int, signal: String)
    /// The plugin has taken this many bytes of the program's output; the app reads more.
    case programOutputRead(programID: Int, bytes: Int)
    /// A message for the plugin's own page.
    case panelPost(payload: JSONValue)
    /// Asks for the tab in front; the app answers with `.reply` (a `FrontTab` as JSON, or null).
    case frontRequest(requestID: Int)
    /// Asks how to start the browser server (`singularity-mcp`); the app answers with `.reply`
    /// (`{command, args, env}`, or null when the plugin may not or there is none).
    case browserServerRequest(requestID: Int)

    private enum Key: String, CodingKey {
        case kind, requestID, tabID, frameHost, payload, callID, result, command, arguments, level, message
        case programID, program, environment, data, signal, status, reason, bytes
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
        case "panelMessage":
            self = .panelMessage(requestID: try c.decode(Int.self, forKey: .requestID),
                                 payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        case "programStarted":
            self = .programStarted(programID: try c.decode(Int.self, forKey: .programID))
        case "programFailed":
            self = .programFailed(programID: try c.decode(Int.self, forKey: .programID),
                                  reason: try c.decode(String.self, forKey: .reason))
        case "programOutput":
            self = .programOutput(programID: try c.decode(Int.self, forKey: .programID),
                                  data: try c.decode(String.self, forKey: .data))
        case "programExit":
            self = .programExit(programID: try c.decode(Int.self, forKey: .programID),
                                status: try c.decodeIfPresent(Int32.self, forKey: .status),
                                signal: try c.decodeIfPresent(String.self, forKey: .signal))
        case "startProgram":
            self = .startProgram(programID: try c.decode(Int.self, forKey: .programID),
                                 program: try c.decode(String.self, forKey: .program),
                                 arguments: try c.decode([String].self, forKey: .arguments),
                                 environment: try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:])
        case "programInput":
            self = .programInput(programID: try c.decode(Int.self, forKey: .programID),
                                 data: try c.decode(String.self, forKey: .data))
        case "closeProgramInput":
            self = .closeProgramInput(programID: try c.decode(Int.self, forKey: .programID))
        case "killProgram":
            self = .killProgram(programID: try c.decode(Int.self, forKey: .programID),
                                signal: try c.decodeIfPresent(String.self, forKey: .signal) ?? "SIGTERM")
        case "programOutputRead":
            self = .programOutputRead(programID: try c.decode(Int.self, forKey: .programID),
                                      bytes: try c.decode(Int.self, forKey: .bytes))
        case "panelPost":
            self = .panelPost(payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        case "frontChanged":
            self = .frontChanged(payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        case "frontRequest":
            self = .frontRequest(requestID: try c.decode(Int.self, forKey: .requestID))
        case "browserServerRequest":
            self = .browserServerRequest(requestID: try c.decode(Int.self, forKey: .requestID))
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
        case let .panelMessage(requestID, payload):
            try c.encode("panelMessage", forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(payload, forKey: .payload)
        case let .programStarted(programID):
            try c.encode("programStarted", forKey: .kind)
            try c.encode(programID, forKey: .programID)
        case let .programFailed(programID, reason):
            try c.encode("programFailed", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(reason, forKey: .reason)
        case let .programOutput(programID, data):
            try c.encode("programOutput", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(data, forKey: .data)
        case let .programExit(programID, status, signal):
            // Both always present (null when not applicable), so host.ts reads them as they are.
            try c.encode("programExit", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(status, forKey: .status)
            try c.encode(signal, forKey: .signal)
        case let .startProgram(programID, program, arguments, environment):
            try c.encode("startProgram", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(program, forKey: .program)
            try c.encode(arguments, forKey: .arguments)
            try c.encode(environment, forKey: .environment)
        case let .programInput(programID, data):
            try c.encode("programInput", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(data, forKey: .data)
        case let .closeProgramInput(programID):
            try c.encode("closeProgramInput", forKey: .kind)
            try c.encode(programID, forKey: .programID)
        case let .killProgram(programID, signal):
            try c.encode("killProgram", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(signal, forKey: .signal)
        case let .programOutputRead(programID, bytes):
            try c.encode("programOutputRead", forKey: .kind)
            try c.encode(programID, forKey: .programID)
            try c.encode(bytes, forKey: .bytes)
        case let .panelPost(payload):
            try c.encode("panelPost", forKey: .kind)
            try c.encode(payload, forKey: .payload)
        case let .frontChanged(payload):
            try c.encode("frontChanged", forKey: .kind)
            try c.encode(payload, forKey: .payload)
        case let .frontRequest(requestID):
            try c.encode("frontRequest", forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
        case let .browserServerRequest(requestID):
            try c.encode("browserServerRequest", forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
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
