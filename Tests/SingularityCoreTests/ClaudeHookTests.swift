import Foundation
import Testing
@testable import SingularityCore

@Suite struct ClaudeHookTests {
    static let questionJSON = """
    {"session_id":"f32c","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[{"question":"Which database should we use?","header":"Database",
       "options":[{"label":"SQLite","description":"File-based"},{"label":"Postgres","description":"Server"}],
       "multiSelect":false}]},"tool_use_id":"toolu_01"}
    """

    func parse(_ s: String) -> ClaudeHookEvent { ClaudeHook.parse(Data(s.utf8)) }
    func dict(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    @Test func parseQuestion() {
        guard case let .question(qs, toolInput) = parse(Self.questionJSON) else { Issue.record("not a question"); return }
        #expect(qs.count == 1)
        #expect(qs[0].question == "Which database should we use?")
        #expect(qs[0].header == "Database")
        #expect(qs[0].options == ["SQLite", "Postgres"])
        #expect(toolInput.contains("Postgres"))
    }

    @Test func parsePermission() {
        let bash = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm x.txt","description":"d"}}"#)
        #expect(bash == .permission(tool: "Bash", input: "command: rm x.txt\ndescription: d", isComplete: true))
        guard case let .permission(tool, input, isComplete) = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/a/b","new":"c"}}"#) else { Issue.record("no"); return }
        #expect(tool == "Edit")
        #expect(input == "file_path: /a/b\n{\n  \"new\" : \"c\"\n}")
        #expect(isComplete)
    }

    func permission(_ tool: String, _ input: [String: Any]) -> (input: String, isComplete: Bool)? {
        let root: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              case let .permission(_, text, isComplete) = ClaudeHook.parse(data) else { return nil }
        return (text, isComplete)
    }

    /// What Allow approves must be visible: the fields that say where or what come first, one
    /// per line, then everything else as sorted JSON.
    @Test func identifyingFieldsComeFirst() throws {
        let input: [String: Any] = ["url": "https://x.test", "pattern": "*.swift", "path": "/p", "notebook_path": "/n.ipynb",
                                    "file_path": "/f", "command": "make", "description": "Build", "other": 1, "zeta": "z"]
        let shown = try #require(permission("Tool", input))
        #expect(shown.input == """
        file_path: /f
        path: /p
        notebook_path: /n.ipynb
        command: make
        url: https://x.test
        pattern: *.swift
        description: Build
        {
          "other" : 1,
          "zeta" : "z"
        }
        """)
        #expect(shown.isComplete)
        // Only strings count as identifying; anything else stays in the JSON.
        let odd = try #require(permission("Tool", ["file_path": 5, "path": ["a"]]))
        #expect(odd.input == "{\n  \"file_path\" : 5,\n  \"path\" : [\n    \"a\"\n  ]\n}")
        // Nothing else left: no JSON at all.
        #expect(try #require(permission("Read", ["file_path": "/etc/hosts"])).input == "file_path: /etc/hosts")
    }

    /// Bash: the command first, before any other identifying field.
    @Test func bashShowsTheCommandFirst() throws {
        let shown = try #require(permission("Bash", ["command": "ls -la\npwd", "description": "List", "path": "/tmp",
                                                     "run_in_background": true]))
        #expect(shown.input == "command: ls -la\npwd\npath: /tmp\ndescription: List\n{\n  \"run_in_background\" : true\n}")
        #expect(shown.isComplete)
    }

    /// A Write of a big file: `content` sorts before `file_path`, yet the path is on the first
    /// line; the text was cut, and says so through `isComplete`.
    @Test func longInputIsMarkedIncomplete() throws {
        let content = String(repeating: "a", count: 10_000)
        let write = try #require(permission("Write", ["content": content, "file_path": "/Users/me/project/big.txt"]))
        #expect(write.input.hasPrefix("file_path: /Users/me/project/big.txt\n"))
        #expect(!write.isComplete)
        #expect(write.input.count == InboxText.inputLimit)
        #expect(write.input.hasSuffix("…"))
        let small = try #require(permission("Write", ["content": "hello", "file_path": "/tmp/a.txt"]))
        #expect(small.isComplete)
        #expect(small.input == "file_path: /tmp/a.txt\n{\n  \"content\" : \"hello\"\n}")
        // A long Bash command.
        let bash = try #require(permission("Bash", ["command": "echo " + String(repeating: "x", count: 5_000)]))
        #expect(bash.input.hasPrefix("command: echo xxx"))
        #expect(!bash.isComplete)
        // Exactly at the limit is complete; one more is not.
        let fits = try #require(permission("Bash", ["command": String(repeating: "y", count: InboxText.inputLimit - 9)]))
        #expect(fits.input.count == InboxText.inputLimit && fits.isComplete)
        let over = try #require(permission("Bash", ["command": String(repeating: "y", count: InboxText.inputLimit - 8)]))
        #expect(!over.isComplete)
    }

    @Test func permissionForAskUserQuestionIsIgnored() {
        #expect(parse(#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#) == .ignored)
    }

    @Test func parseStop() {
        #expect(parse(#"{"hook_event_name":"Stop","last_assistant_message":"Done."}"#) == .stop(lastMessage: "Done."))
        #expect(parse(#"{"hook_event_name":"Stop"}"#) == .stop(lastMessage: nil))
    }

    @Test func otherToolsAndGarbageAreIgnored() {
        #expect(parse(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#) == .ignored)
        #expect(ClaudeHook.parse(Data("not json".utf8)) == .ignored)
        #expect(parse("{}") == .ignored)
        #expect(parse("[1,2]") == .ignored)
        #expect(parse(#"{"hook_event_name":5}"#) == .ignored)
        let options = (0..<50).map { "{\"label\":\"o\($0)\"}" }.joined(separator: ",")
        #expect(parse(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q","options":["# + options + #"]}]}}"#) == .ignored)
    }

    @Test func ambiguousQuestionsAreIgnored() {
        func q(_ questions: String) -> ClaudeHookEvent {
            parse(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":"# + questions + #"}}"#)
        }
        let o = #"[{"label":"a"},{"label":"b"}]"#
        #expect(q(#"[{"question":"Same","options":"# + o + #"},{"question":"Sa​me","options":"# + o + #"}]"#) == .ignored)
        #expect(q(#"[{"question":"x","options":[{"label":"a"},{"label":"a​"}]}]"#) == .ignored)
        #expect(q(#"[{"question":"​","options":"# + o + #"}]"#) == .ignored)
        #expect(q(#"[{"question":"x","options":[{"label":"​"}]}]"#) == .ignored)
        #expect(q("[]") == .ignored)
        #expect(q(#"[{"question":"x","options":[]}]"#) == .ignored)
        #expect(q(#"[{"question":"x"}]"#) == .ignored)
    }

    @Test func questionAndOptionLimits() {
        func event(questions: Int, options: Int) -> ClaudeHookEvent {
            let opts = (0..<options).map { "{\"label\":\"o\($0)\"}" }.joined(separator: ",")
            let qs = (0..<questions).map { "{\"question\":\"q\($0)\",\"options\":[\(opts)]}" }.joined(separator: ",")
            return parse("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[\(qs)]}}")
        }
        if case .question(let qs, _) = event(questions: 4, options: 8) {
            #expect(qs.count == 4 && qs[0].options.count == 8)
        } else { Issue.record("4 questions with 8 options should be accepted") }
        #expect(event(questions: 5, options: 2) == .ignored)
        #expect(event(questions: 1, options: 9) == .ignored)
    }

    @Test func permissionNeedsAnObjectInput() {
        #expect(parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#) == .ignored)
        #expect(parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":"ls"}"#) == .ignored)
        #expect(parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":null}"#) == .ignored)
    }

    @Test func wireLineEdges() {
        let tab = UUID().uuidString
        #expect(ClaudeHook.parseWireLine(Data("{\"tab\":\"\(tab)\",\"hook\":null}".utf8)) == nil)
        // Exactly maxWireBytes is accepted (the check is `>`); one byte more is rejected.
        let head = Data("{\"tab\":\"\(tab)\",\"hook\":\"".utf8), tail = Data("\"}".utf8)
        func line(total: Int) -> Data { head + Data(repeating: 0x61, count: total - head.count - tail.count) + tail }
        #expect(ClaudeHook.parseWireLine(line(total: ClaudeHook.maxWireBytes)) != nil)
        #expect(ClaudeHook.parseWireLine(line(total: ClaudeHook.maxWireBytes + 1)) == nil)
    }

    @Test func hostileInputDoesNotTrap() {
        let big = String(repeating: "a", count: 1_000_000)
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        _ = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"X","tool_input":"# + deep + #"}"#)
        _ = ClaudeHook.parse(Data(deep.utf8))
        _ = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":5}}"#)
        _ = parse(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[1,{"question":3}]}}"#)
        guard case let .permission(_, input, isComplete) = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"c":""# + big + #""}}"#) else { Issue.record("no"); return }
        #expect(input.count <= InboxText.inputLimit)
        #expect(!isComplete)
    }

    @Test func answerReplyEchoesQuestionsAndAddsAnswers() {
        guard case let .question(qs, toolInput) = parse(Self.questionJSON) else { Issue.record("no"); return }
        let reply = ClaudeHook.answerReply(toolInput: toolInput, answers: [qs[0].question: ["SQLite"]])
        let out = dict(reply)["hookSpecificOutput"] as? [String: Any]
        #expect(out?["hookEventName"] as? String == "PreToolUse")
        #expect(out?["permissionDecision"] as? String == "allow")
        let updated = out?["updatedInput"] as? [String: Any]
        #expect(updated?["answers"] as? [String: String] == ["Which database should we use?": "SQLite"])
        let original = dict(Data(toolInput.utf8))["questions"] as? [Any] ?? []
        let echoed = NSArray(array: updated?["questions"] as? [Any] ?? [])
        let same = echoed.isEqual(to: original)
        #expect(same)
    }

    /// The original text has zero-width characters and spaces; the app only sees the cleaned form.
    @Test func answerReplyUsesOriginalStrings() {
        let json = #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"extra":1,"questions":[{"question":"  Which​  one? ","options":[{"label":"A​"},{"label":"B"}],"multiSelect":true}]}}"#
        guard case let .question(qs, toolInput) = parse(json) else { Issue.record("no"); return }
        #expect(qs[0].question == "Which one?")
        let reply = ClaudeHook.answerReply(toolInput: toolInput, answers: ["Which one?": ["A", "B"]])
        let updated = (dict(reply)["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any]
        #expect(updated?["answers"] as? [String: String] == ["  Which\u{200B}  one? ": "A\u{200B}, B"])
        #expect(updated?["extra"] as? Int == 1)
    }

    @Test func multiSelectJoinsLabels() {
        guard case let .question(_, toolInput) = parse(Self.questionJSON) else { Issue.record("no"); return }
        let reply = ClaudeHook.answerReply(toolInput: toolInput,
                                           answers: ["Which database should we use?": ["SQLite", "Postgres"]])
        let updated = (dict(reply)["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any]
        #expect((updated?["answers"] as? [String: String])?.values.first == "SQLite, Postgres")
    }

    @Test func unmatchedAnswersGiveNoDecision() {
        guard case let .question(_, toolInput) = parse(Self.questionJSON) else { Issue.record("no"); return }
        #expect(ClaudeHook.answerReply(toolInput: toolInput, answers: ["Nope": ["SQLite"]]) == ClaudeHook.noDecision)
        #expect(ClaudeHook.answerReply(toolInput: toolInput,
                                       answers: ["Which database should we use?": ["Mongo"]]) == ClaudeHook.noDecision)
        #expect(ClaudeHook.answerReply(toolInput: "garbage", answers: ["a": ["b"]]) == ClaudeHook.noDecision)
    }

    @Test func permissionReplies() {
        let allow = dict(ClaudeHook.permissionReply(allow: true))["hookSpecificOutput"] as? [String: Any]
        #expect(allow?["hookEventName"] as? String == "PermissionRequest")
        let ad = allow?["decision"] as? [String: Any]
        #expect(ad?["behavior"] as? String == "allow")
        #expect(allow?["updatedPermissions"] == nil && ad?["updatedPermissions"] == nil)
        let deny = (dict(ClaudeHook.permissionReply(allow: false))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(deny?["behavior"] as? String == "deny")
        #expect(deny?["message"] as? String == "Denied in Singularity's inbox.")
    }

    @Test func wireLineRoundTrips() throws {
        let id = UUID()
        let hook = Data("{\n  \"a\": \"x\\ny\",\n  \"b\": [1,2]\n}".utf8)
        let line = ClaudeHook.wireLine(tabID: id.uuidString, hookInput: hook)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let parsed = try #require(ClaudeHook.parseWireLine(line))
        #expect(parsed.tabID == id)
        #expect(dict(parsed.hookInput)["a"] as? String == "x\ny")
    }

    /// The exact bytes of a wire line. `singularity-hook` builds the same line with its own copy of
    /// this code (it does not link SingularityCore): if this test has to change, change
    /// `Sources/singularity-hook/main.swift` too. The app test `HeldRequestTests` also compares
    /// the real helper's line with `wireLine`.
    @Test func wireLineFormatIsPinned() {
        let hook = Data(#"{"b": [1, 2.5, true, null], "a": "x/y \"q\" é", "c": {"z": 1, "y": "line\nbreak"}}"#.utf8)
        let line = ClaudeHook.wireLine(tabID: "6916BFB3-AA44-4400-83E8-6735FE2E2030", hookInput: hook)
        let expected = #"{"hook":{"a":"x/y \"q\" é","b":[1,2.5,true,null],"c":{"y":"line\nbreak","z":1}},"tab":"6916BFB3-AA44-4400-83E8-6735FE2E2030"}"#
        #expect(String(decoding: line, as: UTF8.self) == expected + "\n")
        // Not JSON: the hook is sent as {} (the app then ignores it).
        #expect(String(decoding: ClaudeHook.wireLine(tabID: "t", hookInput: Data("nope".utf8)), as: UTF8.self)
                == #"{"hook":{},"tab":"t"}"# + "\n")
        // The acknowledgement byte (the helper's copy is `ackByte`).
        #expect(ClaudeHook.ack == 0x06)
    }

    @Test func parseWireLineRejectsBadLines() {
        #expect(ClaudeHook.parseWireLine(Data(#"{"tab":"nope","hook":{}}"#.utf8)) == nil)
        #expect(ClaudeHook.parseWireLine(Data("{\"tab\":\"\(UUID().uuidString)\"}".utf8)) == nil)
        #expect(ClaudeHook.parseWireLine(Data("[]".utf8)) == nil)
        let long = Data("{\"tab\":\"\(UUID().uuidString)\",\"hook\":\"".utf8)
            + Data(repeating: 0x61, count: ClaudeHook.maxWireBytes) + Data("\"}".utf8)
        #expect(ClaudeHook.parseWireLine(long) == nil)
    }
}
