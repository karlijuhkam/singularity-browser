import Foundation
import SingularityCore

// The fixture program in the repository, found from this file's location.
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let echoProgram = repoRoot.appending(path: "Tests/SingularityCoreTests/Fixtures/echo-program.sh")

/// A data folder (`/private/tmp/sg-pn-…`, a real path as the sandbox sees it) with one plugin,
/// "panelfix": a panel page, a background that answers panel messages, posts to its page and
/// starts the fixture program, and the fixture program itself outside the plugins folder.
struct PanelWorkspace {
    static let id = "panelfix"
    let root: URL
    let program: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }

    init() throws {
        let fm = FileManager.default
        root = URL(filePath: "/private/tmp/sg-pn-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        program = root.appending(path: "fixture-program")
        let plugin = Paths(root: root).pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: plugin.appending(path: path))
        }
        try write("plugin.json", """
            {"id": "panelfix", "name": "Panel Fixture", "version": "1.0.0", "description": "A test panel plugin.",
             "author": "Tests", "background": "background.ts",
             "panel": {"page": "panel.html", "title": "Fixture Panel"},
             "permissions": {"programs": ["fixture"], "programEnv": ["FIXTURE_SETTING"]}}
            """)
        try write("background.ts", """
            import { singularity } from "singularity";

            async function runFixture(args: string[]) {
              const program = singularity.spawn("fixture", args, { env: { FIXTURE_SETTING: "yes", NOT_LISTED: "no" } });
              let error: string | null = null;
              program.on("error", (e: Error) => { error = e.message; });
              const exited = new Promise<number | null>((resolve) => program.on("exit", (code: number | null) => resolve(code)));
              program.stdin.end();
              const chunks: Buffer[] = [];
              const reading = (async () => { for await (const chunk of program.stdout) chunks.push(chunk); })();
              const code = await exited;
              await reading;
              return { error, code, text: Buffer.concat(chunks).toString() };
            }

            singularity.onPageMessage(async ({ tabID, payload }) => {
              const p = payload as any;
              if (p && typeof p === "object" && "post" in p) {
                singularity.panel.post({ pushed: p.post });
                return { posted: true };
              }
              if (p === "env") return await runFixture(["env"]);
              if (p === "crash") {
                setTimeout(() => process.exit(1), 50);
                return { crashing: true };
              }
              return { tabID, echo: payload };
            });
            """)
        try write("panel.html", """
            <!doctype html>
            <html><head><title>loading</title><script type="module" src="./panel.js"></script></head><body></body></html>
            """)
        try write("panel.js", """
            window.__loadID = Math.random().toString(36).slice(2);
            window.singularity.onMessage((message) => { document.title = "post:" + JSON.stringify(message); });
            window.singularity.send({ hello: "page" }).then(
              (reply) => { window.__reply = reply; },
              (error) => { window.__reply = { error: String(error) }; });
            """)
        try fm.copyItem(at: echoProgram, to: program)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }

    private struct NotReady: Error, CustomStringConvertible { let description: String }

    /// Approves the plugin as it is now, on in no Space, with the fixture program pinned: what
    /// `PluginManager.approve` would save, written before the manager starts.
    func approve() throws {
        let scan = PluginScan.scan(folder: plugin)
        guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
            throw NotReady(description: "the fixture plugin doesn't scan: \(scan.manifest)")
        }
        let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                      commandPaths: ["fixture": program.path], enabledSpaces: [],
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
