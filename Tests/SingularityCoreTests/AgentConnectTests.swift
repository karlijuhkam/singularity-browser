import Foundation
import Testing
@testable import SingularityCore

@Suite struct AgentConnectTests {
    let launcher = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp"

    @Test func titlesAndPrograms() {
        #expect(AgentKind.claudeCode.title == "Claude Code")
        #expect(AgentKind.codex.title == "Codex")
        #expect(AgentKind.claudeCode.program == "claude")
        #expect(AgentKind.codex.program == "codex")
        #expect(AgentKind.allCases == [.claudeCode, .codex])
    }

    @Test func shellQuote() {
        #expect(AgentConnect.shellQuote("/Applications/Singularity.app/x") == "'/Applications/Singularity.app/x'")
        #expect(AgentConnect.shellQuote("/A p/it's") == "'/A p/it'\\''s'")
    }

    @Test func commands() {
        let spaced = "/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp"
        #expect(AgentConnect.addCommand(.claudeCode, launcher: spaced)
            == "claude mcp add -s user singularity -- '/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp'")
        #expect(AgentConnect.addCommand(.codex, launcher: spaced)
            == "codex mcp add singularity -- '/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp'")
        #expect(AgentConnect.removeCommand(.claudeCode) == "claude mcp remove -s user singularity")
        #expect(AgentConnect.removeCommand(.codex) == "codex mcp remove singularity")
        #expect(AgentConnect.findCommand(.codex) == "command -v codex")
        #expect(AgentConnect.findCommand(.claudeCode) == "command -v claude")
    }

    @Test func translocation() {
        #expect(AgentConnect.isTranslocated(
            "/private/var/folders/ab/T/AppTranslocation/1234/d/Singularity.app/Contents/MacOS/singularity-mcp"))
        #expect(!AgentConnect.isTranslocated(launcher))
    }

    @Test func configFiles() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(AgentConnect.configFile(.claudeCode, home: home).path == "/Users/someone/.claude.json")
        #expect(AgentConnect.configFile(.codex, home: home).path == "/Users/someone/.codex/config.toml")
    }

    // MARK: Claude Code (~/.claude.json)

    @Test func claudeUserEntry() {
        let text = """
        {"numStartups": 3,
         "mcpServers": {"singularity": {"type": "stdio", "command": "/Applications/Singularity.app/Contents/MacOS/singularity-mcp", "args": [], "env": {}}},
         "projects": {"/Users/someone/x": {"mcpServers": {"singularity": {"command": "/elsewhere"}}}}}
        """
        #expect(AgentConnect.registeredLauncher(.claudeCode, configText: text) == launcher)
    }

    @Test func claudeProjectEntryIsIgnored() {
        let text = #"{"projects": {"/Users/someone/x": {"mcpServers": {"singularity": {"command": "/elsewhere"}}}}}"#
        #expect(AgentConnect.registeredLauncher(.claudeCode, configText: text) == nil)
    }

    @Test func claudeUnexpectedTextIsNil() {
        let texts = [
            "", "{", "[]",
            #"{"mcpServers":{"other":{"command":"x"}}}"#,
            #"{"mcpServers":{"singularity":{"type":"http","url":"u"}}}"#,
        ]
        for text in texts {
            #expect(AgentConnect.registeredLauncher(.claudeCode, configText: text) == nil, "\(text)")
        }
    }

    // MARK: Codex (~/.codex/config.toml)

    @Test func codexTableDoubleQuotes() {
        let text = """
        model = "gpt-5"

        [mcp_servers.singularity]
        command = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp"
        args = []
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: text) == launcher)
    }

    @Test func codexTableEscapes() {
        let text = """
        [mcp_servers.singularity]
        command = "/A \\"q\\"/back\\\\slash"
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: text) == #"/A "q"/back\slash"#)
    }

    @Test func codexTableSingleQuotes() {
        let text = """
        [mcp_servers."singularity"]
        command = '/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp'
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: text)
            == "/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp")
    }

    @Test func codexCommentAndAnotherServerFirst() {
        let text = """
        # my servers
        [mcp_servers.other]
        command = "/usr/local/bin/other"

        [mcp_servers.singularity]
        # added by Singularity
        command = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp"

        [mcp_servers.singularity.env]
        X = "1"
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: text) == launcher)
    }

    @Test func codexInlineForm() {
        let text = """
        [mcp_servers]
        other = { command = "/usr/local/bin/other" }
        singularity = { command = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp", args = [] }
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: text) == launcher)
        // "command" inside another value's string is not the key.
        let tricky = """
        [mcp_servers]
        singularity = { args = ["command = 'no'", "{x}"], env = { A = "1" }, command = "/real/singularity-mcp" }
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: tricky) == "/real/singularity-mcp")
    }

    @Test func codexNoEntryIsNil() {
        let onlyOther = """
        [mcp_servers.other]
        command = "/usr/local/bin/other"
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: onlyOther) == nil)
        #expect(AgentConnect.registeredLauncher(.codex, configText: "") == nil)
        let commandUnderLaterTable = """
        [mcp_servers.singularity]
        args = []

        [mcp_servers.other]
        command = "/usr/local/bin/other"
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: commandUnderLaterTable) == nil)
        let arrayOfTables = """
        [[mcp_servers.singularity]]
        command = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp"
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: arrayOfTables) == nil)
        let emptyCommand = """
        [mcp_servers.singularity]
        command = ""
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: emptyCommand) == nil)
    }

    @Test func codexQuotedInlineKey() {
        let text = """
        [mcp_servers]
        "singularity" = { command = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp" }
        """
        #expect(AgentConnect.registeredLauncher(.codex, configText: text) == launcher)
    }

    /// A damaged inline table must read as "no entry", never hang.
    @Test func codexDamagedInlineTableIsNil() {
        let damaged = [
            "[mcp_servers]\nsingularity = { ] }",
            "[mcp_servers]\nsingularity = { a = 1 ] }",
            "[mcp_servers]\nsingularity = { a = \"open",
            "[mcp_servers]\nsingularity = { a = 1, ",
            "[mcp_servers]\nsingularity = { = }",
        ]
        for text in damaged {
            #expect(AgentConnect.registeredLauncher(.codex, configText: text) == nil, "\(text)")
        }
    }

    // MARK: Status

    @Test func status() {
        let translocated = "/private/var/folders/ab/T/AppTranslocation/1234/d/Singularity.app/Contents/MacOS/singularity-mcp"
        #expect(AgentConnect.status(installed: true, registered: translocated, launcher: translocated) == .translocated)
        #expect(AgentConnect.status(installed: false, registered: nil, launcher: launcher) == .notInstalled)
        #expect(AgentConnect.status(installed: true, registered: nil, launcher: launcher) == .notConnected)
        #expect(AgentConnect.status(installed: true, registered: launcher, launcher: launcher) == .connected)
        #expect(AgentConnect.status(installed: true, registered: "/other/singularity-mcp", launcher: launcher)
            == .otherCopy("/other/singularity-mcp"))
        #expect(AgentConnect.status(installed: false, registered: launcher, launcher: launcher) == .connected)
        #expect(AgentConnect.status(
            installed: true,
            registered: "/Applications/./Singularity.app/Contents/MacOS/singularity-mcp",
            launcher: launcher) == .connected)
    }
}
