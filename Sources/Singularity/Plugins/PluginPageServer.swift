import Foundation
import SingularityCore
import WebKit

/// Serves one plugin's own page (its `panel.page` and every file it loads) from the plugin's
/// folder, at `singularity-plugin://<plugin id>/<path>`. `/` is the page itself.
///
/// How it works: WebKit lets an app answer the requests of a URL scheme of its own
/// (`WKURLSchemeHandler`, registered on the web view's configuration by `PluginPageHost`). So there
/// is no port, no token and no Space: the scheme exists only inside that one web view.
///
/// What is served, by the same rules as artifacts (`ArtifactFiles.resolve`): regular files inside
/// the folder after symlinks are resolved; never a path with "..", a hidden file or folder (".git"),
/// or a link pointing out. `plugin.json`, `background.ts` and the rest are the plugin's own reviewed
/// source, so they may be served. GET only (anything else 405), missing files 404.
///
/// `.ts/.tsx/.jsx/.mts` are compiled on request, one file in, one module out, exactly as for
/// artifacts (`compile`, normally `ArtifactScriptService`). A page written as a script gets the
/// artifacts' small shell page, with the import map built from the plugin's declared packages.
///
/// Every response carries `policy(nonce:)`: scripts, styles, images and fonts only from the
/// plugin's own origin, no network (`connect-src 'none'`), no frames, no forms. Inline scripts
/// run only with the response's nonce, which only the shell page's two script tags have.
@MainActor
final class PluginPageServer: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "singularity-plugin"

    /// Turns one script file into JavaScript (see `ArtifactScriptService.javascript(for:)`).
    typealias Compile = @Sendable (URL) async -> Result<String, ArtifactCompiler.Failure>

    let pluginID: String
    let folder: URL
    /// The page, relative to the folder (`panel.page`, e.g. "panel.tsx").
    let entry: String
    private let compile: Compile

    /// Requests WebKit started and hasn't stopped. Answering a stopped one raises an exception
    /// (WebKit's rule), and a compile can take a moment, so each answer checks first.
    private var running: Set<ObjectIdentifier> = []

    init(pluginID: String, folder: URL, entry: String, compile: @escaping Compile) {
        self.pluginID = pluginID
        self.folder = folder
        self.entry = entry
        self.compile = compile
    }

    /// The address of the page itself.
    nonisolated static func rootURL(pluginID: String) -> URL {
        URL(string: "\(scheme)://\(pluginID)/")!
    }

    /// Whether `url` is on this plugin's origin.
    nonisolated static func isOwn(_ url: URL?, pluginID: String) -> Bool {
        url?.scheme?.lowercased() == scheme && url?.host()?.lowercased() == pluginID
    }

    /// The Content-Security-Policy of every response. WebKit counts `'self'` as the custom scheme's
    /// origin (`singularity-plugin://<id>`): `PluginPageTests` loads a page whose own modules and
    /// package files need it, so the origin isn't named explicitly.
    nonisolated static func policy(nonce: String) -> String {
        "default-src 'none'; script-src 'self' 'nonce-\(nonce)'; style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data:; font-src 'self'; connect-src 'none'; base-uri 'none'; "
            + "form-action 'none'; frame-src 'none'"
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        running.insert(id)
        let request = urlSchemeTask.request
        let pluginID = pluginID, folder = folder, entry = entry, compile = compile
        Task {
            // Runs off the main thread (a nonisolated async function): file reads and compiling.
            let reply = await Self.reply(to: request, pluginID: pluginID, folder: folder, entry: entry, compile: compile)
            guard running.remove(id) != nil else { return }   // WebKit stopped it meanwhile
            urlSchemeTask.didReceive(reply.response(for: request.url ?? Self.rootURL(pluginID: pluginID)))
            urlSchemeTask.didReceive(reply.body)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: Answers

    struct Reply: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        /// Fresh for every response; only the shell page uses it.
        var nonce: String

        func response(for url: URL) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(body.count),
                "Content-Security-Policy": PluginPageServer.policy(nonce: nonce),
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "no-store",
            ])!
        }
    }

    nonisolated static func reply(to request: URLRequest, pluginID: String, folder: URL, entry: String,
                                  compile: Compile) async -> Reply {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func text(_ status: Int, _ message: String) -> Reply {
            Reply(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8), nonce: nonce)
        }
        guard (request.httpMethod ?? "GET").uppercased() == "GET" else { return text(405, "Method Not Allowed") }
        guard let url = request.url, isOwn(url, pluginID: pluginID),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            return text(404, "Not Found")
        }

        // "/" is the page itself.
        if path.isEmpty || path == "/" {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "%")
            guard let encoded = entry.addingPercentEncoding(withAllowedCharacters: allowed),
                  !entry.isEmpty, let file = ArtifactFiles.resolve(requestPath: "/" + encoded, root: folder) else {
                return text(404, "Not Found")
            }
            if ArtifactScripts.isCompiled(file) {
                let page = ArtifactScripts.shellPage(scriptName: entry, importMap: importMap(folder: folder), nonce: nonce)
                return Reply(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8), nonce: nonce)
            }
            return serve(file, nonce: nonce) ?? text(404, "Not Found")
        }

        // `resolveModule`: "./util" also finds util.ts, util.tsx, … as an import in TypeScript expects.
        guard let file = ArtifactScripts.resolveModule(requestPath: path, root: folder) else { return text(404, "Not Found") }
        if ArtifactScripts.isCompiled(file) {
            let javascript: String
            switch await compile(file) {
            case .success(let compiled):
                javascript = compiled
            case .failure(let failure):
                // Still a module, so the page shows the compiler's message instead of a silent failure.
                let name = ArtifactFiles.relativePath(of: file, in: folder) ?? file.lastPathComponent
                javascript = ArtifactScripts.errorModule(file: name, message: failure.message)
            }
            return Reply(status: 200, contentType: "text/javascript; charset=utf-8", body: Data(javascript.utf8), nonce: nonce)
        }
        return serve(file, nonce: nonce) ?? text(404, "Not Found")
    }

    private nonisolated static func serve(_ file: URL, nonce: String) -> Reply? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return Reply(status: 200, contentType: ArtifactFiles.mimeType(for: file), body: data, nonce: nonce)
    }

    /// The import map for the shell page: bare names ("preact", "preact/hooks") to files under
    /// `/node_modules/`, for the packages the plugin's `package.json` declares. Only after that file
    /// (and `bun.lock`) pass the same checks as at approval (`PluginPackages.list`), so every name
    /// is a valid npm name. nil when there is nothing to map.
    nonisolated static func importMap(folder: URL) -> String? {
        guard let packages = try? PluginPackages.list(folder: folder), !packages.isEmpty else { return nil }
        let names = packages.map(\.name).filter { PluginPackages.isValidName($0) && !$0.contains("..") }
        let map = PluginImportMap.make(dependencies: names) { name in
            // Same containment rules as any served file: a link out of the folder reads as missing.
            guard let file = ArtifactFiles.resolve(requestPath: "/node_modules/\(name)/package.json", root: folder),
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
                  size <= 1 << 20 else { return nil }
            return try? Data(contentsOf: file)
        }
        guard !map.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["imports": map],
                                                      options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
