import Foundation
import Testing
@testable import SingularityCore

@Suite struct ArtifactFilesTests {
    /// Builds:  <tmp>/artifacts/{index.html, report/index.html, app.mjs, .env}
    ///          <tmp>/secret.txt                 (outside the root)
    ///          <tmp>/artifacts/escape -> <tmp>  (symlink pointing out)
    func makeTree() throws -> (root: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "artifact-tests-\(UUID().uuidString)")
        let root = base.appending(path: "artifacts")
        try FileManager.default.createDirectory(at: root.appending(path: "report"), withIntermediateDirectories: true)
        try Data("<h1>home</h1>".utf8).write(to: root.appending(path: "index.html"))
        try Data("<h1>report</h1>".utf8).write(to: root.appending(path: "report/index.html"))
        try Data("export {}".utf8).write(to: root.appending(path: "app.mjs"))
        try Data("SECRET=1".utf8).write(to: root.appending(path: ".env"))
        try Data("secret".utf8).write(to: base.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: base)
        return (root, base)
    }

    @Test func servesFilesInsideTheRoot() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ArtifactFiles.resolve(requestPath: "/", root: root)?.lastPathComponent == "index.html")
        #expect(ArtifactFiles.resolve(requestPath: "/report", root: root)?.path.hasSuffix("report/index.html") == true)
        #expect(ArtifactFiles.resolve(requestPath: "/report/", root: root)?.path.hasSuffix("report/index.html") == true)
        #expect(ArtifactFiles.resolve(requestPath: "/app.mjs", root: root) != nil)
    }

    @Test func refusesEverythingOutsideOrHidden() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let attempts = [
            "/../secret.txt",
            "/report/../../secret.txt",
            "/%2e%2e/secret.txt",
            "/%2E%2E%2Fsecret.txt",
            "/report/%2e%2e/%2e%2e/secret.txt",
            "/escape/secret.txt",          // symlink leading out of the root
            "/.env",                       // hidden file
            "/missing.html",
            "/index.html%00.png",          // NUL byte
            "/./index.html",
        ]
        for path in attempts {
            #expect(ArtifactFiles.resolve(requestPath: path, root: root) == nil, "should refuse \(path)")
        }
    }

    @Test func artifactPagesAndListing() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ArtifactFiles.isArtifactPage("report/index.html"))
        #expect(ArtifactFiles.isArtifactPage("Notes.HTM"))
        #expect(!ArtifactFiles.isArtifactPage("app.mjs"))
        #expect(!ArtifactFiles.isArtifactPage(".cache/x.html"))
        #expect(!ArtifactFiles.isArtifactPage("node_modules/pkg/index.html"))
        // The "escape" symlink is not followed by the listing.
        #expect(ArtifactFiles.listPages(in: root) == ["index.html", "report/index.html"])
        #expect(ArtifactFiles.relativePath(of: root.appending(path: "report/index.html"), in: root) == "report/index.html")
    }

    @Test func mimeTypes() {
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/app.mjs")) == "text/javascript; charset=utf-8")
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/app.js")) == "text/javascript; charset=utf-8")
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/index.HTML")) == "text/html; charset=utf-8")
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/logo.png")) == "image/png")
        #expect(ArtifactFiles.mimeType(for: URL(fileURLWithPath: "/a/blob.unknownext")) == "application/octet-stream")
    }

    @Test func artifactTabKind() throws {
        let tab = BrowserTab.artifact(path: "report/index.html")
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
        #expect(decoded.artifactPath == "report/index.html")
        #expect(decoded.displayTitle == "index.html")
        #expect(decoded.url == nil && !decoded.isTerminal)
    }
}

@Suite struct ArtifactAuthTests {
    let token = "abc123"

    @Test func acceptsBearerOrCookie() {
        #expect(ArtifactAuth.isAuthorized(authorization: "Bearer abc123", cookie: nil, token: token))
        #expect(ArtifactAuth.isAuthorized(authorization: "bearer abc123", cookie: nil, token: token))
        #expect(ArtifactAuth.isAuthorized(authorization: nil, cookie: "a=1; singularity_token=abc123; b=2", token: token))
    }

    @Test func rejectsEverythingElse() {
        #expect(!ArtifactAuth.isAuthorized(authorization: nil, cookie: nil, token: token))
        #expect(!ArtifactAuth.isAuthorized(authorization: "Bearer abc12", cookie: nil, token: token))
        #expect(!ArtifactAuth.isAuthorized(authorization: "Basic abc123", cookie: nil, token: token))
        #expect(!ArtifactAuth.isAuthorized(authorization: nil, cookie: "singularity_token=nope", token: token))
        #expect(!ArtifactAuth.isAuthorized(authorization: nil, cookie: "xsingularity_token=abc123", token: token))
    }

    @Test func hosts() {
        #expect(ArtifactAuth.isAllowedHost("127.0.0.1:54321"))
        #expect(ArtifactAuth.isAllowedHost("localhost:54321"))
        #expect(!ArtifactAuth.isAllowedHost("evil.example:54321"))
        #expect(!ArtifactAuth.isAllowedHost(nil))
    }

    @Test func tokensAreRandomAndLong() {
        let a = ArtifactAuth.makeToken(), b = ArtifactAuth.makeToken()
        #expect(a.count == 64 && a != b)
    }
}
