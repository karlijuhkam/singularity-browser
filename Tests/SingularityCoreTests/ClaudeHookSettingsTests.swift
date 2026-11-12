import Foundation
import Testing
@testable import SingularityCore

@Suite struct ClaudeHookSettingsTests {
    let helper = "/Applications/Singularity.app/Contents/MacOS/singularity-hook"
    let odd = "/Users/o'neil/My Apps/Singularity.app/Contents/MacOS/singularity-hook"

    func object(_ text: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    func install(_ text: String?, _ path: String? = nil, timeout: Int = 3600) throws -> String {
        try ClaudeHookSettings.install(settingsText: text, helper: path ?? helper, timeoutSeconds: timeout)
    }

    let others = """
    {
      "model": "opus",
      "permissions": { "allow": ["Bash(ls)"] },
      "hooks": {
        "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo hi" } ] } ],
        "Stop": [ { "hooks": [ { "type": "command", "command": "other-tool stop", "timeout": 5 } ] } ]
      }
    }
    """

    @Test func installIntoNoFile() throws {
        let out = try install(nil)
        #expect(out.hasSuffix("\n"))
        let hooks = try #require(try object(out)["hooks"] as? NSDictionary)
        let pre = try #require(hooks["PreToolUse"] as? [NSDictionary])
        #expect(pre.count == 1)
        #expect(pre[0]["matcher"] as? String == "AskUserQuestion")
        let preHook = try #require((pre[0]["hooks"] as? [NSDictionary])?.first)
        #expect(preHook["type"] as? String == "command")
        #expect(preHook["command"] as? String == "'\(helper)' 2>/dev/null || cat >/dev/null")
        #expect(preHook["timeout"] as? Int == 3600)
        let perm = try #require(hooks["PermissionRequest"] as? [NSDictionary])
        #expect(perm[0]["matcher"] == nil)
        let stop = try #require(hooks["Stop"] as? [NSDictionary])
        #expect(((stop[0]["hooks"] as? [NSDictionary])?.first?["timeout"] as? Int) == 10)
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 3600) == .installed)
        #expect(!out.contains("\\/"))
    }

    @Test func emptyTextIsLikeNoFile() throws {
        #expect(ClaudeHookSettings.status(settingsText: "  \n", helper: helper, timeoutSeconds: 3600) == .notInstalled)
        let out = try install(" \n")
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 3600) == .installed)
        #expect(try ClaudeHookSettings.remove(settingsText: " \n") == " \n")
    }

    @Test func installKeepsEverythingElse() throws {
        let out = try install(others)
        let before = try object(others)
        let after = try object(out)
        #expect(after["model"] as? String == "opus")
        #expect(after["permissions"] as? NSDictionary == before["permissions"] as? NSDictionary)
        let hooks = try #require(after["hooks"] as? NSDictionary)
        let pre = try #require(hooks["PreToolUse"] as? [NSDictionary])
        #expect(pre.count == 2)
        #expect(pre[0] == ((before["hooks"] as? NSDictionary)?["PreToolUse"] as? [NSDictionary])?[0])
        let stop = try #require(hooks["Stop"] as? [NSDictionary])
        #expect(stop.count == 2)
        #expect(stop[0] == ((before["hooks"] as? NSDictionary)?["Stop"] as? [NSDictionary])?[0])
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 3600) == .installed)
    }

    @Test func installKeepsNumbersAndBooleans() throws {
        let text = #"{"a":1,"b":1.5,"c":true,"d":false,"big":9007199254740993,"p":0.1,"n":null,"s":"a/b é","e":1e3,"neg":-0.5}"#
        let out = try install(text)
        let after = try object(out)
        let before = try object(text)
        for key in ["a", "b", "c", "d", "big", "p", "n", "s", "neg"] {
            #expect(after[key] as? NSObject == before[key] as? NSObject, "\(key)")
        }
        #expect(out.contains("\"c\" : true"))
        #expect(out.contains("\"d\" : false"))
        #expect(out.contains("9007199254740993"))
        #expect(out.contains("\"p\" : 0.1"))
        #expect(out.contains("a/b é"))
        #expect((after["e"] as? NSNumber)?.doubleValue == 1000)
    }

    @Test func installTwiceIsTheSame() throws {
        for x in [nil, others, "{}"] as [String?] {
            let once = try install(x)
            #expect(try install(once) == once)
        }
    }

    @Test func installWhenAlreadyThereKeepsTheOrderOfOthers() throws {
        let once = try install(others)
        // Someone else adds a Stop hook after ours.
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(once.utf8)) as? [String: Any])
        var hooks = try #require(obj["hooks"] as? [String: Any])
        var stop = try #require(hooks["Stop"] as? [Any])
        stop.append(["hooks": [["type": "command", "command": "later"]]])
        hooks["Stop"] = stop
        obj["hooks"] = hooks
        let edited = String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
        let again = try install(edited)
        #expect(try object(again) == object(edited))
    }

    @Test func installRepointsAnotherCopy() throws {
        let a = "/A/singularity-hook", b = "/B/singularity-hook"
        let out = try install(others, a)
        #expect(ClaudeHookSettings.status(settingsText: out, helper: b, timeoutSeconds: 3600) == .otherCopy(a))
        let fixed = try install(out, b)
        #expect(ClaudeHookSettings.status(settingsText: fixed, helper: b, timeoutSeconds: 3600) == .installed)
        #expect(!fixed.contains("/A/"))
        #expect(fixed.components(separatedBy: "singularity-hook").count == 4)
    }

    @Test func timeoutChangeIsApplied() throws {
        let out = try install(nil, timeout: 3600)
        let changed = try install(out, timeout: 600)
        #expect(changed.contains("600"))
        #expect(!changed.contains("3600"))
        #expect(changed.components(separatedBy: "singularity-hook").count == 4)
    }

    @Test func ourHookNextToSomeoneElsesIsReplacedAlone() throws {
        let text = """
        {"hooks":{"Stop":[{"hooks":[
          {"type":"command","command":"'/A/singularity-hook'","timeout":10},
          {"type":"command","command":"theirs","extra":true}
        ],"note":"keep"}]}}
        """
        let out = try install(text, "/B/singularity-hook")
        let stop = try #require(((try object(out)["hooks"] as? NSDictionary)?["Stop"]) as? [NSDictionary])
        let commands = stop.flatMap { ($0["hooks"] as? [NSDictionary]) ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.sorted() == ["'/B/singularity-hook' 2>/dev/null || cat >/dev/null", "theirs"])
        #expect(stop.contains { $0["note"] as? String == "keep" })
        let removed = try ClaudeHookSettings.remove(settingsText: out)
        let left = try #require(((try object(removed)["hooks"] as? NSDictionary)?["Stop"]) as? [NSDictionary])
        #expect(left.count == 1)
        #expect(left[0]["note"] as? String == "keep")
        #expect((left[0]["hooks"] as? [NSDictionary])?.count == 1)
        #expect((left[0]["hooks"] as? [NSDictionary])?[0]["extra"] as? Bool == true)
    }

    @Test func removeRestoresTheRest() throws {
        for x in [others, #"{"model":"opus"}"#, "{}"] {
            let removed = try ClaudeHookSettings.remove(settingsText: try install(x))
            #expect(try object(removed) == object(x))
        }
        let plain = "{ \"model\":   \"x\" ,\n \"hooks\": {\"Stop\": []} }\n"
        #expect(try ClaudeHookSettings.remove(settingsText: plain) == plain)
    }

    @Test func removeDropsEmptiedContainers() throws {
        let removed = try ClaudeHookSettings.remove(settingsText: try install(nil))
        #expect(try object(removed).count == 0)
    }

    @Test func removeFindsAnyHelperPath() throws {
        let out = try install(others, "/Somewhere Else/singularity-hook")
        let removed = try ClaudeHookSettings.remove(settingsText: out)
        #expect(!removed.contains("singularity-hook"))
        #expect(try object(removed) == object(others))
    }

    @Test(arguments: [
        "{ // comment\n}", "[]", "\"x\"", "{\"a\":1,}", "{\"a\":1,\"a\":2}", "not json",
        "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}", "{\"hooks\": {\"Other\": \"x\"}}",
        "{\"hooks\": {\"Stop\": [1]}}", "{\"hooks\": {\"Stop\": [{\"hooks\": {}}]}}",
        "{\"hooks\": {\"Stop\": [{\"hooks\": [\"x\"]}]}}", "{\"hooks\": \"x\"}", "{\"hooks\": null}",
    ])
    func unreadableIsRefused(text: String) {
        #expect(ClaudeHookSettings.status(settingsText: text, helper: helper, timeoutSeconds: 3600) == .unreadable)
        #expect(throws: ClaudeHookSettings.Unreadable.self) { try install(text) }
        #expect(throws: ClaudeHookSettings.Unreadable.self) { try ClaudeHookSettings.remove(settingsText: text) }
    }

    @Test func unknownKeysAreFine() throws {
        let text = #"{"hooks":{"Notification":[{"x":1,"hooks":[{"type":"http","url":"u"}]}]}}"#
        let out = try install(text)
        let hooks = try #require(try object(out)["hooks"] as? NSDictionary)
        let expected = (try object(text)["hooks"] as? NSDictionary)?["Notification"] as? [NSDictionary]
        #expect(hooks["Notification"] as? [NSDictionary] == expected)
    }

    @Test func pathWithSpacesAndQuotes() throws {
        let out = try install(nil, odd)
        #expect(ClaudeHookSettings.status(settingsText: out, helper: odd, timeoutSeconds: 3600) == .installed)
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 3600) == .otherCopy(odd))
        // The exact command, quoted the way `AgentConnect.shellQuote` quotes.
        let command = #"'/Users/o'\''neil/My Apps/Singularity.app/Contents/MacOS/singularity-hook' 2>/dev/null || cat >/dev/null"#
        #expect(ClaudeHookSettings.command(helper: odd) == command)
        let commands = try hookCommands(out)
        #expect(commands == [command, command, command])
        #expect(try install(out, odd) == out)
        // Written the old way (bare quoted path): ours, not current.
        let old = out.replacingOccurrences(of: Self.guardText, with: "")
        #expect(old != out)
        #expect(ClaudeHookSettings.status(settingsText: old, helper: odd, timeoutSeconds: 3600) == .notInstalled)
        #expect(try install(old, odd) == out)
    }

    // MARK: The guarded command (a missing helper must stay invisible)

    static let guardText = " 2>/dev/null || cat >/dev/null"

    /// Every hook command in the text, events sorted by name.
    func hookCommands(_ text: String) throws -> [String] {
        let hooks = try #require(try object(text)["hooks"] as? NSDictionary)
        return (hooks.allKeys as? [String] ?? []).sorted().flatMap { name in
            ((hooks[name] as? [NSDictionary]) ?? []).flatMap { ($0["hooks"] as? [NSDictionary]) ?? [] }
                .compactMap { $0["command"] as? String }
        }
    }

    @Test func installWritesTheGuardedCommand() throws {
        #expect(ClaudeHookSettings.command(helper: helper) == "'\(helper)' 2>/dev/null || cat >/dev/null")
        let out = try install(others)
        let ours = try hookCommands(out).filter { $0.contains("singularity-hook") }
        #expect(ours == Array(repeating: ClaudeHookSettings.command(helper: helper), count: 3))
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 3600) == .installed)
        // Byte for byte the same when installed again.
        #expect(try install(out) == out)
    }

    /// A hook of ours written before the guard (the bare quoted path) is recognised as ours but is
    /// not current: Install repairs it to one guarded entry per event.
    @Test func oldBareCommandIsRepaired() throws {
        let current = try install(others)
        let old = current.replacingOccurrences(of: Self.guardText, with: "")
        #expect(old != current)
        #expect(try hookCommands(old).filter { $0.contains("singularity-hook") } == Array(repeating: "'\(helper)'", count: 3))
        #expect(ClaudeHookSettings.status(settingsText: old, helper: helper, timeoutSeconds: 3600) == .notInstalled)
        let repaired = try install(old)
        #expect(repaired == current)
        #expect(try hookCommands(repaired).filter { $0.contains("singularity-hook") }
                == Array(repeating: ClaudeHookSettings.command(helper: helper), count: 3))
        #expect(ClaudeHookSettings.status(settingsText: repaired, helper: helper, timeoutSeconds: 3600) == .installed)
        // The old form pointing at another copy is still that other copy.
        let elsewhere = old.replacingOccurrences(of: helper, with: "/Other/singularity-hook")
        #expect(ClaudeHookSettings.status(settingsText: elsewhere, helper: helper, timeoutSeconds: 3600)
                == .otherCopy("/Other/singularity-hook"))
    }

    @Test func removeTakesOutBothForms() throws {
        let text = """
        {"hooks":{
          "Stop":[{"hooks":[{"type":"command","command":"'/A/singularity-hook'","timeout":10},{"type":"command","command":"theirs"}]}],
          "PermissionRequest":[{"hooks":[{"type":"command","command":"'/B/singularity-hook' 2>/dev/null || cat >/dev/null","timeout":3600}]}],
          "PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"'\(helper)' 2>/dev/null || cat >/dev/null","timeout":3600}]}]
        }}
        """
        let removed = try ClaudeHookSettings.remove(settingsText: text)
        #expect(!removed.contains("singularity-hook"))
        #expect(try hookCommands(removed) == ["theirs"])
    }

    @Test func partialInstallIsNotInstalled() throws {
        let partial = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'\#(helper)'","timeout":10}]}]}}"#
        #expect(ClaudeHookSettings.status(settingsText: partial, helper: helper, timeoutSeconds: 3600) == .notInstalled)
        let fixed = try install(partial)
        #expect(ClaudeHookSettings.status(settingsText: fixed, helper: helper, timeoutSeconds: 3600) == .installed)
        #expect(fixed.components(separatedBy: "singularity-hook").count == 4)
        #expect(ClaudeHookSettings.status(settingsText: nil, helper: helper, timeoutSeconds: 3600) == .notInstalled)
        #expect(ClaudeHookSettings.status(settingsText: "{}", helper: helper, timeoutSeconds: 3600) == .notInstalled)
    }

    @Test func otherPeoplesHooksAreNotOurs() {
        let text = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/singularity-hook-other"},{"type":"prompt","command":"/x/singularity-hook"}]}]}}"#
        #expect(ClaudeHookSettings.status(settingsText: text, helper: helper, timeoutSeconds: 3600) == .notInstalled)
    }

    @Test func staleTimeoutIsNotInstalled() throws {
        let out = try install(nil, timeout: 600)
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 600) == .installed)
        #expect(ClaudeHookSettings.status(settingsText: out, helper: helper, timeoutSeconds: 3600) == .notInstalled)
    }

    @Test func wrongMatcherIsNotInstalled() throws {
        let out = try install(nil)
        let wrong = out.replacingOccurrences(of: "\"matcher\" : \"AskUserQuestion\"", with: "\"matcher\" : \"Bash\"")
        #expect(wrong != out)
        #expect(ClaudeHookSettings.status(settingsText: wrong, helper: helper, timeoutSeconds: 3600) == .notInstalled)
        let fixed = try install(wrong)
        #expect(ClaudeHookSettings.status(settingsText: fixed, helper: helper, timeoutSeconds: 3600) == .installed)
        #expect(fixed.components(separatedBy: "singularity-hook").count == 4)
        // A matcher on a hook that should have none.
        let extra = #"{"hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"'\#(helper)'","timeout":3600}]}]}}"#
        #expect(ClaudeHookSettings.status(settingsText: extra, helper: helper, timeoutSeconds: 3600) == .notInstalled)
    }

    @Test func doubleQuotedCommandIsOurs() throws {
        let text = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/A b/singularity-hook\"","timeout":10}]}]}}"#
        #expect(ClaudeHookSettings.status(settingsText: text, helper: helper, timeoutSeconds: 3600) == .otherCopy("/A b/singularity-hook"))
        let out = try install(text)
        #expect(out.components(separatedBy: "singularity-hook").count == 4)
        #expect(!out.contains("/A b/"))
        let removed = try ClaudeHookSettings.remove(settingsText: text)
        #expect(!removed.contains("singularity-hook"))
        #expect(ClaudeHookSettings.unquote(#""a \"q\" \$ \\ b""#) == #"a "q" $ \ b"#)
        #expect(ClaudeHookSettings.unquote(#""a\nb""#) == #"a\nb"#)
    }

    @Test func oldEntriesUnderOtherEventsAreCleared() throws {
        let text = #"{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"'/A/singularity-hook'"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"theirs"},{"type":"command","command":"'/A/singularity-hook'"}]}]}}"#
        let out = try install(text)
        let hooks = try #require(try object(out)["hooks"] as? NSDictionary)
        #expect(hooks["Notification"] == nil)
        let end = try #require(hooks["SessionEnd"] as? [NSDictionary])
        #expect((end[0]["hooks"] as? [NSDictionary])?.count == 1)
        #expect(out.components(separatedBy: "singularity-hook").count == 4)
        #expect(ClaudeHookSettings.status(settingsText: text, helper: "/A/singularity-hook", timeoutSeconds: 3600) == .notInstalled)
    }

    /// What really changes when the file is written out again (the claims in the source comment).
    @Test func respelledValues() throws {
        let text = #"{"big":18446744073709551616,"huge":123456789012345678901234567890.5,"pi":3.141592653589793,"e":1e3,"z":-0,"one":1.0,"s":"a\/b é","big2":1e100}"#
        let out = try install(text)
        #expect(out.contains("18446744073709551616"))
        #expect(out.contains("123456789012345678901234567890.5"))
        #expect(out.contains("\"e\" : 1000"))
        #expect(out.contains("\"one\" : 1,") || out.contains("\"one\" : 1\n"))
        #expect(out.contains("a/b é"))
        #expect(out.contains("\"pi\" : 3.1415926535897931"))
        #expect(out.contains("\"big2\" : 1e+100"))
        #expect(out.contains("\"z\" : 0"))
    }

    @Test func fileLocation() {
        #expect(ClaudeHookSettings.file(home: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/.claude/settings.json")
    }
}
