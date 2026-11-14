import Darwin
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// Claude Code's questions and permission requests held in the inbox (level 2): the hook helper
/// relays a hook call over the app's socket, the app holds it as an entry, and every held request
/// gets exactly one reply: the answer, or "no decision" (empty) whenever the terminal's own prompt
/// serves the owner better.
///
/// Most tests use a fake connection (`FakeConnection`) that records replies. The last group runs
/// the real `singularity-hook` binary against the real socket listener.
@MainActor
@Suite(.serialized) struct HeldRequestTests {
    /// Records what the app replied. A real `HookConnection` ignores a second reply; this one
    /// keeps every call, so the tests can see that the app replies exactly once.
    final class FakeConnection: HookReplying, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        private var ackCount = 0
        var onClosedByPeer: (@Sendable () -> Void)?
        /// This test process by default, which the fixture names as the tab's shell.
        let peerPID: pid_t?

        init(peerPID: pid_t? = getpid()) {
            self.peerPID = peerPID
        }

        var replies: [Data] { lock.withLock { stored } }
        var acks: Int { lock.withLock { ackCount } }

        func acknowledge() {
            lock.withLock { ackCount += 1 }
        }

        func reply(_ data: Data) {
            lock.withLock { stored.append(data) }
        }

        /// As if Claude Code killed the helper (Esc, Ctrl-C, quit).
        func closeFromPeer() {
            onClosedByPeer?()
        }
    }

    @MainActor final class Recorder {
        var arrivals: [InboxEntry] = []
        /// Added to the real time the inbox sees, so a test can step past the answer lockout.
        var skew: TimeInterval = 0
    }

    /// Two Spaces, "one" (selected) and "two". "two" holds the agent's tab. As in
    /// `InboxCenterTests`, a web tab on about:blank stands in for the terminal: the inbox only
    /// sees ids, and a real terminal would start the owner's login shell.
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let one: Space
        let two: Space
        let tab: BrowserTab
        let recorder: Recorder
        var center: InboxCenter { state.inbox }

        func passTheLockout() {
            recorder.skew += InboxCenter.answerLockout + 0.1
        }

        /// Held entries (questions and permissions) now in the inbox.
        var held: [InboxEntry] { center.inbox.visible.filter(\.isHeld) }

        @discardableResult
        func arrive(_ json: String, connection: FakeConnection = FakeConnection(), tabID: UUID? = nil) -> FakeConnection {
            center.hookArrived(tabID: tabID ?? tab.id, hookInput: Data(json.utf8), connection: connection)
            return connection
        }

        func status(_ state: ProgramState, _ message: String = "") {
            center.terminalSignal(.status([StatusRecord(id: "", state: state, kind: nil, app: "claude-code", message: message)]),
                                  tabID: tab.id, spaceID: two.id, foregroundProgram: "claude")
        }
    }

    private func makeFixture(selecting selected: String = "one") throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        let blank = URL(string: "about:blank")!
        let oneTab = BrowserTab.web(blank, title: "page")
        let tab = BrowserTab.web(blank, title: "claude")
        let one = Space(name: "one", slug: "one", colorHex: "#5E81F4", tabs: [oneTab], selectedTabID: oneTab.id)
        let two = Space(name: "two", slug: "two", colorHex: "#F45E81", tabs: [tab], selectedTabID: tab.id)
        try store.save(one)
        try store.save(two)
        try store.save(AppStateFile(spaceOrder: [one.id, two.id], selectedSpaceID: selected == "two" ? two.id : one.id))

        let state = TestAppState.make(root: root)
        let recorder = Recorder()
        state.inbox.appIsActive = { true }
        state.inbox.windowIsKey = { true }
        state.inbox.now = { Date().addingTimeInterval(recorder.skew) }
        state.inbox.onArrival = { recorder.arrivals.append($0) }
        state.inbox.onChange = {}
        state.inbox.requestAttention = {}
        // The tab's "shell" is this test process: the fake connections say they come from it, and
        // the real helper the tests start is its child, so both count as inside the tab.
        state.inbox.tabShellPID = { _ in getpid() }
        return Fixture(root: root, state: state, one: one, two: two, tab: tab, recorder: recorder)
    }

    private func tearDown(_ f: Fixture) {
        f.center.handBackAllHeld()
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    /// Showing the agent's tab made a web view with Space two's website data store: remove it
    /// again (WebKit refuses while the view is still alive).
    private func forgetWebsiteData(_ f: Fixture) async {
        f.state.web.removeControllers(for: [f.tab.id])
        try? await Task.sleep(for: .seconds(1))
        try? await WKWebsiteDataStore.remove(forIdentifier: f.two.id)
    }

    // MARK: Hook input (shapes from the spec's "As tested")

    /// Task 7's question.
    static let questionJSON = """
    {"session_id":"f32c","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[{"question":"Which database should we use?","header":"Database",
       "options":[{"label":"SQLite","description":"File-based"},{"label":"Postgres","description":"Server"}],
       "multiSelect":false}]},"tool_use_id":"toolu_01"}
    """
    static let question = "Which database should we use?"

    static let twoQuestionsJSON = """
    {"session_id":"f32c","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[
       {"question":"Which database should we use?","header":"Database",
        "options":[{"label":"SQLite"},{"label":"Postgres"}],"multiSelect":false},
       {"question":"Which features should we enable?","header":"Features",
        "options":[{"label":"Auth"},{"label":"Search"},{"label":"Billing"}],"multiSelect":true}]},
     "tool_use_id":"toolu_02"}
    """

    static func permissionJSON(_ command: String = "rm made-by-claude-1.txt") -> String {
        """
        {"session_id":"f32c","hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"\(command)","description":"Remove a file"}}
        """
    }

    /// A Write whose input is too long to show in full (`content` sorts before `file_path`).
    static func writeJSON(contentLength: Int) -> String {
        """
        {"session_id":"f32c","hook_event_name":"PermissionRequest","tool_name":"Write",
         "tool_input":{"content":"\(String(repeating: "a", count: contentLength))","file_path":"/Users/me/project/notes.md"}}
        """
    }

    static let askPermissionJSON = """
    {"session_id":"f32c","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[{"question":"Which database should we use?","options":[{"label":"SQLite"}]}]}}
    """

    static let stopJSON = """
    {"session_id":"f32c","hook_event_name":"Stop","stop_hook_active":false,
     "last_assistant_message":"You chose SQLite as the database. I haven't done anything else."}
    """

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// The `answers` of a PreToolUse reply.
    private static func answers(in reply: Data) -> [String: String]? {
        let output = json(reply)["hookSpecificOutput"] as? [String: Any]
        let input = output?["updatedInput"] as? [String: Any]
        return input?["answers"] as? [String: String]
    }

    // MARK: Required (brief, step 1)

    @Test func questionFromAnotherSpaceIsHeldAndAnswered() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        #expect(connection.replies.isEmpty)
        #expect(connection.acks == 1)
        let entry = try #require(f.held.first)
        #expect(f.held.count == 1)
        #expect(entry.kind == .question([InboxQuestion(question: Self.question, header: "Database",
                                                       options: ["SQLite", "Postgres"])]))
        #expect(entry.agent == "Claude Code")
        #expect(entry.tabID == f.tab.id && entry.spaceID == f.two.id)
        #expect(f.recorder.arrivals.map(\.id) == [entry.id])

        f.center.answerQuestion(entry.id, answers: [Self.question: ["SQLite"]])
        #expect(connection.replies.count == 1)
        let reply = try #require(connection.replies.first)
        #expect(Self.answers(in: reply) == [Self.question: "SQLite"])
        let output = Self.json(reply)["hookSpecificOutput"] as? [String: Any]
        #expect(output?["permissionDecision"] as? String == "allow")
        #expect(f.held.isEmpty)
    }

    @Test func questionForTheTabOnScreenIsNotHeld() throws {
        let f = try makeFixture(selecting: "two")
        defer { tearDown(f) }
        #expect(f.state.isTabOnScreen(f.tab.id))
        let connection = f.arrive(Self.questionJSON)
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.center.inbox.entries.isEmpty)
        #expect(f.recorder.arrivals.isEmpty)
    }

    @Test func goingToTheTerminalHandsItBack() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        #expect(f.held.count == 1)
        f.state.showTab(f.tab.id, in: f.two.id)
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.center.inbox.entries.isEmpty)
        await forgetWebsiteData(f)
    }

    @Test func holdLimitHandsItBackAndLeavesAWaitingEntry() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.holdLimit = .milliseconds(200)
        let connection = f.arrive(Self.questionJSON)
        let held = try #require(f.held.first)
        try await Task.sleep(for: .milliseconds(400))
        #expect(connection.replies == [ClaudeHook.noDecision])
        let waiting = try #require(f.center.inbox.visible.first)
        #expect(waiting.kind == .waiting(.question))
        #expect(waiting.tabID == f.tab.id && waiting.arrived == held.arrived)
        #expect(f.held.isEmpty)
        // The waiting entry holds no connection: going to the terminal now replies nothing more.
        f.center.wentToTerminal(f.tab.id)
        #expect(f.center.inbox.entries.isEmpty)
        #expect(connection.replies.count == 1)
    }

    @Test func peerClosingRemovesTheEntry() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        #expect(f.held.count == 1)
        connection.closeFromPeer()
        try await waitUntil("the entry to go") { f.held.isEmpty }
        #expect(connection.replies.isEmpty)
        #expect(f.center.inbox.entries.isEmpty)
    }

    @Test func permissionAllowAndDeny() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let allowed = f.arrive(Self.permissionJSON("rm a.txt"))
        let denied = f.arrive(Self.permissionJSON("rm b.txt"))
        #expect(f.held.count == 2)
        let entries = f.held
        #expect(entries[0].kind == .permission(tool: "Bash", input: "command: rm a.txt\ndescription: Remove a file", isComplete: true))
        #expect(entries[1].kind == .permission(tool: "Bash", input: "command: rm b.txt\ndescription: Remove a file", isComplete: true))

        f.center.decidePermission(entries[0].id, allow: true)
        #expect(allowed.replies == [ClaudeHook.permissionReply(allow: true)])
        #expect(denied.replies.isEmpty)
        f.center.decidePermission(entries[1].id, allow: false)
        #expect(denied.replies == [ClaudeHook.permissionReply(allow: false)])
        #expect(f.held.isEmpty)
        // A permission cannot be "answered" as a question, nor a question allowed.
        let permission = f.arrive(Self.permissionJSON())
        let question = f.arrive(Self.questionJSON)
        let ids = (permission: try #require(f.held.first { if case .permission = $0.kind { true } else { false } }).id,
                   question: try #require(f.held.first { if case .question = $0.kind { true } else { false } }).id)
        f.center.answerQuestion(ids.permission, answers: [Self.question: ["SQLite"]])
        f.center.decidePermission(ids.question, allow: true)
        #expect(permission.replies.isEmpty && question.replies.isEmpty)
        #expect(f.held.count == 2)
    }

    /// Claude Code's `blocked` status record and its PermissionRequest hook arrive together. Hook
    /// first: the status record's level-1 entry is hidden behind the held one, so it is not
    /// announced (one banner per request).
    @Test func heldFirstThenBlockedAnnouncesOnce() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.arrive(Self.permissionJSON())
        let held = try #require(f.held.first)
        f.center.terminalSignal(.status([StatusRecord(id: "", state: .blocked, kind: .permission, app: "claude-code",
                                                      message: "Claude needs your permission")]),
                                tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: "claude")
        #expect(f.center.inbox.entries.count == 2)
        #expect(f.center.inbox.visible.map(\.id) == [held.id])
        #expect(f.recorder.arrivals.map(\.id) == [held.id])
    }

    /// Status record first: its level-1 entry is announced, then the held one (two different
    /// entries; that order cannot be helped). The level-1 banner is withdrawn at once, because
    /// the notifier is synced with the visible entries, and the held one's banner stays.
    @Test func blockedFirstThenHeldWithdrawsTheHiddenBanner() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let backend = InboxNotifierTests.FakeBackend()
        let notifier = InboxNotifier(onOpen: {}, backend: backend)
        f.center.onArrival = { entry in
            f.recorder.arrivals.append(entry)
            notifier.post(entry, spaceName: "two")
        }
        f.center.onChange = { notifier.sync(with: f.center.inbox.visible) }

        f.center.terminalSignal(.status([StatusRecord(id: "", state: .blocked, kind: .permission, app: "claude-code",
                                                      message: "Claude needs your permission")]),
                                tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: "claude")
        let levelOne = try #require(f.center.inbox.visible.first)
        f.arrive(Self.permissionJSON())
        let held = try #require(f.held.first)
        await notifier.settle()
        #expect(f.recorder.arrivals.map(\.id) == [levelOne.id, held.id])
        #expect(backend.posted.map(\.id) == [levelOne.id.uuidString, held.id.uuidString])
        #expect(backend.removed == [levelOne.id.uuidString])
        #expect(backend.delivered == [held.id.uuidString])
    }

    /// The owner cannot see everything Allow would approve: Allow is refused even when called
    /// directly (not only hidden on the card), the request keeps waiting, and Deny still works.
    @Test func incompletePermissionCanOnlyBeDenied() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.writeJSON(contentLength: 10_000))
        let entry = try #require(f.held.first)
        guard case .permission(let tool, let input, let isComplete) = entry.kind else { Issue.record("not a permission"); return }
        #expect(tool == "Write" && !isComplete)
        #expect(input.hasPrefix("file_path: /Users/me/project/notes.md\n"))

        f.center.decidePermission(entry.id, allow: true)
        f.passTheLockout()
        f.center.perform(.decidePermission(entry.id, allow: true))
        #expect(connection.replies.isEmpty)
        #expect(f.held.map(\.id) == [entry.id])

        f.center.perform(.decidePermission(entry.id, allow: false))
        #expect(connection.replies == [ClaudeHook.permissionReply(allow: false)])
        #expect(f.held.isEmpty)

        // A small input is complete and can be allowed.
        let small = f.arrive(Self.writeJSON(contentLength: 10))
        let smallEntry = try #require(f.held.first)
        #expect(smallEntry.kind == .permission(tool: "Write", input: "file_path: /Users/me/project/notes.md\n{\n  \"content\" : \"aaaaaaaaaa\"\n}",
                                               isComplete: true))
        f.center.decidePermission(smallEntry.id, allow: true)
        #expect(small.replies == [ClaudeHook.permissionReply(allow: true)])
    }

    @Test func stopSetsTheDoneMessage() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.status(.done, "user picked SQLite")
        #expect(f.center.inbox.visible.first?.message == "user picked SQLite")
        let question = f.arrive(Self.questionJSON)
        let stop = f.arrive(Self.stopJSON)
        #expect(stop.replies == [ClaudeHook.noDecision])
        let done = try #require(f.center.inbox.visible.first)
        #expect(done.kind == .done)
        #expect(done.message == "You chose SQLite as the database. I haven't done anything else.")
        // The turn ended: a question still held for that tab can no longer be answered.
        #expect(question.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
    }

    /// A Stop without a message keeps the done entry's text, and still releases held requests.
    @Test func stopWithoutAMessage() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.status(.done, "user picked SQLite")
        let permission = f.arrive(Self.permissionJSON())
        let stop = f.arrive(#"{"session_id":"f32c","hook_event_name":"Stop"}"#)
        #expect(stop.replies == [ClaudeHook.noDecision])
        #expect(permission.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
        #expect(f.center.inbox.visible.first?.message == "user picked SQLite")
    }

    @Test func unknownTabGetsNoDecision() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON, tabID: UUID())
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(connection.acks == 1)
        #expect(f.center.inbox.entries.isEmpty)
    }

    /// SINGULARITY_TAB leaks into whatever the tab starts (a tmux server serving Terminal.app
    /// panes later): a helper that does not run inside the tab's shell gets "no decision" at once,
    /// for questions, permissions and Stop alike. So does an unknown peer or shell.
    @Test func requestsFromOutsideTheTabAreNotHeld() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.status(.done, "user picked SQLite")
        for json in [Self.questionJSON, Self.permissionJSON(), Self.stopJSON] {
            // launchd is no descendant of this process; nor is "unknown".
            for peer in [pid_t(1), nil] {
                let connection = f.arrive(json, connection: FakeConnection(peerPID: peer))
                #expect(connection.replies == [ClaudeHook.noDecision])
            }
        }
        #expect(f.held.isEmpty)
        #expect(f.recorder.arrivals.count == 1)   // the done entry only
        #expect(f.center.inbox.visible.first?.message == "user picked SQLite")

        // The tab's shell is not known (no terminal session for it): "no" as well.
        f.center.tabShellPID = nil
        let connection = f.arrive(Self.questionJSON)
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
    }

    /// At most `maxHeldPerTab` held per tab; the next one goes to the terminal at once.
    @Test func atMostFiveHeldPerTab() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        #expect(InboxCenter.maxHeldPerTab == 5)
        let held = (0..<5).map { f.arrive(Self.permissionJSON("rm \($0).txt")) }
        let extra = f.arrive(Self.questionJSON)
        #expect(f.held.count == 5)
        #expect(held.allSatisfy { $0.replies.isEmpty })
        #expect(extra.replies == [ClaudeHook.noDecision])
        // One answered: room for one more.
        f.center.decidePermission(f.held[0].id, allow: false)
        let next = f.arrive(Self.questionJSON)
        #expect(next.replies.isEmpty)
        #expect(f.held.count == 5)
    }

    @Test func twoPermissionsFromOneTabAreTwoEntries() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let first = f.arrive(Self.permissionJSON("rm a.txt"))
        let second = f.arrive(Self.permissionJSON("rm a.txt"))
        #expect(f.held.count == 2)
        #expect(f.recorder.arrivals.count == 2)
        f.center.decidePermission(f.held[0].id, allow: false)
        #expect(first.replies.count == 1 && second.replies.isEmpty)
        #expect(f.held.count == 1)
        f.center.wentToTerminal(f.tab.id)
        #expect(second.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
    }

    // MARK: More ways in and out

    /// AskUserQuestion also raises a PermissionRequest (its dialog is the question itself), and
    /// other hooks are not ours: "no decision" at once, never an entry.
    @Test func ignoredHooksGetNoDecisionAtOnce() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        for json in [Self.askPermissionJSON, "{}", "not json",
                     #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
                     #"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#] {
            let connection = f.arrive(json)
            #expect(connection.replies == [ClaudeHook.noDecision], "\(json)")
        }
        #expect(f.center.inbox.entries.isEmpty)
        #expect(f.recorder.arrivals.isEmpty)
    }

    /// The owner answered a permission dialog in the terminal (Claude Code does not tell the hook):
    /// the tab reporting `working` releases held permissions, not held questions (the status is
    /// `working` while a question hook is held). `idle` releases both.
    @Test func statusReleasesHeldRequests() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let question = f.arrive(Self.questionJSON)
        let permission = f.arrive(Self.permissionJSON())
        f.status(.working, "Which database should we use?")
        #expect(permission.replies == [ClaudeHook.noDecision])
        #expect(question.replies.isEmpty)
        #expect(f.held.count == 1)
        f.status(.idle)
        #expect(question.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
    }

    @Test func closingTheTabHandsItBack() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.permissionJSON())
        f.state.closeTab(f.tab.id, in: f.two.id, confirmIfBusy: false)
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.center.inbox.entries.isEmpty)
    }

    @Test func deletingTheSpaceHandsItBack() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        f.state.deleteSpace(f.two.id)
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.center.inbox.entries.isEmpty)
    }

    @Test func appQuitHandsEverythingBack() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let question = f.arrive(Self.questionJSON)
        let permission = f.arrive(Self.permissionJSON())
        f.center.handBackAllHeld()
        #expect(question.replies == [ClaudeHook.noDecision])
        #expect(permission.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
    }

    /// "Other…" on a question card is "Go to terminal": the question appears in the terminal.
    @Test func otherGoesToTheTerminal() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        let entry = try #require(f.held.first)
        f.center.perform(.goTo(entry))
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.state.selectedTab?.id == f.tab.id)
        await forgetWebsiteData(f)
    }

    /// An answer that matches nothing in the original question (it cannot happen through the
    /// card) leaves the question to the terminal: "no decision", the entry goes.
    @Test func answerThatMatchesNothingIsNoDecision() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        f.center.answerQuestion(try #require(f.held.first).id, answers: ["Something else?": ["Maybe"]])
        #expect(connection.replies == [ClaudeHook.noDecision])
        #expect(f.held.isEmpty)
    }

    /// Every way a held request can end, then every other way tried after it: one reply only
    /// (none when the helper went away). Afterwards the hold-limit timers have long passed.
    @Test func eachRequestIsAnsweredOnce() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.holdLimit = .milliseconds(300)

        func tryEverything(_ id: UUID, _ connection: FakeConnection) {
            f.center.answerQuestion(id, answers: [Self.question: ["SQLite"]])
            f.center.decidePermission(id, allow: true)
            f.center.decidePermission(id, allow: false)
            f.passTheLockout()
            f.center.perform(.answerQuestion(id, [Self.question: ["SQLite"]]))
            f.center.perform(.decidePermission(id, allow: true))
            f.center.dismiss(id)
            f.center.wentToTerminal(f.tab.id)
            f.center.tabClosed(f.tab.id)
            f.status(.working)
            f.status(.done)
            f.status(.idle)
            f.center.terminalSignal(.programExited, tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: nil)
            f.arrive(Self.stopJSON)
            f.center.handBackAllHeld()
            connection.closeFromPeer()
        }

        enum Ending: CaseIterable {
            case answered, allowed, denied, wentToTerminal, tabClosed, dismissed, working, done, idle,
                 programExited, stop, holdLimit, peerClosed, appQuit
        }
        var seen: [(Ending, FakeConnection)] = []
        for ending in Ending.allCases {
            let isQuestion = [.answered, .wentToTerminal, .tabClosed, .done, .programExited, .stop, .peerClosed]
                .contains(ending)
            let connection = f.arrive(isQuestion ? Self.questionJSON : Self.permissionJSON())
            let id = try #require(f.held.first?.id, "\(ending)")
            switch ending {
            case .answered: f.center.answerQuestion(id, answers: [Self.question: ["Postgres"]])
            case .allowed: f.center.decidePermission(id, allow: true)
            case .denied: f.center.decidePermission(id, allow: false)
            case .wentToTerminal: f.center.wentToTerminal(f.tab.id)
            case .tabClosed: f.center.tabClosed(f.tab.id)
            case .dismissed: f.center.dismiss(id)
            case .working: f.status(.working)
            case .done: f.status(.done)
            case .idle: f.status(.idle)
            case .programExited:
                f.center.terminalSignal(.programExited, tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: nil)
            case .stop: f.arrive(Self.stopJSON)
            case .holdLimit: try await waitUntil("the hold limit") { connection.replies.count == 1 }
            case .peerClosed:
                connection.closeFromPeer()
                try await waitUntil("the entry to go") { f.held.isEmpty }
            case .appQuit: f.center.handBackAllHeld()
            }
            #expect(f.held.isEmpty, "\(ending)")
            #expect(connection.replies.count == (ending == .peerClosed ? 0 : 1), "\(ending)")
            tryEverything(id, connection)
            #expect(connection.replies.count == (ending == .peerClosed ? 0 : 1), "\(ending)")
            // Clear away level-1 entries the endings left (done, demoted waiting).
            f.center.tabClosed(f.tab.id)
            seen.append((ending, connection))
        }
        try await Task.sleep(for: .milliseconds(600))
        for (ending, connection) in seen {
            #expect(connection.replies.count == (ending == .peerClosed ? 0 : 1), "\(ending) after the hold limit")
        }
        if case .answered = seen[0].0 {
            #expect(Self.answers(in: try #require(seen[0].1.replies.first)) == [Self.question: "Postgres"])
        }
    }

    // MARK: The cards

    @Test func questionPicks() {
        let single = InboxQuestion(question: "Which database?", options: ["SQLite", "Postgres"])
        let multi = InboxQuestion(question: "Which features?", options: ["Auth", "Search", "Billing"], multiSelect: true)
        #expect(InboxQuestionPicks(questions: [single]).answersAtOnce)
        #expect(!InboxQuestionPicks(questions: [multi]).answersAtOnce)

        var picks = InboxQuestionPicks(questions: [single, multi])
        #expect(!picks.answersAtOnce)
        #expect(!picks.isComplete)
        // A single-choice question is a radio group.
        picks.toggle(0, "SQLite")
        picks.toggle(0, "Postgres")
        #expect(!picks.isPicked(0, "SQLite") && picks.isPicked(0, "Postgres"))
        #expect(!picks.isComplete)
        // Multiple choice: toggles, answered in the options' order.
        picks.toggle(1, "Billing")
        picks.toggle(1, "Auth")
        picks.toggle(1, "Search")
        picks.toggle(1, "Search")
        #expect(picks.isComplete)
        #expect(picks.answers == ["Which database?": ["Postgres"], "Which features?": ["Auth", "Billing"]])
        // Unknown labels and questions change nothing.
        picks.toggle(0, "MySQL")
        picks.toggle(7, "Auth")
        #expect(picks.answers == ["Which database?": ["Postgres"], "Which features?": ["Auth", "Billing"]])
        picks.toggle(1, "Auth")
        picks.toggle(1, "Billing")
        #expect(!picks.isComplete)
    }

    /// Several questions: the card's picks go back with the original texts; multi-select labels
    /// are joined with ", ". Answer clicks wait for the lockout, as approvals' do.
    @Test func cardAnswersSeveralQuestions() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.twoQuestionsJSON)
        let entry = try #require(f.held.first)
        guard case .question(let questions) = entry.kind else { Issue.record("not a question"); return }
        var picks = InboxQuestionPicks(questions: questions)
        picks.toggle(0, "Postgres")
        picks.toggle(1, "Billing")
        picks.toggle(1, "Auth")

        // Just arrived: the click is ignored.
        f.center.perform(.answerQuestion(entry.id, picks.answers))
        #expect(connection.replies.isEmpty)
        #expect(f.held.count == 1)

        f.passTheLockout()
        f.center.perform(.answerQuestion(entry.id, picks.answers))
        let reply = try #require(connection.replies.first)
        #expect(Self.answers(in: reply) == ["Which database should we use?": "Postgres",
                                            "Which features should we enable?": "Auth, Billing"])
        // updatedInput replaces the whole input: the questions are repeated.
        let input = (Self.json(reply)["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any]
        #expect((input?["questions"] as? [Any])?.count == 2)
        #expect(f.held.isEmpty)
    }

    @Test func permissionCardButtons() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.permissionJSON())
        let entry = try #require(f.held.first)
        let choices = InboxPermissionButtons.choices(for: entry)
        #expect(choices.map(\.title) == ["Allow", "Deny"])
        #expect(InboxPermissionText(entry)?.cutNote == nil)
        // A permission that could not be shown in full: Deny only (and Go to terminal, which every
        // card with a tab has).
        let long = f.arrive(Self.writeJSON(contentLength: 10_000))
        let cut = try #require(f.held.first { $0.id != entry.id })
        #expect(InboxPermissionButtons.choices(for: cut).map(\.title) == ["Deny"])
        #expect(cut.tabID != nil)
        let text = try #require(InboxPermissionText(cut))
        #expect(text.cutNote == "Too long to show in full.")
        #expect(text.headline == "Wants to use Write")
        #expect(text.input.hasPrefix("file_path: /Users/me/project/notes.md\n"))
        f.center.decidePermission(cut.id, allow: false)
        #expect(long.replies == [ClaudeHook.permissionReply(allow: false)])
        #expect(InboxPermissionButtons.choices(for: InboxEntry(kind: .done, spaceID: f.two.id, tabID: f.tab.id,
                                                               agent: "x", message: nil, arrived: Date())).isEmpty)
        // Just arrived: ignored.
        f.center.perform(choices[0].action)
        #expect(connection.replies.isEmpty)
        f.passTheLockout()
        f.center.perform(choices[1].action)
        #expect(connection.replies == [ClaudeHook.permissionReply(allow: false)])
    }

    @Test func singleQuestionOptionAnswersAtOnce() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let connection = f.arrive(Self.questionJSON)
        let entry = try #require(f.held.first)
        let action = try #require(InboxQuestionPicks.answerAtOnce(entry: entry, question: 0, label: "Postgres"))
        f.passTheLockout()
        f.center.perform(action)
        #expect(Self.answers(in: try #require(connection.replies.first)) == [Self.question: "Postgres"])
    }

    // MARK: Lookups for the Assistant's terminal tools

    @Test func aHeldQuestionCanBeFoundAndAnsweredOnce() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        #expect(f.center.heldQuestion(forTab: f.tab.id) == nil)
        let connection = f.arrive(Self.questionJSON)
        let entry = try #require(f.held.first)
        let found = try #require(f.center.heldQuestion(forTab: f.tab.id))
        #expect(found.entryID == entry.id)
        #expect(found.questions == [InboxQuestion(question: Self.question, header: "Database", options: ["SQLite", "Postgres"])])
        #expect(f.center.heldQuestion(forTab: UUID()) == nil)
        #expect(!f.center.waitsOnPermission(tabID: f.tab.id))

        #expect(f.center.answerQuestion(entry.id, answers: [Self.question: ["SQLite"]]))
        // Already answered: false, and no second reply to the hook.
        #expect(!f.center.answerQuestion(entry.id, answers: [Self.question: ["Postgres"]]))
        #expect(connection.replies.count == 1)
        #expect(f.center.heldQuestion(forTab: f.tab.id) == nil)
    }

    @Test func aHeldPermissionIsWaitingOnPermission() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.arrive(Self.permissionJSON())
        let entry = try #require(f.held.first)
        #expect(f.center.waitsOnPermission(tabID: f.tab.id))
        #expect(f.center.heldQuestion(forTab: f.tab.id) == nil)
        f.center.decidePermission(entry.id, allow: false)
        #expect(!f.center.waitsOnPermission(tabID: f.tab.id))
    }

    /// An approval asked about a held question (`heldEntryID`) ends `cancelled` when that question
    /// leaves the inbox for any reason: answered on its own card first, or handed back to the
    /// terminal. One asked for a question that is no longer held ends at once.
    @Test func anApprovalAboutAHeldQuestionEndsWhenTheQuestionLeaves() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        // No panel opening by itself in this test, and no plugin page on screen (asking AppKit
        // would need `NSApp`, which a test run on its own has not made).
        f.center.appIsActive = { false }
        f.center.pluginPageOnScreen = { _ in false }
        let space = try #require(f.state.space(f.two.id))

        func ask(about heldID: UUID) -> Task<AgentApprovals.Outcome, Never> {
            var request = AgentApprovals.Request(actor: "Assistant", action: "answer a question in a terminal",
                                                 detail: "In “claude”.", url: nil, spaceName: space.name,
                                                 tabTitle: nil, text: "\(Self.question) → SQLite")
            request.pluginID = "assistant"
            request.tabID = f.tab.id
            request.tabButton = .none
            request.isTerminalRequest = true
            request.heldEntryID = heldID
            return Task { @MainActor in
                await f.state.approvals.check(AgentActionContext(kind: .terminalSend), space: space, request: request)
            }
        }
        func approvalCount() -> Int {
            f.center.inbox.visible.filter { if case .approval = $0.kind { true } else { false } }.count
        }

        // Answered on the inbox's own card first.
        let first = f.arrive(Self.questionJSON)
        let question = try #require(f.held.first)
        let answeredFirst = ask(about: question.id)
        try await waitUntil("the approval") { approvalCount() == 1 }
        #expect(f.center.answerQuestion(question.id, answers: [Self.question: ["Postgres"]]))
        #expect(await answeredFirst.value.logValue == "cancelled")
        #expect(approvalCount() == 0)
        #expect(first.replies.count == 1)

        // Handed back to the terminal (the owner went there).
        let second = f.arrive(Self.questionJSON)
        let again = try #require(f.held.first)
        let handedBack = ask(about: again.id)
        try await waitUntil("the approval") { approvalCount() == 1 }
        f.center.wentToTerminal(f.tab.id)
        #expect(await handedBack.value.logValue == "cancelled")
        #expect(second.replies == [ClaudeHook.noDecision])

        // Asked about a question that is gone already: no entry, cancelled at once.
        #expect(await ask(about: again.id).value.logValue == "cancelled")
        #expect(approvalCount() == 0)
    }

    // MARK: The real socket and the real helper

    /// The built `singularity-hook`, next to this test bundle (`swift build` puts every product of
    /// the package in one folder).
    private static func helperURL() -> URL? {
        var folders = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent() }
        // Fallback: the package's own build folder.
        let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folders.append(package.appending(path: ".build/debug"))
        for folder in folders {
            let url = folder.appending(path: "singularity-hook")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func requireHelper() throws -> URL {
        guard let url = Self.helperURL() else {
            Issue.record("singularity-hook is not built. Build it with `source scripts/env.sh && swift build --product singularity-hook`, then run these tests again.")
            throw CancellationError()
        }
        return url
    }

    /// One run of the helper, as Claude Code starts it: hook JSON on stdin, environment given.
    @MainActor final class HelperRun {
        let process = Process()
        private let output = Pipe()
        private let errors = Pipe()
        private let input = Pipe()
        let started = ContinuousClock.now
        /// Writes stdin off the main actor (it may be larger than the pipe holds) and tells whether
        /// all of it was written. Claude Code reports a hook that stops reading early (EPIPE) as a
        /// failed hook, so every test checks this.
        private var writer: Task<Bool, Never>?

        convenience init(_ url: URL, environment: [String: String], stdin: String) throws {
            try self.init(url, environment: environment, stdin: Data(stdin.utf8))
        }

        init(_ url: URL, arguments: [String] = [], environment: [String: String], stdin: Data) throws {
            // A helper that stopped reading must show up as a failed write, not kill the tests.
            signal(SIGPIPE, SIG_IGN)
            process.executableURL = url
            process.arguments = arguments
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let handle = input.fileHandleForWriting
            writer = Task.detached {
                defer { try? handle.close() }
                do {
                    try handle.write(contentsOf: stdin)
                    return true
                } catch {
                    return false
                }
            }
        }

        /// Waits for the helper to exit; its status, stdout and stderr, and how long it ran.
        /// Expects that the helper read all of its stdin.
        func finish(limit: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation) async throws
            -> (status: Int32, stdout: Data, stderr: Data, took: Duration) {
            try await waitUntil("the helper to exit", limit: limit) { !process.isRunning }
            let took = ContinuousClock.now - started
            let wroteAll = await writer?.value ?? false
            #expect(wroteAll, "the helper did not read all of its stdin", sourceLocation: sourceLocation)
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, stdout, stderr, took)
        }
    }

    private static func shortFolder() -> URL {
        URL(filePath: "/private/tmp/sg-hook-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    /// The real chain: helper → the app's own hook socket (started by `AppState`) → a held entry →
    /// answered in the inbox → the reply on the helper's stdout, exit 0.
    @Test func helperQuestionIsHeldAndAnswered() async throws {
        let helper = try requireHelper()
        let f = try makeFixture()
        defer { tearDown(f) }
        let socket = f.state.paths.hookSocket.path
        // Same rules as the MCP socket: folder 0700, socket 0600.
        var info = stat()
        #expect(stat(socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat((socket as NSString).deletingLastPathComponent, &info) == 0 && info.st_mode & 0o777 == 0o700)

        let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": f.tab.id.uuidString,
                                                      "SINGULARITY_HOOK_SOCKET": socket],
                                stdin: Self.questionJSON)
        try await waitUntil("the held question") { !f.held.isEmpty }
        #expect(run.process.isRunning)
        f.center.answerQuestion(try #require(f.held.first).id, answers: [Self.question: ["Postgres"]])
        let result = try await run.finish()
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        #expect(Self.answers(in: result.stdout) == [Self.question: "Postgres"])
        let output = Self.json(result.stdout)["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PreToolUse")
        #expect(f.held.isEmpty)
    }

    /// Permission allowed in the inbox: the helper prints the PermissionRequest reply.
    @Test func helperPermissionIsAllowed() async throws {
        let helper = try requireHelper()
        let f = try makeFixture()
        defer { tearDown(f) }
        let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": f.tab.id.uuidString,
                                                      "SINGULARITY_HOOK_SOCKET": f.state.paths.hookSocket.path],
                                stdin: Self.permissionJSON())
        try await waitUntil("the held permission") { !f.held.isEmpty }
        f.center.decidePermission(try #require(f.held.first).id, allow: true)
        let result = try await run.finish()
        #expect(result.status == 0 && result.stderr.isEmpty)
        #expect(result.stdout == ClaudeHook.permissionReply(allow: true))
    }

    /// Looking at the tab, or a hook that is not ours: empty stdout, exit 0, at once.
    @Test func helperGetsNoDecisionAtOnce() async throws {
        let helper = try requireHelper()
        let f = try makeFixture(selecting: "two")
        defer { tearDown(f) }
        for json in [Self.questionJSON, Self.stopJSON, Self.askPermissionJSON, "not json at all"] {
            let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": f.tab.id.uuidString,
                                                          "SINGULARITY_HOOK_SOCKET": f.state.paths.hookSocket.path],
                                    stdin: json)
            let result = try await run.finish()
            #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty, "\(json)")
        }
        #expect(f.center.inbox.entries.allSatisfy { !$0.isHeld })
        // The Stop hook's message arrived.
        #expect(f.center.inbox.entries.isEmpty)
    }

    /// Claude Code killed the helper (Esc in the terminal): the entry goes.
    @Test func helperKilledWhileHeldRemovesTheEntry() async throws {
        let helper = try requireHelper()
        let f = try makeFixture()
        defer { tearDown(f) }
        let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": f.tab.id.uuidString,
                                                      "SINGULARITY_HOOK_SOCKET": f.state.paths.hookSocket.path],
                                stdin: Self.questionJSON)
        try await waitUntil("the held question") { !f.held.isEmpty }
        run.process.terminate()   // SIGTERM, as Claude Code sends it
        try await waitUntil("the entry to go") { f.held.isEmpty }
        #expect(f.center.inbox.entries.isEmpty)
    }

    /// Anywhere but a Singularity terminal with the app running, the helper must be invisible:
    /// no variables, no socket, a stale socket file: exit 0, no output, at once.
    @Test func helperIsInvisibleOutsideSingularity() async throws {
        let helper = try requireHelper()
        let folder = Self.shortFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A socket file nobody listens on (the app crashed): bind, then close without unlinking.
        let stale = folder.appending(path: "stale.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: stale.utf8)
            buffer[stale.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(bound == 0 && FileManager.default.fileExists(atPath: stale))

        let tab = UUID().uuidString
        let cases: [(String, [String: String])] = [
            ("no variables", [:]),
            ("no tab", ["SINGULARITY_HOOK_SOCKET": stale]),
            ("no socket variable", ["SINGULARITY_TAB": tab]),
            ("no socket file", ["SINGULARITY_TAB": tab, "SINGULARITY_HOOK_SOCKET": folder.appending(path: "none.sock").path]),
            ("stale socket file", ["SINGULARITY_TAB": tab, "SINGULARITY_HOOK_SOCKET": stale]),
        ]
        for (name, environment) in cases {
            let run = try HelperRun(helper, environment: environment, stdin: Self.questionJSON)
            let result = try await run.finish(limit: .seconds(5))
            #expect(result.status == 0, "\(name)")
            #expect(result.stdout.isEmpty, "\(name)")
            #expect(result.stderr.isEmpty, "\(name)")
            #expect(result.took < .seconds(2), "\(name) took \(result.took)")
        }

        // A large hook input (a Write of a big file) in a terminal that is not Singularity's: more
        // than the pipe holds, so the helper must read it all before going quietly.
        let large = Self.permissionJSON(String(repeating: "x", count: 300_000))
        for (name, environment) in cases {
            let result = try await HelperRun(helper, environment: environment, stdin: large).finish(limit: .seconds(5))
            #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty, "large, \(name)")
        }
    }

    /// The command Install writes into Claude Code's settings, run the way Claude Code runs a hook
    /// (`/bin/sh -c <command>`, hook JSON on stdin). With the helper missing (the bundle moved,
    /// deleted, or being rebuilt or swapped by an update) it must stay as invisible as the helper
    /// itself: exit 0, no output, all of stdin read (a large Write still arrives whole). With the
    /// built helper there and no Singularity variables: the same. No environment at all, so not
    /// even PATH: `sh` finds `cat` on its own default path.
    @Test func installedCommandIsQuietWhenTheHelperIsMissing() async throws {
        let helper = try requireHelper()
        let folder = Self.shortFolder()
        let missing = folder.appending(path: "Moved It's.app/Contents/MacOS/singularity-hook").path
        #expect(!FileManager.default.fileExists(atPath: missing))
        let large = Data(Self.permissionJSON(String(repeating: "x", count: 300_000)).utf8)
        for (name, path) in [("missing helper", missing), ("built helper", helper.path)] {
            let command = ClaudeHookSettings.command(helper: path)
            let run = try HelperRun(URL(filePath: "/bin/sh"), arguments: ["-c", command], environment: [:], stdin: large)
            let result = try await run.finish(limit: .seconds(5))
            #expect(result.status == 0, "\(name)")
            #expect(result.stdout.isEmpty, "\(name)")
            #expect(result.stderr.isEmpty, "\(name): \(String(decoding: result.stderr, as: UTF8.self))")
        }
    }

    /// Over `maxWireBytes`, inside a Singularity tab with the app listening: read to the end,
    /// nothing sent, no output, exit 0.
    @Test func helperReadsAnOversizedInputToTheEnd() async throws {
        let helper = try requireHelper()
        let f = try makeFixture()
        defer { tearDown(f) }
        let huge = Data(Self.permissionJSON(String(repeating: "x", count: 2_500_000)).utf8)
        let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": f.tab.id.uuidString,
                                                      "SINGULARITY_HOOK_SOCKET": f.state.paths.hookSocket.path],
                                stdin: huge)
        let result = try await run.finish()
        #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(f.center.inbox.entries.isEmpty)
    }

    /// A listener for the acknowledgement tests: reads the helper's line, then does `then` with
    /// the connection (write something, or nothing) and keeps it open until the test ends.
    private final class ScriptedListener: @unchecked Sendable {
        let listener: MCPSocketListener

        init(path: String, then answer: @escaping @Sendable (Int32) -> Void) {
            let box = Box()
            listener = MCPSocketListener(path: path) { client, _ in
                DispatchQueue.global().async {
                    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var line = Data()
                    while !line.contains(0x0A) {
                        let count = read(client, &buffer, buffer.count)
                        if count <= 0 { break }
                        line.append(contentsOf: buffer[0..<count])
                    }
                    box.add(client)
                    answer(client)
                }
            }
            self.box = box
        }

        private let box: Box
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var clients: [Int32] = []
            func add(_ fd: Int32) { lock.withLock { clients.append(fd) } }
            func closeAll() { lock.withLock { clients.forEach { close($0) }; clients = [] } }
        }

        func stop() {
            listener.stop()
            box.closeAll()
        }
    }

    private func helperAgainst(_ answer: @escaping @Sendable (Int32) -> Void) async throws
        -> (status: Int32, stdout: Data, stderr: Data, took: Duration) {
        let helper = try requireHelper()
        let folder = Self.shortFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "hook.sock").path
        let scripted = ScriptedListener(path: path, then: answer)
        try scripted.listener.start()
        defer { scripted.stop() }
        let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": UUID().uuidString, "SINGULARITY_HOOK_SOCKET": path],
                                stdin: Self.questionJSON)
        return try await run.finish(limit: .seconds(12))
    }

    /// The app accepted but never acknowledged (its main thread is stuck): the helper gives up
    /// after about 5 s with no output, instead of holding Claude Code for the hook's hour.
    @Test func helperGivesUpWithoutAnAcknowledgement() async throws {
        let result = try await helperAgainst { _ in }
        #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(result.took > .seconds(4.5) && result.took < .seconds(8), "took \(result.took)")
    }

    /// The acknowledgement byte is stripped and the rest passes through unchanged; any other
    /// first byte is not our app: nothing printed.
    @Test func helperStripsTheAcknowledgement() async throws {
        let answered = try await helperAgainst { client in
            let bytes: [UInt8] = [ClaudeHook.ack] + Array("{\"ok\":1}\n".utf8)
            _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) }
            shutdown(client, SHUT_WR)
        }
        #expect(answered.status == 0 && answered.stderr.isEmpty)
        #expect(String(decoding: answered.stdout, as: UTF8.self) == "{\"ok\":1}\n")
        #expect(answered.took < .seconds(3))

        let stranger = try await helperAgainst { client in
            _ = write(client, "{\"ok\":1}", 8)
            shutdown(client, SHUT_WR)
        }
        #expect(stranger.status == 0 && stranger.stdout.isEmpty && stranger.stderr.isEmpty)
    }

    /// The helper keeps its own copy of the wire framing (it does not link SingularityCore): the
    /// line it really sends must be exactly `ClaudeHook.wireLine`.
    @Test func helperSendsTheSameLineAsCore() async throws {
        let helper = try requireHelper()
        let folder = Self.shortFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "hook.sock").path

        final class Received: @unchecked Sendable {
            let lock = NSLock()
            var line: Data?
        }
        let received = Received()
        // A bare listener that reads one line and hangs up without a reply.
        let listener = MCPSocketListener(path: path) { client, _ in
            DispatchQueue.global().async {
                // An accepted socket inherits the listener's O_NONBLOCK on macOS: read blocking here.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var line = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !line.contains(0x0A) {
                    let count = read(client, &buffer, buffer.count)
                    if count <= 0 { break }
                    line.append(contentsOf: buffer[0..<count])
                }
                received.lock.withLock { received.line = line }
                close(client)
            }
        }
        try listener.start()
        defer { listener.stop() }

        let tab = UUID().uuidString
        let hook = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_input":{"b":[1,2.5,null],"a":"x/y é\n"}}"#
        let run = try HelperRun(helper, environment: ["SINGULARITY_TAB": tab, "SINGULARITY_HOOK_SOCKET": path], stdin: hook)
        let result = try await run.finish()
        // Hung up without a reply: no decision.
        #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
        let line = try #require(received.lock.withLock { received.line })
        #expect(String(decoding: line, as: UTF8.self)
                == String(decoding: ClaudeHook.wireLine(tabID: tab, hookInput: Data(hook.utf8)), as: UTF8.self))
        #expect(line == ClaudeHook.wireLine(tabID: tab, hookInput: Data(hook.utf8)))
    }

    // MARK: The socket listener itself

    /// Connects to a Unix socket (the test's stand-in for the helper).
    private static func connectRaw(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Reads until the other side hangs up (or `limit` passes); off the main actor.
    private static func readToEnd(_ fd: Int32, limit: Duration) async -> (data: Data, hungUp: Bool) {
        await Task.detached {
            var timeout = timeval(tv_sec: Int(limit.components.seconds) + 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { return (data, true) }
                if count < 0 { return (data, false) }
                data.append(contentsOf: buffer[0..<count])
            }
        }.value
    }

    /// A peer that says nothing is dropped after the idle limit; one that sends a line longer
    /// than `maxWireBytes` is dropped at once; a line that is not a wire line gets "no decision".
    /// None of them reaches the inbox, and none blocks the next connection.
    @Test func socketDropsSilentOversizedAndBadPeers() async throws {
        MainRunLoopGuard.start
        let folder = Self.shortFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "hook.sock").path

        final class Arrived: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let arrived = Arrived()
        let socket = HookSocket(path: path, idleLimit: .milliseconds(300)) { _, _, connection in
            arrived.lock.withLock { arrived.count += 1 }
            connection.reply(Data("ok".utf8))
        }
        try socket.start()
        defer { socket.stop() }

        // Silent: dropped after the idle limit, with nothing written.
        let silent = try #require(Self.connectRaw(path))
        defer { close(silent) }
        // Meanwhile another connection is served at once.
        let good = try #require(Self.connectRaw(path))
        defer { close(good) }
        let line = ClaudeHook.wireLine(tabID: UUID().uuidString, hookInput: Data("{}".utf8))
        _ = line.withUnsafeBytes { write(good, $0.baseAddress, line.count) }
        let goodReply = await Self.readToEnd(good, limit: .seconds(2))
        #expect(goodReply == (Data("ok".utf8), true))

        let started = ContinuousClock.now
        let silentReply = await Self.readToEnd(silent, limit: .seconds(3))
        #expect(silentReply.hungUp && silentReply.data.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))

        // Not a wire line: "no decision" (hang up, nothing written).
        let bad = try #require(Self.connectRaw(path))
        defer { close(bad) }
        _ = write(bad, "hello\n", 6)
        let badReply = await Self.readToEnd(bad, limit: .seconds(2))
        #expect(badReply.hungUp && badReply.data.isEmpty)

        // Too long: dropped without waiting for the end of the line.
        let big = try #require(Self.connectRaw(path))
        defer { close(big) }
        let chunk = Data(repeating: 0x61, count: ClaudeHook.maxWireBytes + 100_000)
        Task.detached { _ = chunk.withUnsafeBytes { write(big, $0.baseAddress, chunk.count) } }
        let bigReply = await Self.readToEnd(big, limit: .seconds(3))
        #expect(bigReply.data.isEmpty)

        #expect(arrived.lock.withLock { arrived.count } == 1)
    }

    /// A real connection: one reply only, and the peer going away is reported once.
    @Test func connectionRepliesOnceAndReportsThePeerLeaving() async throws {
        MainRunLoopGuard.start
        let folder = Self.shortFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "hook.sock").path

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var connections: [HookConnection] = []
            var closed = 0
        }
        let box = Box()
        let socket = HookSocket(path: path) { _, _, connection in
            connection.onClosedByPeer = { box.lock.withLock { box.closed += 1 } }
            box.lock.withLock { box.connections.append(connection) }
        }
        try socket.start()
        defer { socket.stop() }
        let line = ClaudeHook.wireLine(tabID: UUID().uuidString, hookInput: Data("{}".utf8))

        // Replied twice: the second reply is ignored.
        let first = try #require(Self.connectRaw(path))
        defer { close(first) }
        _ = line.withUnsafeBytes { write(first, $0.baseAddress, line.count) }
        try await waitUntil("the line") { box.lock.withLock { box.connections.count } == 1 }
        let connection = box.lock.withLock { box.connections[0] }
        connection.reply(Data("one".utf8))
        connection.reply(Data("two".utf8))
        #expect(await Self.readToEnd(first, limit: .seconds(2)) == (Data("one".utf8), true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.lock.withLock { box.closed } == 0)

        // The peer hangs up while held: reported once; a late reply goes nowhere.
        let second = try #require(Self.connectRaw(path))
        _ = line.withUnsafeBytes { write(second, $0.baseAddress, line.count) }
        try await waitUntil("the line") { box.lock.withLock { box.connections.count } == 2 }
        close(second)
        try await waitUntil("the peer to be gone") { box.lock.withLock { box.closed } == 1 }
        box.lock.withLock { box.connections[1] }.reply(Data("late".utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.lock.withLock { box.closed } == 1)
    }
}
}
