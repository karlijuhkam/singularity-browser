import Foundation
import Testing
@testable import SingularityCore

@Suite struct HerdrTreeTests {
    static let root = "sg-0123456789abcdef01234567"

    /// A terminal as herdr-core writes it.
    static func terminal(_ address: String, name: String? = nil, parent: String? = nil, state: String = "live",
                         status: String? = nil, labels: [String: String] = [:], argv: [String]? = nil,
                         created: Int = 0) -> [String: Any] {
        var object: [String: Any] = ["address": address, "state": state, "labels": labels, "created_ms": created,
                                     "name": name ?? NSNull(), "parent": parent ?? NSNull()]
        object["status"] = status.map { ["app": "x", "state": $0] } ?? NSNull()
        object["foreground"] = argv.map { ["argv": $0, "cwd": "/work"] } ?? NSNull()
        return object
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func snapshot(_ terminals: [[String: Any]]) -> String {
        json(["channel": NSNull(), "seq": 1, "terminals": terminals])
    }

    static func event(_ type: String, _ address: String, _ data: [String: Any] = [:]) -> String {
        json(["jsonrpc": "2.0", "method": "event", "params": ["type": type, "terminal": address, "seq": 2, "data": data]])
    }

    static func facts(_ terminals: [[String: Any]]) -> HerdrFacts {
        var facts = HerdrFacts()
        _ = facts.apply(line: snapshot(terminals))
        return facts
    }

    func rows(_ facts: HerdrFacts) -> [String] {
        facts.children(ofTerminalNamed: Self.root).rows.map { "\($0.level) \($0.name)" }
    }

    // MARK: - The tree

    @Test func aTabWithoutATerminalHasNoRows() {
        #expect(HerdrFacts().children(ofTerminalNamed: Self.root) == .none)
        let facts = Self.facts([Self.terminal("t1", name: "other")])
        #expect(facts.children(ofTerminalNamed: Self.root) == .none)
    }

    @Test func childrenInCreationOrderThenAddress() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t4", name: "late", parent: "t1", created: 30),
            Self.terminal("t3", name: "b", parent: "t1", created: 10),
            Self.terminal("t2", name: "a", parent: "t1", created: 10),
            Self.terminal("t9", name: "stranger"),
        ])
        #expect(rows(facts) == ["1 a", "1 b", "1 late"])
        #expect(facts.children(ofTerminalNamed: Self.root).liveCount == 3)
    }

    @Test func grandchildrenFollowTheirParent() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t2", name: "topic", parent: "t1", created: 1),
            Self.terminal("t3", name: "second", parent: "t1", created: 2),
            Self.terminal("t4", name: "worker", parent: "t2", created: 3),
        ])
        #expect(rows(facts) == ["1 topic", "2 worker", "1 second"])
    }

    @Test func mailboxesArePassedThrough() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t2", name: "postkast-gwb", parent: "t1", labels: ["role": "postkast"], created: 1),
            Self.terminal("t3", name: "plat135", parent: "t2", created: 2),
            Self.terminal("t4", name: "teema-nortal", parent: "t1", labels: ["role": "topic"], created: 3),
            Self.terminal("t5", name: "kast-nortal", parent: "t4", labels: ["role": "topic-postkast"], created: 4),
            Self.terminal("t6", name: "review", parent: "t5", created: 5),
        ])
        #expect(rows(facts) == ["1 plat135", "1 teema-nortal", "2 review"])
        // The close alert counts everything that may end, mailboxes too.
        #expect(facts.children(ofTerminalNamed: Self.root).liveCount == 5)
    }

    @Test func deepRowsAreDrawnAtLevelThree() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t2", name: "a", parent: "t1"),
            Self.terminal("t3", name: "b", parent: "t2"),
            Self.terminal("t4", name: "c", parent: "t3"),
            Self.terminal("t5", name: "d", parent: "t4"),
        ])
        #expect(rows(facts) == ["1 a", "2 b", "3 c", "3 d"])
    }

    @Test func atMostThirtyRows() {
        var terminals = [Self.terminal("t1", name: Self.root)]
        for index in 0..<34 {
            terminals.append(Self.terminal("w\(index)", name: "w\(index)", parent: "t1", status: index == 33 ? "blocked" : nil, created: index))
        }
        let children = Self.facts(terminals).children(ofTerminalNamed: Self.root)
        #expect(children.rows.count == 30)
        #expect(children.more == 4)
        #expect(children.liveCount == 34)
        // A row that was left out still counts for the tab's mark.
        #expect(children.needsYou)
    }

    @Test func finishedTerminalsAreNotRowsAndEndTheWalk() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t2", name: "gone", parent: "t1", state: "finished"),
            Self.terminal("t3", name: "orphan", parent: "t2"),
        ])
        #expect(rows(facts) == [])
        // A finished root has no rows either.
        let ended = Self.facts([Self.terminal("t1", name: Self.root, state: "finished"), Self.terminal("t2", parent: "t1")])
        #expect(ended.children(ofTerminalNamed: Self.root) == .none)
    }

    @Test func aCycleAndAMissingParentEndTheWalk() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root, parent: "t3"),
            Self.terminal("t2", name: "a", parent: "t1"),
            Self.terminal("t3", name: "b", parent: "t2"),
            Self.terminal("t7", name: "lost", parent: "t99"),
        ])
        #expect(rows(facts) == ["1 a", "2 b"])
    }

    @Test func anotherTabsTerminalIsNeverListed() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t2", name: "sg-aaaaaaaaaaaaaaaaaaaaaaaa", parent: "t1"),
            Self.terminal("t3", name: "its-worker", parent: "t2"),
            Self.terminal("t4", name: "sg-short", parent: "t1"),
        ])
        #expect(rows(facts) == ["1 sg-short"])
    }

    // MARK: - Names and marks

    @Test func namesAreCleanedCutAndFallBack() {
        let long = String(repeating: "x", count: 500)
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("t2", name: "evil\u{1b}[31m\nname\u{7}", parent: "t1", created: 1),
            Self.terminal("t3", name: long, parent: "t1", created: 2),
            Self.terminal("t4", parent: "t1", argv: ["/opt/homebrew/bin/pnpm", "dev"], created: 3),
            Self.terminal("t5", name: " \n ", parent: "t1", created: 4),
        ])
        let names = facts.children(ofTerminalNamed: Self.root).rows.map(\.name)
        #expect(names[0] == "evil[31m name")
        #expect(names[1].count <= 60)
        #expect(names[2] == "pnpm")
        #expect(names[3] == "t5")
        #expect(facts.children(ofTerminalNamed: Self.root).rows[2].folder == "/work")
    }

    @Test func marksFollowTheStatus() {
        #expect(HerdrMark(status: "working") == .working)
        #expect(HerdrMark(status: "blocked") == .needsYou)
        #expect(HerdrMark(status: "error") == .error)
        #expect(HerdrMark(status: "done") == .done)
        #expect(HerdrMark(status: "idle") == .idle)
        #expect(HerdrMark(status: "dancing") == .none)
        #expect(HerdrMark(status: nil) == .none)
        let facts = Self.facts([Self.terminal("t1", name: Self.root), Self.terminal("t2", parent: "t1", status: "blocked")])
        #expect(facts.children(ofTerminalNamed: Self.root).rows.first?.mark == .needsYou)
        #expect(facts.children(ofTerminalNamed: Self.root).needsYou)
    }

    // MARK: - Lines

    @Test func changesAreFoldedIn() {
        var facts = Self.facts([Self.terminal("t1", name: Self.root)])
        #expect(facts.apply(line: Self.event("created", "t2", Self.terminal("t2", name: "w", parent: "t1"))) == .changed)
        #expect(rows(facts) == ["1 w"])

        #expect(facts.apply(line: Self.event("status", "t2", ["records": [:], "reported": true, "status": ["app": "claude", "state": "blocked"]])) == .changed)
        #expect(facts.terminals["t2"]?.status == "blocked")
        #expect(facts.apply(line: Self.event("status", "t2", ["status": NSNull()])) == .changed)
        #expect(facts.terminals["t2"]?.status == nil)

        #expect(facts.apply(line: Self.event("labels", "t2", ["labels": ["role": "postkast"]])) == .changed)
        #expect(rows(facts) == [])

        #expect(facts.apply(line: Self.event("labels", "t2", ["labels": [:]])) == .changed)
        #expect(facts.apply(line: Self.event("foreground", "t2", ["argv": ["/usr/bin/sleep", "3"], "cwd": "/tmp/x", "name": "sleep", "pid": 4])) == .changed)
        #expect(facts.terminals["t2"]?.program == "sleep")
        #expect(facts.terminals["t2"]?.cwd == "/tmp/x")

        #expect(facts.apply(line: Self.event("finished", "t2", ["exit_code": 0])) == .changed)
        #expect(rows(facts) == [])
        #expect(facts.apply(line: Self.event("removed", "t2")) == .changed)
        #expect(facts.terminals["t2"] == nil)
    }

    @Test func aRestartedTerminalIsLiveAgain() {
        var facts = Self.facts([Self.terminal("t1", name: Self.root), Self.terminal("t2", name: "w", parent: "t1")])
        _ = facts.apply(line: Self.event("finished", "t2"))
        #expect(rows(facts) == [])
        #expect(facts.apply(line: Self.event("restarted", "t2", ["pid": 5])) == .changed)
        #expect(rows(facts) == ["1 w"])
        _ = facts.apply(line: Self.event("finished", "t2"))
        #expect(facts.apply(line: Self.event("restarted", "t2", Self.terminal("t2", name: "again", parent: "t1"))) == .changed)
        #expect(rows(facts) == ["1 again"])
    }

    @Test func onlyAddressesThatLookLikeHerdrsAreTaken() {
        let facts = Self.facts([
            Self.terminal("t1", name: Self.root),
            Self.terminal("--observe", name: "a", parent: "t1"),
            Self.terminal("t2 --force", name: "b", parent: "t1"),
            Self.terminal("box/t7", name: "c", parent: "t1"),
            Self.terminal("", name: "d", parent: "t1"),
        ])
        #expect(rows(facts) == ["1 c"])
    }

    @Test func aTurnsStateIsNotTheTerminals() {
        var facts = Self.facts([Self.terminal("t1", name: Self.root), Self.terminal("t2", name: "w", parent: "t1", status: "working")])
        #expect(facts.apply(line: Self.event("turn", "t2", ["state": "blocked", "turn": 1])) == .unchanged)
        #expect(facts.terminals["t2"]?.isLive == true)
        #expect(facts.terminals["t2"]?.status == "working")
    }

    @Test func aNewSnapshotReplacesEverything() {
        var facts = Self.facts([Self.terminal("t1", name: Self.root), Self.terminal("t2", parent: "t1")])
        #expect(facts.apply(line: Self.snapshot([Self.terminal("t1", name: Self.root)])) == .changed)
        #expect(facts.terminals.count == 1)
        #expect(facts.apply(line: Self.snapshot([Self.terminal("t1", name: Self.root)])) == .unchanged)
        facts.clear()
        #expect(facts.terminals.isEmpty)
    }

    @Test func oddLines() {
        var facts = Self.facts([Self.terminal("t1", name: Self.root)])
        let before = facts
        #expect(facts.apply(line: "") == .skipped)
        #expect(facts.apply(line: "not json") == .skipped)
        #expect(facts.apply(line: "[1,2]") == .skipped)
        #expect(facts.apply(line: #"{"stopped":true}"#) == .skipped)
        #expect(facts.apply(line: #"{"jsonrpc":"2.0","method":"heartbeat","params":{}}"#) == .unchanged)
        #expect(facts.apply(line: Self.event("missed", "t1")) == .resync)
        #expect(facts.apply(line: Self.event("size", "t1", ["cols": 80])) == .unchanged)
        // A change for a terminal we never heard of does nothing.
        #expect(facts.apply(line: Self.event("status", "t77", ["status": ["state": "working"]])) == .unchanged)
        #expect(facts.apply(line: Self.event("created", "t5", ["name": "no address"])) == .unchanged)
        #expect(facts == before)
    }
}
