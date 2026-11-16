import Foundation
import SingularityCore
import WebKit

/// Serves the note editor's page to one note's web view, at `singularity-note://editor/`.
///
/// Like `PluginPageServer`: a URL scheme of our own (`WKURLSchemeHandler`), so there is no port,
/// no token, and the address exists only inside that one web view. Two kinds of file are served,
/// GET only:
///
/// - the editor itself: `/` (index.html), `/editor.js`, `/editor.css`, from the app bundle's
///   `Resources/note-editor/` (built by `scripts/build-note-editor.sh`);
/// - the note's pictures: `/file/<path as written in the Markdown>`, from the note's own folder,
///   by `NoteFiles.imageFile` (picture types only, never outside the folder).
///
/// Every response carries `policy`: scripts and styles only from this origin, pictures only from
/// here (or `data:`, which the checkbox tick uses), and no network at all. So whatever a note
/// contains, the page can't fetch anything, and opening a note can't tell any server about it.
@MainActor
final class NotePageServer: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "singularity-note"
    nonisolated static let host = "editor"
    nonisolated static let rootURL = URL(string: "\(scheme)://\(host)/")!

    /// The folder with index.html, editor.js and editor.css.
    private let editorFolder: URL
    /// The note's folder and its path inside it, asked for at each request (a rename changes it).
    private let location: @MainActor () -> NoteFiles.Location

    init(editorFolder: URL, location: @escaping @MainActor () -> NoteFiles.Location) {
        self.editorFolder = editorFolder
        self.location = location
    }

    /// The editor inside the app bundle. A bare debug binary has none (see `NoteHost.editorIsBundled`).
    nonisolated static var bundledEditorFolder: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/note-editor", directoryHint: .isDirectory)
    }

    nonisolated static func isOwn(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme && url?.host()?.lowercased() == host
    }

    nonisolated static let policy =
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        + "font-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'"

    // MARK: WKURLSchemeHandler

    /// Requests WebKit started and hasn't stopped: answering a stopped one raises an exception.
    private var running: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        running.insert(id)
        let request = urlSchemeTask.request
        let editorFolder = editorFolder, location = location()
        Task {
            // A nonisolated async function: the file is read off the main thread.
            let reply = await Self.reply(to: request, editorFolder: editorFolder, location: location)
            guard running.remove(id) != nil else { return }
            urlSchemeTask.didReceive(reply.response(for: request.url ?? Self.rootURL))
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

        func response(for url: URL) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(body.count),
                "Content-Security-Policy": NotePageServer.policy,
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "no-store",
            ])!
        }
    }

    private nonisolated static let editorFiles = ["/": "index.html", "/editor.js": "editor.js", "/editor.css": "editor.css"]
    private nonisolated static let filePrefix = "/file/"

    nonisolated static func reply(to request: URLRequest, editorFolder: URL, location: NoteFiles.Location) async -> Reply {
        func text(_ status: Int, _ message: String) -> Reply {
            Reply(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
        }
        guard (request.httpMethod ?? "GET").uppercased() == "GET" else { return text(405, "Method Not Allowed") }
        guard let url = request.url, isOwn(url),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            return text(404, "Not Found")
        }
        if let name = editorFiles[path.isEmpty ? "/" : path] {
            let file = editorFolder.appending(path: name)
            guard let data = try? Data(contentsOf: file) else { return text(404, "Not Found") }
            return Reply(status: 200, contentType: ArtifactFiles.mimeType(for: file), body: data)
        }
        if path.hasPrefix(filePrefix), let source = String(path.dropFirst(filePrefix.count)).removingPercentEncoding,
           let file = NoteFiles.imageFile(source: source, notePath: location.path, root: location.root),
           let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= NoteFiles.maxImageBytes,
           let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
            return Reply(status: 200, contentType: ArtifactFiles.mimeType(for: file), body: data)
        }
        return text(404, "Not Found")
    }
}
