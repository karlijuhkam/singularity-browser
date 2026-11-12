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
        #expect(bash == .permission(tool: "Bash", input: "rm x.txt"))
        guard case let .permission(tool, input) = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/a/b","new":"c"}}"#) else { Issue.record("no"); return }
        #expect(tool == "Edit")
        #expect(input.contains("\"file_path\" : \"/a/b\""))
        #expect(input.contains("\n"))
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
        guard case let .permission(_, input) = parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"c":""# + big + #""}}"#) else { Issue.record("no"); return }
        #expect(input.count <= InboxText.inputLimit)
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
