import Foundation

/// TypeScript and TSX in artifacts: an agent writes `app.tsx`, the artifact server hands the
/// browser plain JavaScript. No build step, no bundle, nothing installed.
///
/// How a page fits together:
/// - Each `.ts`, `.tsx`, `.jsx` or `.mts` file is compiled on its own when the browser asks for
///   it (`ArtifactCompiler`), and stays a module: its imports are left as written.
/// - `import "./util"` (no extension) finds `util.ts`, `util.tsx`, … (`resolveModule`).
/// - `import "react"` is a *bare* name; the browser resolves those through the page's import
///   map. Singularity ships no packages: the map points wherever the author chose (files in the
///   artifacts folder, or a CDN).
/// - Opening a script directly in a tab shows a small page around it (`shellPage`), with the
///   folder's `importmap.json` if there is one.
public enum ArtifactScripts {
    /// Extensions the server compiles before serving.
    public static let compiledExtensions: Set<String> = ["ts", "tsx", "jsx", "mts"]

    public static func isCompiled(_ file: URL) -> Bool {
        // TypeScript declaration files have nothing to run.
        if file.lastPathComponent.lowercased().hasSuffix(".d.ts") { return false }
        return compiledExtensions.contains(file.pathExtension.lowercased())
    }

    /// File names that count as "the app": a new one opens a tab, like a new HTML page, unless
    /// its folder has an HTML page (which then is the page, and loads the script itself).
    public static let entryNames: Set<String> = ["app.tsx", "index.tsx", "main.tsx", "app.jsx", "index.jsx", "main.jsx"]

    public static func isEntryScript(_ relativePath: String) -> Bool {
        entryNames.contains((relativePath as NSString).lastPathComponent.lowercased())
    }

    /// What `import "./util"` may mean, tried in this order after the exact path.
    static let moduleSuffixes = [".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.tsx", "/index.js", "/index.jsx"]

    /// Like `ArtifactFiles.resolve`, and when nothing is at the exact path and its last part has
    /// no extension, also tries the usual script extensions, as bundlers do. Every candidate goes
    /// through `resolve`, so the same containment rules hold.
    public static func resolveModule(requestPath: String, root: URL) -> URL? {
        if let exact = ArtifactFiles.resolve(requestPath: requestPath, root: root) { return exact }
        // Without the query (the handler passes the path only, but be sure).
        var path = requestPath
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, (path as NSString).pathExtension.isEmpty else { return nil }
        for suffix in moduleSuffixes {
            if let file = ArtifactFiles.resolve(requestPath: path + suffix, root: root) { return file }
        }
        return nil
    }

    /// The page shown when a script is opened directly in a tab: an empty `#root` and the script
    /// as a module. `importMap` is the text of the folder's `importmap.json`, if any; it is only
    /// used when it is valid JSON, and is written so that it can't close its own script tag.
    public static func shellPage(scriptName: String, importMap: String?) -> String {
        var map = ""
        if let importMap, let data = importMap.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            // "<" can only appear inside JSON strings, where < means the same.
            let safe = importMap.replacingOccurrences(of: "<", with: "\\u003c")
            map = "\n<script type=\"importmap\">\(safe)</script>"
        }
        let name = LoadErrorPage.escape(scriptName)
        let source = LoadErrorPage.escape(scriptName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scriptName)
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(name)</title>\(map)
        </head>
        <body>
        <div id="root"></div>
        <script type="module" src="./\(source)"></script>
        </body></html>
        """
    }

    /// The module served in place of a file that didn't compile: it puts the compiler's message
    /// on the page and in the console, so neither the owner nor an agent has to guess.
    public static func errorModule(file: String, message: String) -> String {
        func literal(_ text: String) -> String {
            // A JSON string is a JavaScript string; "<" is escaped in case the text ends up inline.
            let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast()).replacingOccurrences(of: "<", with: "\\u003c")
        }
        return """
        // Singularity could not compile this file.
        const file = \(literal(file));
        const message = \(literal(message));
        console.error("Could not compile " + file + "\\n" + message);
        const show = () => {
          const box = document.createElement("pre");
          box.textContent = "Could not compile " + file + "\\n\\n" + message;
          box.style.cssText = "margin:0;padding:12px 16px;background:#3b0d0c;color:#ffd7d5;font:12px/1.5 ui-monospace,monospace;white-space:pre-wrap;position:relative;z-index:2147483647";
          (document.body || document.documentElement).prepend(box);
        };
        if (document.body) show(); else addEventListener("DOMContentLoaded", show);
        export {};
        """
    }
}

/// Compiles one artifact script with the bundled Bun, in the plugin sandbox, on a copy of the
/// file (Bun never reads the artifacts folder itself). Blocking: call it off the main thread.
public enum ArtifactCompiler {
    public static let maxSourceBytes = 2_000_000

    public enum Failure: Error, Equatable, Sendable {
        /// The compiler's own message (a syntax error, with line and column).
        case rejected(String)
        /// Bun is missing, couldn't run, or the file can't be read.
        case unavailable(String)

        public var message: String {
            switch self {
            case .rejected(let text), .unavailable(let text): return text
            }
        }
    }

    /// - Parameters:
    ///   - runtime: the bundled Bun (`Contents/Helpers/bun`).
    ///   - hostFolder: `Contents/Resources/plugin-host` (transpile-artifact.ts, bunfig.toml).
    public static func compile(file: URL, runtime: URL, hostFolder: URL) -> Result<String, Failure> {
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            return .failure(.unavailable("The Bun runtime is missing from this copy of Singularity, so TypeScript can't be compiled."))
        }
        guard let data = try? Data(contentsOf: file), let source = String(data: data, encoding: .utf8) else {
            return .failure(.unavailable("The file couldn't be read as UTF-8 text."))
        }
        guard data.count <= maxSourceBytes else {
            return .failure(.unavailable("The file is larger than 2 MB."))
        }
        // Only the extension matters to Bun; the name stays out of the sandbox.
        let inputName = "module." + file.pathExtension.lowercased()
        switch PluginPageCompiler.runHostScript("transpile-artifact.ts", inputName: inputName, source: source,
                                                runtime: runtime, hostFolder: hostFolder, errorLimit: 4000) {
        case .success(let javascript):
            // Bun starts the output with a comment naming its input ("// ../in/module.ts"),
            // which is the sandbox's copy and means nothing to the reader.
            if javascript.hasPrefix("// "), let end = javascript.firstIndex(of: "\n"),
               javascript[..<end].hasSuffix(inputName) {
                return .success(String(javascript[javascript.index(after: end)...]))
            }
            return .success(javascript)
        case .failure(.refused(let why)):
            // The copy's temporary path means nothing to the reader.
            return .failure(.rejected(tidy(why, inputName: inputName)))
        case .failure(let other):
            return .failure(.unavailable(other.userMessage.replacingOccurrences(of: "page.ts", with: "The file")))
        }
    }

    /// Removes the sandbox's temporary folder from the compiler's messages.
    static func tidy(_ message: String, inputName: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let range = line.range(of: "/" + inputName), let start = line[..<range.lowerBound].lastIndex(of: " ") else {
                return String(line)
            }
            return String(line[...start]) + String(line[line.index(after: range.lowerBound)...])
        }.joined(separator: "\n")
    }
}
