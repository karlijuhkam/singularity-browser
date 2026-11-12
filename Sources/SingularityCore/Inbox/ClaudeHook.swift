import Foundation

/// What a Claude Code hook call means for the inbox.
public enum ClaudeHookEvent: Equatable, Sendable {
    /// A held AskUserQuestion. `questions` hold CLEANED text only; `toolInput` is the original
    /// `tool_input` object as JSON text, read again by `ClaudeHook.answerReply`.
    case question(questions: [InboxQuestion], toolInput: String)
    /// A held permission request; `input` is cleaned and ready to show. `isComplete` is false
    /// when `input` had to be cut to fit (`InboxText.inputLimit`).
    case permission(tool: String, input: String, isComplete: Bool)
    case stop(lastMessage: String?)
    /// Anything else, unreadable, or not safe to show (the terminal's own prompt stays alone).
    case ignored
}

/// Reads Claude Code hook input (stdin JSON) and builds the replies. Shapes follow the spec's
/// "As tested" section (Claude Code 2.1.322). All input is untrusted and may be hostile.
public enum ClaudeHook {
    public static let noDecision = Data()            // empty stdout, exit 0
    public static let maxWireBytes = 2_000_000       // longer lines are dropped
    /// The app's first byte on a connection it is going to answer (ASCII ACK), written from the
    /// main actor: it shows the helper the app is alive. The helper waits a few seconds for it,
    /// then gives up (no decision), and strips it from what it prints.
    public static let ack: UInt8 = 0x06
    static let maxQuestions = 4
    static let maxOptions = 8
    static let toolNameLimit = 100
    static let askTool = "AskUserQuestion"

    // MARK: Parsing

    public static func parse(_ hookInput: Data) -> ClaudeHookEvent {
        guard let root = object(from: hookInput) as? [String: Any],
              let name = root["hook_event_name"] as? String else { return .ignored }
        switch name {
        case "PreToolUse":
            guard root["tool_name"] as? String == askTool,
                  let input = root["tool_input"] as? [String: Any],
                  let questions = questions(from: input),
                  let text = jsonText(input) else { return .ignored }
            return .question(questions: questions, toolInput: text)
        case "PermissionRequest":
            // AskUserQuestion also raises a PermissionRequest; its dialog is the question itself.
            // A missing or odd tool_input is ignored: the owner must never approve what they can't see.
            guard let tool = root["tool_name"] as? String, tool != askTool,
                  let input = root["tool_input"] as? [String: Any] else { return .ignored }
            let cleanTool = InboxText.clean(tool, limit: toolNameLimit)
            guard !cleanTool.isEmpty else { return .ignored }
            let shown = permissionText(tool: tool, input: input)
            return .permission(tool: cleanTool, input: shown.text, isComplete: shown.isComplete)
        case "Stop":
            let raw = root["last_assistant_message"] as? String
            let text = raw.map { InboxText.clean($0, limit: InboxText.messageLimit) }
            return .stop(lastMessage: (text?.isEmpty ?? true) ? nil : text)
        default:
            return .ignored
        }
    }

    private static func questions(from input: [String: Any]) -> [InboxQuestion]? {
        guard let raw = input["questions"] as? [Any],
              !raw.isEmpty, raw.count <= maxQuestions else { return nil }
        var result: [InboxQuestion] = []
        var seen = Set<String>()
        for item in raw {
            guard let dict = item as? [String: Any],
                  let q = dict["question"] as? String,
                  let rawOptions = dict["options"] as? [Any],
                  !rawOptions.isEmpty, rawOptions.count <= maxOptions else { return nil }
            let text = InboxText.clean(q, limit: InboxText.messageLimit)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            var labels: [String] = []
            for option in rawOptions {
                guard let o = option as? [String: Any], let l = o["label"] as? String else { return nil }
                let label = InboxText.clean(l, limit: InboxText.messageLimit)
                guard !label.isEmpty, !labels.contains(label) else { return nil }
                labels.append(label)
            }
            var header = (dict["header"] as? String).map { InboxText.clean($0, limit: InboxText.messageLimit) }
            if header?.isEmpty == true { header = nil }
            result.append(InboxQuestion(question: text, header: header, options: labels,
                                        multiSelect: (dict["multiSelect"] as? Bool) ?? false))
        }
        return result
    }

    /// The input fields that say where or what a tool acts on, in the order the card shows them.
    static let identifyingKeys = ["file_path", "path", "notebook_path", "command", "url", "pattern", "description"]

    /// What the permission card shows, and whether that is all of it.
    /// The identifying fields (those that are strings) come first, each on its own line as
    /// `name: value`, for Bash the command before the others; then every other key as sorted,
    /// pretty-printed JSON (none when nothing is left). So the destination of a `Write` is on
    /// the first line even though `content` sorts before `file_path`. Cut to
    /// `InboxText.inputLimit`; `isComplete` false when it had to be cut, and then the inbox
    /// does not offer Allow: the owner must never approve what they can't see.
    private static func permissionText(tool: String, input: [String: Any]) -> (text: String, isComplete: Bool) {
        var keys = identifyingKeys
        if tool == "Bash", let index = keys.firstIndex(of: "command") {
            keys.insert(keys.remove(at: index), at: 0)
        }
        var lines: [String] = []
        var rest = input
        for key in keys {
            guard let value = input[key] as? String else { continue }
            lines.append("\(key): \(value)")
            rest[key] = nil
        }
        if !rest.isEmpty, let json = jsonText(rest, pretty: true) { lines.append(json) }
        // Cleaned in full first, so the length that decides "complete" is the length shown.
        let full = InboxText.cleanBlock(lines.joined(separator: "\n"), limit: .max)
        let isComplete = full.count <= InboxText.inputLimit
        return (isComplete ? full : InboxText.cleanBlock(full, limit: InboxText.inputLimit), isComplete)
    }

    // MARK: Replies

    /// `answers`: cleaned question text → cleaned labels. Mapped back to the original strings by
    /// reading `toolInput` again. Multi-select labels are joined with ", ".
    public static func answerReply(toolInput: String, answers: [String: [String]]) -> Data {
        guard var input = object(from: Data(toolInput.utf8)) as? [String: Any],
              let questions = input["questions"] as? [Any] else { return noDecision }
        var out: [String: String] = [:]
        for item in questions {
            guard let dict = item as? [String: Any], let original = dict["question"] as? String,
                  let chosen = answers[InboxText.clean(original, limit: InboxText.messageLimit)],
                  let options = dict["options"] as? [Any] else { continue }
            let labels = chosen.compactMap { picked -> String? in
                for case let option as [String: Any] in options {
                    if let l = option["label"] as? String,
                       InboxText.clean(l, limit: InboxText.messageLimit) == picked { return l }
                }
                return nil
            }
            if !labels.isEmpty { out[original] = labels.joined(separator: ", ") }
        }
        guard !out.isEmpty else { return noDecision }
        // updatedInput replaces the whole input: every original key stays, `questions` included.
        input["answers"] = out
        let reply: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input,
        ] as [String: Any]]
        return serialize(reply) ?? noDecision
    }

    public static func permissionReply(allow: Bool) -> Data {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = "Denied in Singularity's inbox." }
        let reply: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest", "decision": decision,
        ] as [String: Any]]
        return serialize(reply) ?? noDecision
    }

    // MARK: Wire

    /// `{"tab":"<uuid>","hook":<hook input>}\n`. The hook input is re-serialised so the result
    /// is one line; input that is not JSON is sent as `{}` (the app then ignores it).
    public static func wireLine(tabID: String, hookInput: Data) -> Data {
        let hook = object(from: hookInput) ?? [String: Any]()
        var data = serialize(["tab": tabID, "hook": hook] as [String: Any]) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func parseWireLine(_ line: Data) -> (tabID: UUID, hookInput: Data)? {
        guard line.count <= maxWireBytes,
              let root = object(from: line) as? [String: Any],
              let tab = root["tab"] as? String, let id = UUID(uuidString: tab),
              let hook = root["hook"], !(hook is NSNull),
              let data = serialize(hook) else { return nil }
        return (id, data)
    }

    // MARK: JSON helpers

    /// Foundation refuses very deep nesting itself (an error, not a crash).
    private static func object(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func serialize(_ value: Any, pretty: Bool = false) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber else { return nil }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: value, options: options)
    }

    private static func jsonText(_ value: Any, pretty: Bool = false) -> String? {
        serialize(value, pretty: pretty).flatMap { String(data: $0, encoding: .utf8) }
    }
}
