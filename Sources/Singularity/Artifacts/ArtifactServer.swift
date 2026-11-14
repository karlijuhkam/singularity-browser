import FlyingFox
import FlyingSocks
import Foundation
import SingularityCore
import os

/// Visible with: log stream --level debug --predicate 'subsystem == "dev.roosa.Singularity" AND category == "artifacts"'
let artifactLog = Logger(subsystem: "dev.roosa.Singularity", category: "artifacts")

/// A file server for one Space's `artifacts/` folder, on 127.0.0.1 and a random free port.
///
/// It serves files: no directory listings, no uploads. The one thing beyond files: inside an
/// **app** (a folder with a `wrangler.jsonc`, see `ArtifactApps`), a request the folder has no
/// file for goes to that app's Worker (`AppWorkers`). Outside an app nothing else is answered.
/// Every request must carry the Space's token (see `ArtifactAuth`).
actor ArtifactServer {
    private let server: HTTPServer
    private var runTask: Task<Void, Never>?

    init(root: URL, token: String, scripts: ArtifactScriptService?, apps: AppWorkers? = nil) throws {
        server = HTTPServer(
            // Port 0 asks the OS for any free port; 127.0.0.1 means only this Mac can connect.
            address: try .inet(ip4: "127.0.0.1", port: 0),
            logger: .disabled,
            handler: ArtifactFileHandler(root: root, token: token, scripts: scripts, apps: apps)
        )
    }

    /// Starts listening and returns the port the OS picked.
    func start() async throws -> UInt16 {
        runTask = Task { [server] in
            do {
                try await server.run()
            } catch {
                NSLog("Singularity: artifact server stopped: \(error)")
            }
        }
        try await server.waitUntilListening()
        guard case .ip4(_, let port)? = await server.listeningAddress else {
            throw CocoaError(.featureUnsupported)
        }
        return port
    }

    func stop() async {
        await server.stop()
        runTask?.cancel()
    }
}

/// Answers one request: check host and token, map the path to a file, stream it back.
struct ArtifactFileHandler: HTTPHandler {
    let root: URL
    let token: String
    /// Compiles TypeScript/TSX on the way out (nil in tests that don't need it).
    let scripts: ArtifactScriptService?
    /// The Space's app Workers. Nil: no folder is treated as an app (files only, as before apps).
    var apps: AppWorkers? = nil

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await respond(to: request)
        // Logs whether credentials were present, never their values.
        artifactLog.debug("\(request.method.rawValue, privacy: .public) \(request.path, privacy: .public) → \(response.statusCode.code) (auth header: \(request.headers[.authorization] != nil), cookie: \(request.headers[.cookie]?.contains(ArtifactAuth.cookieName) == true))")
        return response
    }

    private func respond(to request: HTTPRequest) async throws -> HTTPResponse {
        guard ArtifactAuth.isAllowedHost(request.headers[.host]) else {
            return Self.text(.forbidden, "Forbidden")
        }

        // CORS preflight from another origin. We send no Access-Control-Allow-* headers, so the
        // browser refuses the cross-origin request, the same as for any ordinary website.
        if request.method == .OPTIONS {
            return HTTPResponse(statusCode: .noContent)
        }
        // The app this path is in, if any ("/firma/api/x" → app "firma", the Worker's path "/api/x").
        let app = apps == nil ? nil : ArtifactApps.app(forRequestPath: request.path, root: root)
        let reads = request.method == .GET || request.method == .HEAD
        // Outside an app: files only, so nothing but GET and HEAD.
        guard reads || app != nil else {
            return Self.text(.methodNotAllowed, "Method Not Allowed")
        }
        guard ArtifactAuth.isAuthorized(
            authorization: request.headers[.authorization],
            cookie: request.headers[.cookie],
            token: token
        ) else {
            return Self.text(.unauthorized, "Unauthorized")
        }
        // A request that proved itself with the header (the tab's first page load, made by the app)
        // gets the cookie, so the page's own sub-requests (and later reloads) are authorised too.
        let setCookie: String? = request.headers[.authorization] != nil
            ? "\(ArtifactAuth.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict" : nil

        // `resolveModule`: "./util" also finds util.ts, util.tsx, … as an import in TypeScript expects.
        let found = reads ? ArtifactScripts.resolveModule(requestPath: request.path, root: root) : nil
        if let apps, let app,
           ArtifactApps.route(method: request.method.rawValue, hasFile: found != nil, inApp: true) == .worker,
           !Self.isMissingPage(request) {
            return try await workerResponse(apps: apps, app: app.app, path: app.rest, request: request, setCookie: setCookie)
        }
        guard let file = found else {
            // A page load gets a readable page (the tab's file was deleted); everything else plain text.
            guard request.method == .GET, ArtifactMissingPage.wantsHTML(accept: request.headers[HTTPHeader("Accept")]) else {
                return Self.text(.notFound, "Not Found")
            }
            var headers = HTTPHeaders()
            headers[.contentType] = "text/html; charset=utf-8"
            headers[.cacheControl] = "no-store"
            headers[HTTPHeader("X-Content-Type-Options")] = "nosniff"
            if let setCookie { headers[HTTPHeader("Set-Cookie")] = setCookie }
            return HTTPResponse(statusCode: .notFound, headers: headers,
                                body: Data(ArtifactMissingPage.html(requestPath: request.path).utf8))
        }

        var headers = HTTPHeaders()
        headers[.contentType] = ArtifactFiles.mimeType(for: file)
        // Artifacts change while you look at them; never serve a stale copy.
        headers[.cacheControl] = "no-store"
        headers[HTTPHeader("X-Content-Type-Options")] = "nosniff"
        if let setCookie { headers[HTTPHeader("Set-Cookie")] = setCookie }

        // TypeScript, TSX and JSX are compiled before they are served (ArtifactScripts).
        if let scripts, ArtifactScripts.isCompiled(file) {
            if request.method == .HEAD { return HTTPResponse(statusCode: .ok, headers: headers) }
            // Opened in a tab (a page load, not an import): a small page that loads the script.
            if ArtifactMissingPage.wantsHTML(accept: request.headers[HTTPHeader("Accept")]) {
                let importMap = try? String(contentsOf: file.deletingLastPathComponent().appending(path: "importmap.json"), encoding: .utf8)
                headers[.contentType] = "text/html; charset=utf-8"
                return HTTPResponse(statusCode: .ok, headers: headers,
                                    body: Data(ArtifactScripts.shellPage(scriptName: file.lastPathComponent, importMap: importMap).utf8))
            }
            headers[.contentType] = "text/javascript; charset=utf-8"
            switch await scripts.javascript(for: file) {
            case .success(let javascript):
                return HTTPResponse(statusCode: .ok, headers: headers, body: Data(javascript.utf8))
            case .failure(let failure):
                // Still a module, so the page shows the compiler's message instead of a silent failure.
                let name = ArtifactFiles.relativePath(of: file, in: root) ?? file.lastPathComponent
                return HTTPResponse(statusCode: .ok, headers: headers,
                                    body: Data(ArtifactScripts.errorModule(file: name, message: failure.message).utf8))
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        // Tells the browser it may ask for parts of the file (needed to seek in video and audio).
        headers[.acceptRanges] = "bytes"

        switch ArtifactRange.parse(header: request.headers[.range], fileSize: size) {
        case .unsatisfiable:
            headers[.contentRange] = "bytes */\(size)"
            headers[.contentType] = "text/plain; charset=utf-8"
            return HTTPResponse(statusCode: .rangeNotSatisfiable, headers: headers, body: Data("Range Not Satisfiable".utf8))
        case .partial(let range):
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
            if request.method == .HEAD {
                headers[.contentLength] = String(range.count)
                return HTTPResponse(statusCode: .partialContent, headers: headers)
            }
            return HTTPResponse(statusCode: .partialContent, headers: headers,
                                body: try HTTPBodySequence(file: file, range: range.lowerBound..<(range.upperBound + 1)))
        case .full:
            if request.method == .HEAD {
                headers[.contentLength] = String(size)
                return HTTPResponse(statusCode: .ok, headers: headers)
            }
            return HTTPResponse(statusCode: .ok, headers: headers, body: try HTTPBodySequence(file: file))
        }
    }

    /// A page load of an `.html` path that has no file. Inside an app this still gets the
    /// "file is missing" page instead of going to the Worker: pages are files (the Worker is the
    /// API behind them), and a tab whose file was deleted must say so.
    private static func isMissingPage(_ request: HTTPRequest) -> Bool {
        guard request.method == .GET, ArtifactMissingPage.wantsHTML(accept: request.headers[HTTPHeader("Accept")]) else {
            return false
        }
        let ext = (request.path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    /// Hands a request to an app's Worker and turns its answer into ours.
    private func workerResponse(apps: AppWorkers, app: String, path: String, request: HTTPRequest,
                                setCookie: String?) async throws -> HTTPResponse {
        // The Host header was checked above (loopback only), so this is the server's own origin.
        let origin = "http://" + (request.headers[.host] ?? "127.0.0.1")
        guard ArtifactApps.mayReachWorker(method: request.method.rawValue,
                                          secFetchSite: request.headers[HTTPHeader("Sec-Fetch-Site")],
                                          origin: request.headers[HTTPHeader("Origin")],
                                          serverOrigin: origin) else {
            return Self.text(.forbidden, "Forbidden: an app's Worker only answers its own pages.")
        }
        // A declared size over the limit is refused before the body is read into memory.
        let limit = AppWorkerProcess.Limits().bodyBytes
        let tooLarge = HTTPStatusCode(413, phrase: "Payload Too Large")
        if let declared = request.bodySequence.count, declared > limit {
            return Self.text(tooLarge, "The request body is over the 8 MB limit.")
        }
        let body = try await request.bodyData
        guard body.count <= limit else {
            return Self.text(tooLarge, "The request body is over the 8 MB limit.")
        }

        // The Worker sees the app as if it were at the root of the site, as it will be on
        // Cloudflare: "/firma/api/x?y=1" arrives as "/api/x?y=1".
        var url = origin + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        let query = request.target.query(percentEncoded: true)
        if !query.isEmpty { url += "?" + query }
        var headers: [(String, String)] = []
        for name in request.headers.keys {
            for value in request.headers.values(for: name) { headers.append((name.rawValue, value)) }
        }
        let answer = await apps.handle(app: app, request: AppHTTPRequest(
            method: request.method.rawValue, url: url, headers: ArtifactApps.headersForWorker(headers),
            body: body.isEmpty ? nil : body))

        var out = HTTPHeaders()
        for (name, value) in ArtifactApps.headersFromWorker(answer.headers) {
            // The server writes these two itself from the body it sends.
            let lower = name.lowercased()
            if lower == "content-length" || lower == "transfer-encoding" { continue }
            out.addValue(value, for: HTTPHeader(name))
        }
        // An API's answers change; never a stale copy unless the Worker says otherwise.
        if out[.cacheControl] == nil { out[.cacheControl] = "no-store" }
        out[HTTPHeader("X-Content-Type-Options")] = "nosniff"
        if let setCookie { out.addValue(setCookie, for: HTTPHeader("Set-Cookie")) }
        let phrase = HTTPURLResponse.localizedString(forStatusCode: answer.status).capitalized
        return HTTPResponse(statusCode: HTTPStatusCode(answer.status, phrase: phrase), headers: out,
                            body: request.method == .HEAD ? Data() : answer.body)
    }

    private static func text(_ status: HTTPStatusCode, _ message: String) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain; charset=utf-8"
        return HTTPResponse(statusCode: status, headers: headers, body: Data(message.utf8))
    }
}
