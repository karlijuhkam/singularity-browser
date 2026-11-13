import Foundation
import Testing
@testable import SingularityCore

@Suite struct PluginPanelManifestTests {
    /// A plugin folder named `t` with background.ts, panel.html and the given `plugin.json` pieces.
    private func load(panel: String? = nil, permissions: String = "{}", background: Bool = true) throws -> PluginManifest {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sing-panel-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "t", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("// stub".utf8).write(to: dir.appending(path: "background.ts"))
        try Data("<p>hi</p>".utf8).write(to: dir.appending(path: "panel.html"))
        var json = #"{"id":"t","name":"T","version":"1","description":"d","author":"a","permissions":\#(permissions)"#
        if background { json += #","background":"background.ts""# }
        if let panel { json += #","panel":\#(panel)"# }
        json += "}"
        try Data(json.utf8).write(to: dir.appending(path: "plugin.json"))
        return try PluginManifest.load(from: dir)
    }

    private let goodPanel = #"{"page":"panel.html","title":"Assistant"}"#

    @Test func decodesWithAndWithoutTheNewKeys() throws {
        let plain = try load()
        #expect(plain.panel == nil)
        #expect(plain.permissions.programs == [] && plain.permissions.programEnv == [])
        #expect(!plain.showsSpaceSwitches)
        let full = try load(panel: goodPanel, permissions: #"{"programs":["claude"],"programEnv":["API_BASE"]}"#)
        #expect(full.panel == .init(page: "panel.html", title: "Assistant"))
        #expect(full.permissions.programs == ["claude"])
        #expect(full.permissions.programEnv == ["API_BASE"])
    }

    @Test func unknownPermissionStillFails() {
        #expect(throws: PluginError.unknownPermission("cookies")) { _ = try load(permissions: #"{"cookies":[]}"#) }
    }

    @Test func showsSpaceSwitchesOnlyWithAPageScript() throws {
        var m = try load()
        #expect(!m.showsSpaceSwitches)
        m.page = .init(script: "page.ts", sites: [])
        #expect(m.showsSpaceSwitches)
    }

    // MARK: programs

    @Test func programNamesMustBeValidAndNotRefused() throws {
        for bad in ["bash", "../x", "a b", "-c", "python3.12"] {
            #expect(throws: PluginError.refusedProgram(bad), Comment(rawValue: bad)) {
                _ = try load(permissions: #"{"programs":["\#(bad)"]}"#)
            }
        }
        #expect(try load(permissions: #"{"programs":["claude"]}"#).permissions.programs == ["claude"])
    }

    @Test func noDuplicateProgramsAndAtMostFour() throws {
        #expect(throws: PluginError.refusedProgram("a")) { _ = try load(permissions: #"{"programs":["a","b","a"]}"#) }
        #expect(throws: PluginError.refusedProgram("e")) { _ = try load(permissions: #"{"programs":["a","b","c","d","e"]}"#) }
        #expect(try load(permissions: #"{"programs":["a","b","c","d"]}"#).permissions.programs.count == 4)
    }

    @Test func programsNeedABackgroundProgram() throws {
        #expect(throws: PluginError.programsNeedBackground) {
            _ = try load(permissions: #"{"programs":["claude"]}"#, background: false)
        }
        #expect(try load(background: false).permissions.programs.isEmpty)
    }

    // MARK: programEnv

    @Test func programEnvNamesAreChecked() throws {
        let refused = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL", "PWD", "DYLD_X", "LD_PRELOAD",
                       "SINGULARITY_HOME", "SINGULARITY_", "lower", "1A", "_A", "A-B", ""]
        for bad in refused {
            #expect(throws: PluginError.invalidProgramEnv(bad), Comment(rawValue: bad)) {
                _ = try load(permissions: #"{"programs":["claude"],"programEnv":["\#(bad)"]}"#)
            }
        }
        let long = "A" + String(repeating: "B", count: 64)
        #expect(throws: PluginError.invalidProgramEnv(long)) {
            _ = try load(permissions: #"{"programs":["claude"],"programEnv":["\#(long)"]}"#)
        }
        let ok = "A" + String(repeating: "B", count: 63)
        #expect(try load(permissions: #"{"programs":["claude"],"programEnv":["\#(ok)","A_1"]}"#).permissions.programEnv.count == 2)
    }

    @Test func programEnvNeedsPrograms() {
        #expect(throws: PluginError.invalidProgramEnv("API_BASE")) { _ = try load(permissions: #"{"programEnv":["API_BASE"]}"#) }
    }

    // MARK: panel

    @Test func panelTitleRules() throws {
        for bad in ["", "   ", String(repeating: "x", count: 41), "a\\nb"] {
            #expect(throws: PluginError.invalidPanelTitle, Comment(rawValue: bad)) {
                _ = try load(panel: #"{"page":"panel.html","title":"\#(bad)"}"#)
            }
        }
        _ = try load(panel: #"{"page":"panel.html","title":"\#(String(repeating: "x", count: 40))"}"#)
    }

    @Test func aPanelNeedsABackgroundProgram() throws {
        // Its page exists only while the background runs: without one it would never show.
        #expect(throws: PluginError.panelNeedsBackground) { _ = try load(panel: goodPanel, background: false) }
        #expect(try load(panel: goodPanel).panel != nil)
        #expect(PluginError.panelNeedsBackground.userMessage == "its panel needs a background program")
    }

    @Test func panelPageMustBeAFileInTheFolder() {
        for bad in ["nope.html", "../x.html", "/etc/hosts"] {
            #expect(throws: PluginError.missingFile(bad), Comment(rawValue: bad)) {
                _ = try load(panel: #"{"page":"\#(bad)","title":"A"}"#)
            }
        }
    }

    @Test func programChecksComeAfterCommandsAndBeforeFiles() {
        // A bad program wins over a missing panel file; a bad command wins over a bad program.
        #expect(throws: PluginError.refusedProgram("bash")) {
            _ = try load(panel: #"{"page":"nope.html","title":"A"}"#, permissions: #"{"programs":["bash"]}"#)
        }
        #expect(throws: PluginError.refusedCommand("bash")) {
            _ = try load(permissions: #"{"commands":{"bash":["x"]},"programs":["bash"]}"#)
        }
    }

    @Test func errorMessages() {
        #expect(PluginError.refusedProgram("x").userMessage == "it asks to keep “x” running, which plugins may not")
        #expect(PluginError.programsNeedBackground.userMessage
                == "it asks to keep a program running but has no background program")
        #expect(PluginError.invalidProgramEnv("HOME").userMessage
                == "it asks to set “HOME” for its program, which plugins may not")
        #expect(PluginError.invalidPanelTitle.userMessage == "its panel needs a title of 1 to 40 characters")
    }

    // MARK: approval text

    @Test func descriptionLines() {
        let p = PluginManifest.Permissions(programs: ["codex", "claude"], programEnv: ["B_SET", "A_SET"])
        let lines = PermissionDescriptions.lines(for: p, commandPaths: ["claude": "/opt/bin/claude"], hasPanel: true)
        #expect(lines == [
            "Shows its own panel and tab",
            "Keeps /opt/bin/claude running and talks to it. This program is not sandboxed: it uses the internet and acts as you",
            "Keeps codex running and talks to it. This program is not sandboxed: it uses the internet and acts as you",
            "Passes these settings to it: A_SET, B_SET",
            "Its background program never uses the internet; the programs it runs can",
        ])
        #expect(PermissionDescriptions.lines(for: .init(), commandPaths: [:]) == ["Its background program never uses the internet"])
    }

    // MARK: pinning and launching

    @Test func programsArePinnedButNeverRunnable() throws {
        let m = try load(panel: goodPanel, permissions: #"{"programs":["claude"]}"#)
        let scan = PluginScan(folder: URL(filePath: "/x"), manifest: .success(m), files: .success(.init(fingerprint: "f", fileHashes: [:])))
        let review = try PluginReview.prepare(scan: scan, resolve: { $0 == "claude" ? "/opt/bin/claude" : nil }).get()
        #expect(review.commandPaths == ["claude": "/opt/bin/claude"])
        #expect(review.canApprove)
        let missing = try PluginReview.prepare(scan: scan, resolve: { _ in nil }).get()
        #expect(missing.missingCommands == ["claude"] && !missing.canApprove)
        #expect(!CommandPolicy.allows(command: "claude", arguments: [], declared: m.permissions.commands))
    }

    @Test func programsWidenApproval() {
        let approved = PluginManifest.Permissions(programs: ["a"], programEnv: ["X"])
        #expect(!PluginManifest.Permissions(programs: ["a"], programEnv: ["X"]).widens(approved))
        #expect(!PluginManifest.Permissions().widens(approved))
        #expect(PluginManifest.Permissions(programs: ["a", "b"], programEnv: ["X"]).widens(approved))
        #expect(PluginManifest.Permissions(programs: ["a"], programEnv: ["X", "Y"]).widens(approved))
    }

    @Test func aPanelPluginIsNotSwitchedOffWithoutSpaces() throws {
        let withPanel = try load(panel: goodPanel)
        let without = try load()
        func approval(_ m: PluginManifest) -> PluginApproval {
            PluginApproval(fingerprint: "f", permissions: m.permissions, commandPaths: [:], enabledSpaces: [],
                           developmentMode: false, approvedAt: Date(timeIntervalSince1970: 0))
        }
        #expect(PluginLaunch.decide(status: .approved, approval: approval(withPanel), manifest: withPanel) == .launch)
        #expect(PluginLaunch.decide(status: .approved, approval: approval(without), manifest: without) == .switchedOff)
    }

    @Test func aPinnedProgramThatVanishedBlocksLaunch() throws {
        let m = try load(panel: goodPanel, permissions: #"{"programs":["claude"]}"#)
        let gone = PluginApproval(fingerprint: "f", permissions: m.permissions, commandPaths: ["claude": "/opt/bin/claude"],
                                  enabledSpaces: [], developmentMode: false, approvedAt: Date(timeIntervalSince1970: 0))
        #expect(PluginLaunch.decide(status: .approved, approval: gone, manifest: m, isExecutable: { _ in false })
                == .blocked("claude isn't at /opt/bin/claude any more — review to re-approve"))
        let unpinned = PluginApproval(fingerprint: "f", permissions: m.permissions, commandPaths: [:],
                                      enabledSpaces: [], developmentMode: false, approvedAt: Date(timeIntervalSince1970: 0))
        #expect(PluginLaunch.decide(status: .approved, approval: unpinned, manifest: m)
                == .blocked("no approved path for claude — review to re-approve"))
    }

    // MARK: packages

    @Test func installOmitsOptionalPackages() {
        #expect(PluginPackages.installArguments(hostFolder: "/h").contains("--omit=optional"))
    }

    @Test func lockedCountLeavesOutOptionalOnlyPackages() throws {
        let integrity = "sha512-AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw=="
        func entry(_ spec: String, _ meta: String) -> String { #"["\#(spec)", "", \#(meta), "\#(integrity)"]"# }
        let lock = """
        {"lockfileVersion": 1, "workspaces": {"": {"name": "t", "dependencies": {"a": "1.0.0"}}},
         "packages": {
           "a": \(entry("a@1.0.0", #"{"dependencies": {"b": "^1.0.0"}, "optionalDependencies": {"opt": "^1.0.0"}}"#)),
           "b": \(entry("b@1.0.0", "{}")),
           "opt": \(entry("opt@1.0.0", #"{"dependencies": {"deep": "^1.0.0"}}"#)),
           "deep": \(entry("deep@1.0.0", "{}"))
         }}
        """
        #expect(try PluginPackages.checkLockfile(Data(lock.utf8), dependencies: ["a": "1.0.0"]) == 2)
    }
}
