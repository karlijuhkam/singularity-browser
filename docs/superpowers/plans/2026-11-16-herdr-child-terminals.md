# Child terminals under a terminal tab: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under a herdr-core terminal tab, list the herdr terminals that descend from it and show one in the tab's pane on click.

**Architecture:** Core folds the lines of `hc events --json` into a picture of every terminal and derives each tab's child rows (pure, tested). The app runs one `hc events` process, keeps `shownChild` (tab id → child address) in memory, and the tab's pane hosts an attach-only terminal view for that child. Nothing is stored.

**Tech Stack:** Swift, SwiftUI/AppKit, SwiftTerm, Swift Testing. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-16-herdr-child-terminals-design.md`

## Global Constraints

- The app never runs `hc run`, `hc kill`, `hc rm`, `hc send` or `hc keys` for a child. Only `hc events --json`, `hc attach <address> --history 2000` and `hc get <address> --json`.
- Nothing about children is written to `space.json`; no Space is marked dirty by them.
- Everything read from herdr-core is untrusted: names through `InboxText.clean`, cut to 60, drawn with `Text(verbatim:)`.
- No agent tool, plugin or inbox rule in Core changes.
- Tests never run `hc` and never start a shell; no test window becomes key.
- With `SINGULARITY_HOME` set, the watcher runs only when `HC_SESSION` is set too.

## What `hc events --json` sends (checked on hc 0.1.20, a throwaway `HC_SESSION`)

- First line: `{"channel":null,"seq":N,"terminals":[<Terminal>…]}`.
- Then `{"jsonrpc":"2.0","method":"event","params":{"type":T,"terminal":"t3","seq":N,"data":{…}}}`:
  - `created`: `data` is the whole Terminal (has `address`).
  - `foreground`: `data` is the foreground object (`argv`, `cwd`, `name`, `pid`).
  - `status`: `data.status` is `{"app","state"}` or null.
  - `title`: `data.title`. `labels`: `data.labels` (the whole set).
  - `finished`: the terminal is no longer live. `removed`: it is gone.
  - `turn`: `data.state` is the turn's state, **not** the terminal's: never merged.
  - `lost`, `restarted`, `keep`, `size`, `doc`, heartbeats: ignored.
  - `missed`: the subscriber fell behind; the watcher starts the process again.

## Review Focus

- A worker ends while its row is shown in the pane: the pane must go back to the tab's own terminal, not stay on a dead view.
- `hc` restarts or the watcher dies: rows go after 10 s and come back without a relaunch.
- A terminal named by a hostile program (escape characters, 500 characters, newlines): the row stays one clean line.
- A Bot asks a question while the owner watches a worker: an inbox entry appears (the tab is not "on screen").
- Closing a tab with children and a shell at its prompt: the alert appears.

---

### Task 1: Core `HerdrTree`

**Files:** Create `Sources/SingularityCore/Terminal/HerdrTree.swift`, `Tests/SingularityCoreTests/HerdrTreeTests.swift`.

**Produces:**

```swift
public struct HerdrTerminal: Equatable, Sendable {
    public var address: String; public var name: String?; public var parent: String?
    public var isLive: Bool; public var status: String?; public var labels: [String: String]
    public var program: String?; public var cwd: String?; public var createdMs: Int64
}
public enum HerdrMark: Equatable, Sendable { case working, needsYou, error, done, idle, none }
public struct HerdrChildRow: Equatable, Identifiable, Sendable {
    public var address: String; public var name: String; public var mark: HerdrMark
    public var level: Int          // 1...3
    public var folder: String?; public var id: String { address }
}
public struct HerdrChildren: Equatable, Sendable {
    public var rows: [HerdrChildRow]   // at most 30
    public var more: Int               // rows left out
    public var liveCount: Int          // every live descendant, mailboxes too (the close alert)
    public var needsYou: Bool
    public static let none: HerdrChildren
}
public struct HerdrFacts: Equatable, Sendable {
    public enum LineResult: Equatable, Sendable { case changed, unchanged, resync, skipped }
    public init()
    public private(set) var terminals: [String: HerdrTerminal]
    public mutating func apply(line: String) -> LineResult
    public mutating func clear()
    public func children(ofTerminalNamed name: String) -> HerdrChildren
}
```

- [x] Tests first (`HerdrTreeTests`): snapshot then `created`; root found by name; order by `createdMs` then address; `role=postkast` and `role=topic-postkast` passed through with their children lifted to the mailbox's level; a topic's workers at level 2; levels capped at 3; 30 rows and `more`; a cycle; a missing parent; another tab's root (`sg-` + 24 hex) under a tab is neither listed nor walked; names cleaned and cut to 60, fallback to program then address; marks from `working`/`blocked`/`error`/`done`/`idle`/other; `status`, `title`, `labels`, `foreground`, `finished`, `removed` folded; `turn` not merged; `missed` → `.resync`; rubbish → `.skipped`.
- [x] Implement, run `swift test --filter HerdrTreeTests`, commit.

### Task 2: The watcher, the child session, state

**Files:** Create `Sources/Singularity/Terminal/HerdrWatcher.swift`, `Sources/Singularity/Terminal/HerdrChildSession.swift`. Modify `TerminalRegistry.swift`, `App/AppState.swift`.

**Produces:**

```swift
@MainActor @Observable final class HerdrWatcher {
    private(set) var facts: HerdrFacts
    var collapsed: Set<UUID>
    func children(of tabID: UUID) -> HerdrChildren
    func feed(line: String)                 // the process's lines; tests call it directly
    func updateRunning()                    // start or stop the process from settings and tabs
    func stop()
    static func mayRun(herdrOn: Bool, hasTerminalTab: Bool, environment: [String: String]) -> Bool
}
@MainActor final class HerdrChildSession {
    let address: String; let view: SingularityTerminalView
    init(address: String, hc: String?, font: NSFont, onGone: @escaping () -> Void)  // hc nil: no process (tests)
    func tearDown()
}
// TerminalRegistry
func childSession(address: String) -> HerdrChildSession
func existingChildSession(_ address: String) -> HerdrChildSession?
func removeChildSessions(keeping addresses: Set<String>)
// AppState
let herdr: HerdrWatcher
private(set) var shownChild: [UUID: String]
func showChild(_ address: String, under tabID: UUID)
func showOwnTerminal(_ tabID: UUID)
func herdrFactsChanged()                    // prunes shownChild and child sessions
```

- [x] Watcher: `Process` + pipe, lines to `feed` on the main actor; restart after 2, 4, 8 … 60 s (a parsed line resets it); rows cleared after 10 s down; `.resync` restarts at once.
- [x] `isTabOnScreen` false while `shownChild[tabID]` is set; `inboxNoteVisibleTabs` skips such a tab; `showTab` clears it; `closeSelectedTab` goes back to the own terminal first; `closeTab` asks when `children(of:).liveCount > 0` with the spec's text; closing a tab clears its entry.

### Task 3: Sidebar rows and the pane

**Files:** Create `Sources/Singularity/Sidebar/HerdrChildRows.swift`. Modify `Sidebar/SidebarView.swift`, `Split/SplitViews.swift`.

- [x] A tab (or split) with children is one List row holding a `VStack`: the tab's own row with a disclosure triangle, then the child rows. Not tagged for List selection (as `SplitRow` isn't): taps select, own highlight.
- [x] `TabContentView`: when `shownChild[tab.id]` is set, the strip `‹ <tab title>  /  <child name>` and the child session's view.

### Task 4: App tests, documents, release

**Files:** Create `Tests/SingularityAppTests/HerdrChildTests.swift`. Modify `CLAUDE.md`, `IDEAS.md`, the herdr-core spec's non-goal, this spec's "As built".

- [x] Tests: rows from fed lines; `showChild` and the hosted view; child ends → back; ⌘W; inbox facts while a child is shown; `showTab` clears; nothing saved; `mayRun`.
- [x] `scripts/test.sh`, a build of the bundle, review, merge to main, `scripts/release.sh`.
