import FlyingFox
import FlyingSocks
import Foundation
import SingularityCore
import os

/// Visible with: log stream --level debug --predicate 'subsystem == "dev.roosa.Singularity" AND category == "artifacts"'
let artifactLog = Logger(subsystem: "dev.roosa.Singularity", category: "artifacts")

/// A static file server for one Space's `artifacts/` folder, on 127.0.0.1 and a random free port.
///
/// It serves files and nothing else: no directory listings, no API routes, no uploads.
/// Every request must carry the Space's token (see `ArtifactAuth`).
actor ArtifactServer {
    private let server: HTTPServer
    private var runTask: Task<Void, Never>?

    init(root: URL, token: String) throws {
        server = HTTPServer(
            // Port 0 asks the OS for any free port; 127.0.0.1 means only this Mac can connect.
            address: try .inet(ip4: "127.0.0.1", port: 0),
            logger: .disabled,
            handler: ArtifactFileHandler(root: root, token: token)
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
        guard request.method == .GET || request.method == .HEAD else {
            return Self.text(.methodNotAllowed, "Method Not Allowed")
        }
        guard ArtifactAuth.isAuthorized(
            authorization: request.headers[.authorization],
            cookie: request.headers[.cookie],
            token: token
        ) else {
            return Self.text(.unauthorized, "Unauthorized")
        }
        guard let file = ArtifactFiles.resolve(requestPath: request.path, root: root) else {
            return Self.text(.notFound, "Not Found")
        }

        var headers = HTTPHeaders()
        headers[.contentType] = ArtifactFiles.mimeType(for: file)
        // Artifacts change while you look at them; never serve a stale copy.
        headers[.cacheControl] = "no-store"
        headers[HTTPHeader("X-Content-Type-Options")] = "nosniff"

        // A request that proved itself with the header (the tab's first page load, made by the app)
        // gets the cookie, so the page's own sub-requests are authorised too.
        if request.headers[.authorization] != nil {
            headers[HTTPHeader("Set-Cookie")] = "\(ArtifactAuth.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict"
        }

        if request.method == .HEAD {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            headers[.contentLength] = String(size)
            return HTTPResponse(statusCode: .ok, headers: headers)
        }
        return HTTPResponse(statusCode: .ok, headers: headers, body: try HTTPBodySequence(file: file))
    }

    private static func text(_ status: HTTPStatusCode, _ message: String) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain; charset=utf-8"
        return HTTPResponse(statusCode: status, headers: headers, body: Data(message.utf8))
    }
}
