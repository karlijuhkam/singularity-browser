import Foundation
import Testing
@testable import SingularityCore

@Suite struct TerminalModelTests {
    @Test func terminalKindRoundTripsAndOldJSONStillDecodes() throws {
        let tab = BrowserTab.terminal(workingDirectory: "~/Developer")
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)
        #expect(decoded.workingDirectory == "~/Developer")
        #expect(decoded.url == nil)
        #expect(decoded.displayTitle == "Terminal")

        // A web tab written by Phase 1 must still load.
        let phase1 = #"{"id":"10000000-0000-0000-0000-000000000001","kind":{"web":{"url":"https://example.com/"}},"title":"","isPinned":false}"#
        let web = try JSONDecoder().decode(BrowserTab.self, from: Data(phase1.utf8))
        #expect(web.url == URL(string: "https://example.com/"))
        #expect(!web.isTerminal)
    }

    @Test func homePaths() {
        #expect(HomePath.expand("~", home: "/Users/k") == "/Users/k")
        #expect(HomePath.expand("~/Developer", home: "/Users/k") == "/Users/k/Developer")
        #expect(HomePath.expand("/tmp", home: "/Users/k") == "/tmp")
        #expect(HomePath.abbreviate("/Users/k", home: "/Users/k") == "~")
        #expect(HomePath.abbreviate("/Users/k/Developer", home: "/Users/k") == "~/Developer")
        #expect(HomePath.abbreviate("/Users/kx", home: "/Users/k") == "/Users/kx")
    }
}

@Suite struct TerminalTitleTests {
    let home = "/Users/k"

    @Test func atThePromptShowsTheDirectory() {
        let title = TerminalTitle.make(foregroundProgram: "zsh", isShellInForeground: true, programTitle: "stale title",
                                       directory: "/Users/k/Developer/app", home: home)
        #expect(title == "~/Developer/app")
    }

    @Test func runningProgramPrefersItsOwnTitle() {
        let title = TerminalTitle.make(foregroundProgram: "claude", isShellInForeground: false, programTitle: "✳ Fix the bug",
                                       directory: "/Users/k/Developer/app", home: home)
        #expect(title == "✳ Fix the bug")
    }

    @Test func runningProgramWithoutTitleShowsNameAndFolder() {
        #expect(TerminalTitle.make(foregroundProgram: "vim", isShellInForeground: false, programTitle: nil,
                                   directory: "/Users/k/Developer/app", home: home) == "vim · app")
        #expect(TerminalTitle.make(foregroundProgram: "top", isShellInForeground: false, programTitle: "  ",
                                   directory: home, home: home) == "top")
    }
}

@Suite struct ProcessInspectorTests {
    @Test func readsOurOwnProcess() throws {
        let pid = getpid()
        let arguments = try #require(ProcessInspector.arguments(pid: pid))
        #expect(arguments == CommandLine.arguments)
        #expect(ProcessInspector.programName(pid: pid) == (CommandLine.arguments[0] as NSString).lastPathComponent)
        // Compare resolved paths: /tmp vs /private/tmp and similar symlinks.
        let cwd = try #require(ProcessInspector.currentDirectory(pid: pid))
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() ==
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath())
    }

    @Test func unknownProcessReturnsNil() {
        #expect(ProcessInspector.programName(pid: 999_999) == nil)
        #expect(ProcessInspector.currentDirectory(pid: 999_999) == nil)
    }
}

@Suite struct ForegroundProcessTests {
    /// Starts `sleep` on a fresh pseudo-terminal exactly the way SwiftTerm starts a shell
    /// (`forkpty`, which makes the PTY the child's controlling terminal), then checks that the PTY
    /// reports it as the foreground program, by its argv[0] name.
    @Test func reportsTheProgramRunningOnAPTY() throws {
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleepy-test"), strdup("5"), nil]
        defer { argv.forEach { free($0) } }

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, nil)
        if pid == 0 {
            // Child: only exec here; nothing else is safe after fork in a multithreaded process.
            execv("/bin/sleep", argv)
            _exit(127)
        }
        try #require(pid > 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            close(master)
        }

        // Give the child a moment to exec.
        var name: String?
        for _ in 0..<50 where name != "sleepy-test" {
            usleep(20_000)
            name = ProcessInspector.programName(pid: pid)
        }
        #expect(ProcessInspector.foregroundProcessGroup(ptyFileDescriptor: master) == pid)
        #expect(name == "sleepy-test")
    }
}

@Suite struct HerdrCoreTests {
    @Test func looksInTheUsualPlacesThenThePath() {
        let candidates = HerdrCore.candidatePaths(home: "/Users/x", path: "/usr/bin:/opt/homebrew/bin::/custom")
        #expect(candidates == ["/Users/x/.local/bin/hc", "/opt/homebrew/bin/hc", "/usr/local/bin/hc", "/usr/bin/hc", "/custom/hc"])
        #expect(HerdrCore.locate(home: "/Users/x", path: "/custom", isExecutable: { $0 == "/custom/hc" }) == "/custom/hc")
        #expect(HerdrCore.locate(home: "/Users/x", path: nil, isExecutable: { _ in false }) == nil)
    }

    @Test func namesAndArguments() {
        let tab = UUID(uuidString: "6916BFB3-AA44-4400-83E8-6735FE2E2030")!
        let name = HerdrCore.terminalName(tabID: tab)
        #expect(name == "sg-6916bfb3aa44440083e86735")
        #expect(name.count <= 32 && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
        let run = HerdrCore.runArguments(name: name, directory: "/tmp/x y", spaceSlug: "work", shell: "/bin/zsh")
        #expect(run.prefix(3) == ["run", "--bg", "--json"])
        #expect(run.contains("--no-parent"))
        #expect(run.suffix(5) == ["--", "/usr/bin/env", "SINGULARITY_SPACE=work", "/bin/zsh", "-l"])
        #expect(run[run.firstIndex(of: "--cwd")! + 1] == "/tmp/x y")
        #expect(HerdrCore.attachArguments(name: name).prefix(2) == ["attach", name])
        #expect(HerdrCore.parseVersion("hc 0.1.19\n") == "0.1.19")
        #expect(HerdrCore.parseVersion("zsh: command not found") == nil)
    }

    @Test func readsWhatHcSaysAboutATerminal() {
        // Real answers of hc 0.1.19, shortened.
        let live = #"{"address":"t1","argv":["/bin/zsh","-l"],"exit_code":null,"foreground":{"name":"zsh","pid":84684},"name":"sg-abc","pid":84684,"state":"live","title":""}"#
        #expect(HerdrCore.parseGet(live) == .found(.init(state: .live, pid: 84684, exitCode: nil)))
        let finished = #"{"address":"t1","exit_code":1,"pid":84684,"reason":"killed","state":"finished"}"#
        #expect(HerdrCore.parseGet(finished) == .found(.init(state: .finished, pid: 84684, exitCode: 1)))
        let missing = #"{"error":{"hint":"see `hc ls --all`","kind":"not_found","message":"no terminal \"nope\""}}"#
        #expect(HerdrCore.parseGet(missing) == .missing)
        let taken = #"{"error":{"kind":"name_taken","message":"a live terminal is already named \"sg-abc\""}}"#
        #expect(HerdrCore.parseGet(taken) == .unreadable("a live terminal is already named \"sg-abc\""))
        #expect(HerdrCore.errorMessage(taken) == "a live terminal is already named \"sg-abc\"")
        #expect(HerdrCore.parseGet("") == .unreadable("hc gave no JSON"))
        #expect(HerdrCore.parseGet(#"{"state":"parked","pid":0}"#) == .found(.init(state: .other("parked"), pid: nil, exitCode: nil)))
    }

    @Test func findsTheForegroundGroupByProcessID() {
        // This test process has a terminal or it doesn't; either way a nonsense pid has none.
        #expect(ProcessInspector.foregroundProcessGroup(ofTerminalOf: 0x7FFF_FFF0) == nil)
    }
}
