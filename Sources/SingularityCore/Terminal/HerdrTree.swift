import Foundation

/// The herdr-core terminals that descend from a terminal tab's own terminal: a Bot's workers,
/// its topic sessions, a dev server started with `hc run --bg`. The sidebar lists them under the
/// tab (spec `docs/superpowers/specs/2026-11-16-herdr-child-terminals-design.md`).
///
/// Everything here is pure: the lines of `hc events --json` go in, a picture comes out. The app
/// runs that one process (`HerdrWatcher`) and never asks herdr-core to start, end or change a
/// terminal for this. All of it is read from another program and is untrusted: names are cleaned
/// and cut before they are shown.

/// One herdr-core terminal, as far as the sidebar needs it.
public struct HerdrTerminal: Equatable, Sendable {
    /// herdr-core's own short id, e.g. "t64". What `hc attach` takes.
    public var address: String
    public var name: String?
    /// The address of the terminal that started it, or nil.
    public var parent: String?
    public var isLive: Bool
    /// What the program in it last reported: "working", "blocked", "done", "idle", "error", or nil.
    public var status: String?
    public var labels: [String: String]
    /// The program in front (the last part of its path), when herdr-core knows it.
    public var program: String?
    public var cwd: String?
    public var createdMs: Int64

    public init(address: String, name: String? = nil, parent: String? = nil, isLive: Bool = true,
                status: String? = nil, labels: [String: String] = [:], program: String? = nil,
                cwd: String? = nil, createdMs: Int64 = 0) {
        self.address = address
        self.name = name
        self.parent = parent
        self.isLive = isLive
        self.status = status
        self.labels = labels
        self.program = program
        self.cwd = cwd
        self.createdMs = createdMs
    }
}

/// The small mark on a child's row.
public enum HerdrMark: Equatable, Sendable {
    case working, needsYou, error, done, idle, none

    public init(status: String?) {
        switch status {
        case "working": self = .working
        case "blocked": self = .needsYou
        case "error": self = .error
        case "done": self = .done
        case "idle": self = .idle
        default: self = .none
        }
    }
}

/// One row under a terminal tab.
public struct HerdrChildRow: Equatable, Identifiable, Sendable {
    public var address: String
    /// Cleaned and cut; still untrusted (draw with `Text(verbatim:)`).
    public var name: String
    public var mark: HerdrMark
    /// How far it is indented: 1 for the tab's own children, at most `HerdrFacts.maxLevel`.
    public var level: Int
    public var folder: String?
    public var id: String { address }

    public init(address: String, name: String, mark: HerdrMark, level: Int, folder: String? = nil) {
        self.address = address
        self.name = name
        self.mark = mark
        self.level = level
        self.folder = folder
    }
}

/// Everything the sidebar shows under one tab.
public struct HerdrChildren: Equatable, Sendable {
    /// At most `HerdrFacts.maxRows`.
    public var rows: [HerdrChildRow]
    /// How many rows were left out ("and N more").
    public var more: Int
    /// Every live descendant, mailboxes included: what may end when the tab is closed.
    public var liveCount: Int
    /// Some row (shown or left out) waits for the owner.
    public var needsYou: Bool

    public static let none = HerdrChildren(rows: [], more: 0, liveCount: 0, needsYou: false)

    public init(rows: [HerdrChildRow], more: Int, liveCount: Int, needsYou: Bool) {
        self.rows = rows
        self.more = more
        self.liveCount = liveCount
        self.needsYou = needsYou
    }
}

/// herdr-core's terminals as last heard from `hc events --json`.
public struct HerdrFacts: Equatable, Sendable {
    public static let maxRows = 30
    public static let maxLevel = 3
    public static let nameLimit = 60

    public private(set) var terminals: [String: HerdrTerminal] = [:]

    public init() {}

    public enum LineResult: Equatable, Sendable {
        /// The picture changed.
        case changed
        /// Understood, nothing to redraw (a heartbeat, a resize).
        case unchanged
        /// herdr-core says this listener fell behind: start listening again for a full picture.
        case resync
        /// Not understood. The picture is kept.
        case skipped
    }

    /// Forgets everything (the listener is gone: stale rows are worse than none).
    public mutating func clear() {
        terminals = [:]
    }

    // MARK: - Lines in

    /// One line of `hc events --json` (hc 0.1.20). The first line is every terminal:
    /// `{"seq":…,"terminals":[…]}`. Then one line per change:
    /// `{"jsonrpc":"2.0","method":"event","params":{"type":…,"terminal":"t3","data":{…}}}`.
    public mutating func apply(line: String) -> LineResult {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .skipped
        }
        let before = terminals
        if let list = object["terminals"] as? [Any] {
            terminals = [:]
            for case let item as [String: Any] in list {
                if let terminal = Self.terminal(from: item) { terminals[terminal.address] = terminal }
            }
            return terminals == before ? .unchanged : .changed
        }
        guard let params = object["params"] as? [String: Any], let type = params["type"] as? String else {
            // A heartbeat or another notification without a change in it.
            return object["method"] is String ? .unchanged : .skipped
        }
        if type == "missed" { return .resync }
        let data = params["data"] as? [String: Any] ?? [:]
        guard let address = params["terminal"] as? String ?? data["address"] as? String else { return .unchanged }

        switch type {
        case "created":
            if let terminal = Self.terminal(from: data) { terminals[terminal.address] = terminal }
        case "removed":
            terminals[address] = nil
        case "finished":
            terminals[address]?.isLive = false
        case "status":
            terminals[address]?.status = Self.status(data["status"])
        case "labels":
            if let labels = data["labels"] as? [String: Any] {
                terminals[address]?.labels = labels.compactMapValues { $0 as? String }
            }
        case "foreground":
            // Here `data` is the foreground program itself.
            terminals[address]?.program = Self.program(data)
            if let cwd = data["cwd"] as? String { terminals[address]?.cwd = cwd }
        default:
            // "turn" carries a `state` of its own (the turn's, not the terminal's), so nothing is
            // merged blindly. "title", "lost", "restarted", "keep", "size", "doc": not shown.
            break
        }
        return terminals == before ? .unchanged : .changed
    }

    /// A terminal from herdr-core's JSON, or nil when it has no address.
    private static func terminal(from object: [String: Any]) -> HerdrTerminal? {
        guard let address = object["address"] as? String, !address.isEmpty else { return nil }
        let foreground = object["foreground"] as? [String: Any]
        let created = (object["created_ms"] as? NSNumber)?.int64Value ?? 0
        return HerdrTerminal(
            address: address,
            name: object["name"] as? String,
            parent: object["parent"] as? String,
            isLive: object["state"] as? String == "live",
            status: status(object["status"]),
            labels: (object["labels"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String },
            program: foreground.flatMap(program),
            cwd: foreground?["cwd"] as? String ?? object["cwd"] as? String,
            createdMs: created
        )
    }

    /// `{"app":…,"state":"working"}`, or the plain word some answers use.
    private static func status(_ value: Any?) -> String? {
        if let object = value as? [String: Any] { return object["state"] as? String }
        return value as? String
    }

    private static func program(_ foreground: [String: Any]) -> String? {
        guard let first = (foreground["argv"] as? [Any])?.first as? String, !first.isEmpty else { return nil }
        return first.split(separator: "/").last.map(String.init)
    }

    // MARK: - A tab's rows

    /// The rows under the tab whose own herdr terminal is called `name` (`HerdrCore.terminalName`).
    public func children(ofTerminalNamed name: String) -> HerdrChildren {
        guard let root = terminals.values.first(where: { $0.isLive && $0.name == name }) else { return .none }

        var byParent: [String: [HerdrTerminal]] = [:]
        for terminal in terminals.values where terminal.isLive {
            if let parent = terminal.parent { byParent[parent, default: []].append(terminal) }
        }
        for key in byParent.keys {
            byParent[key]?.sort { ($0.createdMs, $0.address) < ($1.createdMs, $1.address) }
        }

        var rows: [HerdrChildRow] = []
        var liveCount = 0
        var needsYou = false
        var seen: Set<String> = [root.address]

        func walk(_ parent: String, level: Int) {
            for child in byParent[parent] ?? [] {
                // `seen` ends a cycle. Another tab's own terminal is that tab's, with its children.
                guard !seen.contains(child.address), !Self.isTabTerminalName(child.name) else { continue }
                seen.insert(child.address)
                liveCount += 1
                if Self.isMailbox(child) {
                    // Not a row: its children take its place.
                    walk(child.address, level: level)
                    continue
                }
                let mark = HerdrMark(status: child.status)
                if mark == .needsYou { needsYou = true }
                rows.append(HerdrChildRow(address: child.address, name: Self.rowName(child), mark: mark,
                                          level: min(level, Self.maxLevel), folder: child.cwd))
                walk(child.address, level: level + 1)
            }
        }
        walk(root.address, level: 1)

        let more = max(rows.count - Self.maxRows, 0)
        return HerdrChildren(rows: Array(rows.prefix(Self.maxRows)), more: more, liveCount: liveCount, needsYou: needsYou)
    }

    /// A Bot's mailbox (`herdr-bot`'s postkast): a plain program that only takes its workers'
    /// reports, so they don't land on the line the owner is typing on. Its workers are the Bot's
    /// (or the topic's) in every way that matters to the owner. This is the one `herdr-bot` label
    /// the app knows.
    static func isMailbox(_ terminal: HerdrTerminal) -> Bool {
        let role = terminal.labels["role"]
        return role == "postkast" || role == "topic-postkast"
    }

    /// "sg-" and 24 hex digits: the name `HerdrCore.terminalName` gives a tab's own terminal.
    static func isTabTerminalName(_ name: String?) -> Bool {
        guard let name, name.hasPrefix("sg-"), name.count == 27 else { return false }
        return name.dropFirst(3).allSatisfy { $0.isHexDigit }
    }

    /// The row's text: the terminal's name, else its program, else its address.
    static func rowName(_ terminal: HerdrTerminal) -> String {
        for candidate in [terminal.name, terminal.program] {
            let cleaned = InboxText.clean(candidate ?? "", limit: nameLimit)
            if !cleaned.isEmpty { return cleaned }
        }
        return InboxText.clean(terminal.address, limit: nameLimit)
    }
}
