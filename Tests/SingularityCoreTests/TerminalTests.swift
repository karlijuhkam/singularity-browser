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

@Suite struct ProgramNameTests {
    @Test func aScriptIsCalledByItsOwnName() {
        // What the owner's Bot launcher really is: a shell script.
        #expect(ProcessInspector.programName(arguments: ["/bin/sh", "/Users/x/.local/bin/herdr-bot", "createdat"]) == "herdr-bot")
        #expect(ProcessInspector.programName(arguments: ["bash", "./deploy.sh", "--prod"]) == "deploy.sh")
        #expect(ProcessInspector.programName(arguments: ["/opt/homebrew/bin/python3.14", "collect.py"]) == "collect.py")
        #expect(ProcessInspector.programName(arguments: ["node", "/x/server.js"]) == "server.js")
        #expect(ProcessInspector.programName(arguments: ["sh", "herdr-bot"]) == "herdr-bot")
    }

    @Test func everythingElseKeepsItsName() {
        #expect(ProcessInspector.programName(arguments: ["/usr/local/bin/claude", "--resume"]) == "claude")
        #expect(ProcessInspector.programName(arguments: ["-zsh"]) == "zsh")
        #expect(ProcessInspector.programName(arguments: ["zsh", "-l"]) == "zsh")
        #expect(ProcessInspector.programName(arguments: ["sh", "-c", "sleep 5"]) == "sh")
        #expect(ProcessInspector.programName(arguments: ["python3", "-m", "http.server"]) == "python3")
        #expect(ProcessInspector.programName(arguments: ["python3"]) == "python3")
        // A sub-command is not a script.
        #expect(ProcessInspector.programName(arguments: ["bun", "run", "dev"]) == "bun")
        #expect(ProcessInspector.programName(arguments: ["deno", "test"]) == "deno")
        #expect(ProcessInspector.programName(arguments: ["node", "inspect"]) == "node")
        #expect(ProcessInspector.programName(arguments: ["vim", "notes.txt"]) == "vim")
        #expect(ProcessInspector.programName(arguments: ["shellcheck", "x.sh"]) == "shellcheck")
        #expect(ProcessInspector.programName(arguments: ["sh", ""]) == "sh")
        #expect(ProcessInspector.programName(arguments: []) == nil)
        #expect(ProcessInspector.programName(arguments: [""]) == nil)
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
        #expect(ProcessInspector.parentPID(of: 999_999) == nil)
    }

    /// The hook's check that a request comes from inside the tab's shell.
    @Test func descendantWalk() {
        // 50 → 40 → 30 → 20 → 1 (launchd); 70 → 60 → 1; 90 ↔ 91 (a broken table, a loop).
        let table: [pid_t: pid_t] = [50: 40, 40: 30, 30: 20, 20: 1, 70: 60, 60: 1, 90: 91, 91: 90]
        func parent(_ pid: pid_t) -> pid_t? { table[pid] }
        #expect(ProcessInspector.isDescendant(50, of: 30, parent: parent))
        #expect(ProcessInspector.isDescendant(50, of: 20, parent: parent))
        #expect(ProcessInspector.isDescendant(30, of: 30, parent: parent))       // the shell itself
        #expect(!ProcessInspector.isDescendant(70, of: 30, parent: parent))      // another terminal
        #expect(!ProcessInspector.isDescendant(20, of: 50, parent: parent))      // an ancestor is no descendant
        #expect(!ProcessInspector.isDescendant(50, of: 1, parent: parent))       // launchd is everyone's
        #expect(!ProcessInspector.isDescendant(90, of: 30, parent: parent))      // loop: ends, "no"
        #expect(!ProcessInspector.isDescendant(80, of: 30, parent: parent))      // unknown process
        #expect(!ProcessInspector.isDescendant(0, of: 30, parent: parent))
        #expect(!ProcessInspector.isDescendant(-5, of: 30, parent: parent))
        // Depth limit: a chain longer than maxDepth counts as "no".
        func long(_ pid: pid_t) -> pid_t? { pid > 1000 ? pid - 1 : nil }
        #expect(ProcessInspector.isDescendant(1010, of: 1000, maxDepth: 10, parent: long))
        #expect(!ProcessInspector.isDescendant(1011, of: 1000, maxDepth: 10, parent: long))
        // The real table: this test process is its parent's descendant, not the other way round.
        #expect(ProcessInspector.parentPID(of: getpid()) == getppid())
        #expect(ProcessInspector.isDescendant(getpid(), of: getppid()))
        #expect(!ProcessInspector.isDescendant(getppid(), of: getpid()))
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
        let run = HerdrCore.runArguments(name: name, directory: "/tmp/x y", spaceSlug: "work", tabID: tab,
                                         hookSocket: "/Users/x/Singularity/.run/hook.sock", shell: "/bin/zsh")
        #expect(run.prefix(3) == ["run", "--bg", "--json"])
        #expect(run.contains("--no-parent"))
        // herdr-core starts the shell with its own environment: the Space, the tab id and the hook
        // socket travel through /usr/bin/env (the Claude Code hook helper reads the last two).
        #expect(run.suffix(7) == ["--", "/usr/bin/env", "SINGULARITY_SPACE=work",
                                  "SINGULARITY_TAB=6916BFB3-AA44-4400-83E8-6735FE2E2030",
                                  "SINGULARITY_HOOK_SOCKET=/Users/x/Singularity/.run/hook.sock", "/bin/zsh", "-l"])
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

/// Cmd-clicking a path that ends a sentence ("…/draft.md.") in a terminal: SwiftTerm's detection
/// keeps the full stop, finds no such file and blocks the link.
@Suite struct TerminalLinkTargetTests {
    let dir = "/Users/k/project"
    let home = "/Users/k"
    let files: Set<String> = [
        "/Users/k/dev/notes/plat-326-ui-direction-draft.md",
        "/Users/k/project/README.md",
        "/Users/k/project/src/main.swift",
        "/Users/k/project/odd.",
        "/Users/k/todo.txt",
        "/Users/k/project/docs",
    ]
    func target(_ link: String, in directory: String? = "/Users/k/project") -> String? {
        TerminalLinkPath.target(link, in: directory, home: home, exists: { files.contains($0) })
    }

    @Test func aFullStopAfterAnAbsolutePathIsDropped() {
        #expect(target("/Users/k/dev/notes/plat-326-ui-direction-draft.md.")
            == "/Users/k/dev/notes/plat-326-ui-direction-draft.md")
        #expect(target("/Users/k/dev/notes/plat-326-ui-direction-draft.md.", in: nil)
            == "/Users/k/dev/notes/plat-326-ui-direction-draft.md")
    }

    @Test func severalClosingCharactersAreDropped() {
        #expect(target("/Users/k/project/README.md).") == "/Users/k/project/README.md")
        #expect(target("README.md\u{201D},") == "/Users/k/project/README.md")
        #expect(target("README.md`:") == "/Users/k/project/README.md")
        #expect(target("docs.)") == "/Users/k/project/docs")
    }

    @Test func aLocationSuffixKeepsItsNumbers() {
        #expect(target("src/main.swift:12.") == "/Users/k/project/src/main.swift:12")
        #expect(target("src/main.swift:12:4,") == "/Users/k/project/src/main.swift:12:4")
        #expect(target("/Users/k/project/src/main.swift:12") == nil)
    }

    @Test func aHomePathIsExpanded() {
        #expect(target("~/todo.txt.") == "/Users/k/todo.txt")
        #expect(target("~/todo.txt") == "/Users/k/todo.txt")
        #expect(target("~other/a.txt.") == nil)
    }

    @Test func aWordSwiftTermTookAfterThePathIsDropped() {
        #expect(target("/Users/k/dev/notes/plat-326-ui-direction-draft.md today.")
            == "/Users/k/dev/notes/plat-326-ui-direction-draft.md")
        #expect(target("/Users/k/todo.txt. Done.") == "/Users/k/todo.txt")
        #expect(target("README.md. e.g.") == "/Users/k/project/README.md")
        #expect(target("/nowhere/a.md today.") == nil)
    }

    @Test func anEllipsisNeverOpensTheParentFolder() {
        let dirs: Set<String> = ["/Users/k/dev", "/Users/k/dev/", "/Users/k", "/Users/k/dev/..", "/Users/k/dev/."]
        let t = { (link: String) in TerminalLinkPath.target(link, in: "/Users/k", home: "/Users/k", exists: { dirs.contains($0) }) }
        #expect(t("/Users/k/dev/...") == "/Users/k/dev/")
        #expect(t("dev/...") == "/Users/k/dev/")
        #expect(t("/Users/k/dev..") == "/Users/k/dev")
    }

    @Test func aFileWhoseNameEndsInPunctuationKeepsIt() {
        #expect(target("odd.") == "/Users/k/project/odd.")
    }

    @Test func anExistingAbsolutePathIsLeftAlone() {
        #expect(target("/Users/k/project/README.md") == nil)
    }

    @Test func withNoFileAnywhereTheLinkStaysAsItWas() {
        #expect(target("/nowhere/a.md.") == nil)
        #expect(target("missing.md.") == "/Users/k/project/missing.md.")
        #expect(target("missing.md.", in: nil) == nil)
        #expect(target(".") == "/Users/k/project/.")
    }

    @Test func urlsAreLeftAlone() {
        #expect(target("https://example.com/a.") == nil)
        #expect(target("mailto:a@b.ee.") == nil)
    }
}

/// Cmd-clicking a relative path in a terminal (e.g. one Claude Code printed). Our shells send no
/// OSC 7, so SwiftTerm would look for the file in the app's own folder (`/`) and block the link.
@Suite struct TerminalLinkPathTests {
    let dir = "/Users/k/project"

    @Test func aRelativePathIsJoinedToTheDirectory() {
        #expect(TerminalLinkPath.absolute("leads/wp/2026-11.csv", in: dir) == "/Users/k/project/leads/wp/2026-11.csv")
        #expect(TerminalLinkPath.absolute("./a.txt", in: dir) == "/Users/k/project/./a.txt")
        #expect(TerminalLinkPath.absolute("../b.txt", in: dir) == "/Users/k/project/../b.txt")
        #expect(TerminalLinkPath.absolute("README.md", in: dir) == "/Users/k/project/README.md")
    }

    @Test func aLocationSuffixStaysForSwiftTermToHandle() {
        #expect(TerminalLinkPath.absolute("main.swift:12", in: dir) == "/Users/k/project/main.swift:12")
        #expect(TerminalLinkPath.absolute("src/main.swift:12:4", in: dir) == "/Users/k/project/src/main.swift:12:4")
    }

    @Test func absolutePathsHomePathsAndURLsAreLeftAlone() {
        #expect(TerminalLinkPath.absolute("/etc/hosts", in: dir) == nil)
        #expect(TerminalLinkPath.absolute("~/notes.md", in: dir) == nil)
        #expect(TerminalLinkPath.absolute("https://example.com/a", in: dir) == nil)
        #expect(TerminalLinkPath.absolute("file:///tmp/a", in: dir) == nil)
        #expect(TerminalLinkPath.absolute("mailto:a@b.ee", in: dir) == nil)
        #expect(TerminalLinkPath.absolute("tel:5551234", in: dir) == nil)
    }

    @Test func noDirectoryOrNoLinkChangesNothing() {
        #expect(TerminalLinkPath.absolute("a.txt", in: nil) == nil)
        #expect(TerminalLinkPath.absolute("a.txt", in: "") == nil)
        #expect(TerminalLinkPath.absolute("a.txt", in: "relative/dir") == nil)
        #expect(TerminalLinkPath.absolute("", in: dir) == nil)
    }
}
