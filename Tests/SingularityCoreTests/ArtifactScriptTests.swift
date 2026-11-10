import Foundation
import Testing
@testable import SingularityCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostFolder = repoRoot.appending(path: "Resources/plugin-host", directoryHint: .isDirectory)
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

private func makeFolder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "artifact-scripts-\(UUID().uuidString)")
    for (path, text) in files {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    return root
}

@Suite struct ArtifactScriptTests {
    @Test func knowsWhatToCompile() {
        for name in ["app.tsx", "util.ts", "View.JSX", "worker.mts"] {
            #expect(ArtifactScripts.isCompiled(URL(fileURLWithPath: "/a/" + name)), "\(name)")
        }
        for name in ["app.js", "types.d.ts", "notes.txt", "ts", "movie.mp4"] {
            #expect(!ArtifactScripts.isCompiled(URL(fileURLWithPath: "/a/" + name)), "\(name)")
        }
        // Compiled scripts are served as JavaScript (macOS thinks .ts is a video).
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/x.ts")) == "text/javascript; charset=utf-8")
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/x.tsx")) == "text/javascript; charset=utf-8")
    }

    @Test func importsWithoutExtensionFindTheFile() throws {
        let root = try makeFolder(["app.tsx": "", "util.ts": "", "ui/index.tsx": "", "both.js": "", "both.ts": "",
                                   "page/index.html": "", ".secret.ts": "", "data.json": "{}"])
        defer { try? FileManager.default.removeItem(at: root) }
        func found(_ path: String) -> String? {
            ArtifactScripts.resolveModule(requestPath: path, root: root).flatMap { ArtifactFiles.relativePath(of: $0, in: root) }
        }
        #expect(found("/app.tsx") == "app.tsx")
        #expect(found("/util") == "util.ts")
        #expect(found("/app") == "app.tsx")
        #expect(found("/ui") == "ui/index.tsx")
        #expect(found("/both") == "both.ts")              // TypeScript first
        #expect(found("/page") == "page/index.html")      // a folder with a page stays that page
        #expect(found("/nope") == nil)
        #expect(found("/data") == nil)                    // only script extensions are guessed
        #expect(found("/util.css") == nil)                // a path with an extension is taken as written
        // The same refusals as for any file.
        #expect(found("/.secret") == nil)
        #expect(found("/../util") == nil)
    }

    @Test func entryScriptsArePagesOnlyWithoutAnHTMLPage() throws {
        let root = try makeFolder(["solo/app.tsx": "", "site/index.html": "", "site/app.tsx": "", "lib/button.tsx": "",
                                   "main.tsx": "", "node_modules/x/index.tsx": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArtifactFiles.isArtifactPage("solo/app.tsx", root: root))
        #expect(ArtifactFiles.isArtifactPage("main.tsx", root: root))
        #expect(ArtifactFiles.isArtifactPage("site/index.html", root: root))
        #expect(!ArtifactFiles.isArtifactPage("site/app.tsx", root: root))   // index.html is the page there
        #expect(!ArtifactFiles.isArtifactPage("lib/button.tsx", root: root)) // a component, not an app
        #expect(!ArtifactFiles.isArtifactPage("node_modules/x/index.tsx", root: root))
        #expect(ArtifactFiles.listPages(in: root) == ["main.tsx", "site/index.html", "solo/app.tsx"])
    }

    @Test func shellPageLoadsTheScriptAndOnlyAValidImportMap() {
        let plain = ArtifactScripts.shellPage(scriptName: "my app.tsx", importMap: nil)
        #expect(plain.contains(#"<script type="module" src="./my%20app.tsx"></script>"#))
        #expect(plain.contains("<div id=\"root\"></div>"))
        #expect(!plain.contains("importmap"))

        let map = #"{"imports":{"react":"https://esm.sh/react@19","x":"</script><script>alert(1)</script>"}}"#
        let page = ArtifactScripts.shellPage(scriptName: "app.tsx", importMap: map)
        #expect(page.contains(#"<script type="importmap">{"imports":{"react":"https://esm.sh/react@19""#))
        #expect(!page.contains("<script>alert(1)"))     // it can't close its own script tag
        #expect(page.contains(#"</script>"#))
        // Not JSON, or not an object: left out.
        #expect(!ArtifactScripts.shellPage(scriptName: "app.tsx", importMap: "</script><b>").contains("importmap"))
        #expect(!ArtifactScripts.shellPage(scriptName: "app.tsx", importMap: "[1]").contains("importmap"))
        // A file name can't break out of the page either.
        #expect(!ArtifactScripts.shellPage(scriptName: "\"><img src=x>.tsx", importMap: nil).contains("<img"))
    }

    @Test func errorModuleCarriesTheMessageSafely() {
        let module = ArtifactScripts.errorModule(file: "app.tsx", message: "Unexpected \"}\" (line 3)\n</script>`${x}`")
        #expect(module.contains(#"Unexpected \"}\" (line 3)\n"#))
        #expect(!module.contains("</script>"))
        #expect(module.contains("export {};"))
    }

    @Test func tidiesTheSandboxPathOutOfMessages() {
        let raw = "error: Unexpected =\n    at /private/var/folders/x/singularity-page-1/in/module.ts:1:10"
        #expect(ArtifactCompiler.tidy(raw, inputName: "module.ts") == "error: Unexpected =\n    at module.ts:1:10")
        #expect(ArtifactCompiler.tidy("plain", inputName: "module.ts") == "plain")
    }
}

@Suite(.enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
struct ArtifactCompilerTests {
    @Test func compilesTSXToAModuleThatKeepsItsImports() throws {
        let root = try makeFolder(["app.tsx": """
            import { useState } from "react";
            import { helper } from "./util";
            import type { Thing } from "./types";
            enum Color { Red, Green }
            export function App({ name }: { name: string }) {
              const [n, setN] = useState<number>(0);
              return <div onClick={() => setN(n + 1)}>Hello {name} {helper(Color.Red)}<></></div>;
            }
            """])
        defer { try? FileManager.default.removeItem(at: root) }
        let js = try ArtifactCompiler.compile(file: root.appending(path: "app.tsx"), runtime: bunPath, hostFolder: hostFolder).get()
        #expect(js.contains(#"from "react""#))
        #expect(js.contains(#"from "./util""#))               // left for the browser to ask for
        #expect(js.contains(#"from "react/jsx-runtime""#))    // what compiled JSX needs, imported
        #expect(!js.contains("./types"))                      // type-only imports are gone
        #expect(!js.contains(": string") && !js.contains("<div"))
        #expect(js.contains("App"))
    }

    @Test func compilesPlainTypeScript() throws {
        let root = try makeFolder(["util.ts": "export const double = (n: number): number => n * 2;\nexport interface X { a: string }\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let js = try ArtifactCompiler.compile(file: root.appending(path: "util.ts"), runtime: bunPath, hostFolder: hostFolder).get()
        #expect(js.contains("double") && js.contains("n * 2"))
        #expect(!js.contains("module.ts"))                     // no trace of the sandbox's copy
        #expect(!js.contains("number") && !js.contains("interface"))
    }

    @Test func syntaxErrorsComeBackWithTheLine() throws {
        let root = try makeFolder(["bad.ts": "const fine = 1;\nconst x: = ;\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ArtifactCompiler.compile(file: root.appending(path: "bad.ts"), runtime: bunPath, hostFolder: hostFolder)
        guard case .failure(.rejected(let message)) = result else {
            Issue.record("expected a compile error, got \(result)")
            return
        }
        #expect(message.contains("Unexpected"))
        #expect(message.contains("2"))                         // the line
        #expect(!message.contains("singularity-page-"))        // no temporary paths
    }

    @Test func missingBunIsSaidPlainly() throws {
        let root = try makeFolder(["a.ts": "export {}"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ArtifactCompiler.compile(file: root.appending(path: "a.ts"), runtime: URL(fileURLWithPath: "/nonexistent/bun"),
                                              hostFolder: hostFolder)
        guard case .failure(.unavailable(let message)) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(message.contains("Bun"))
    }
}
