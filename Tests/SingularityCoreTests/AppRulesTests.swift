import Foundation
import Testing
@testable import SingularityCore

@Suite struct ArtifactAppsTests {
    /// Builds:  <tmp>/artifacts/firma/{wrangler.jsonc, worker.ts, app.tsx}
    ///          <tmp>/artifacts/firma/tools/inner/wrangler.json     (an app inside an app's folder)
    ///          <tmp>/artifacts/firma2/index.html                   (no manifest: a plain artifact)
    ///          <tmp>/artifacts/plain/index.html
    ///          <tmp>/artifacts/.hidden/wrangler.jsonc
    ///          <tmp>/outside/wrangler.jsonc, <tmp>/artifacts/escape -> <tmp>/outside
    func makeTree() throws -> (root: URL, base: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "app-rules-\(UUID().uuidString)")
        let root = base.appending(path: "artifacts")
        for folder in ["firma/tools/inner", "firma2", "plain", ".hidden"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: base.appending(path: "outside"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "firma/wrangler.jsonc"))
        try Data("export default {}".utf8).write(to: root.appending(path: "firma/worker.ts"))
        try Data("export {}".utf8).write(to: root.appending(path: "firma/app.tsx"))
        try Data("{}".utf8).write(to: root.appending(path: "firma/tools/inner/wrangler.json"))
        try Data("<p>".utf8).write(to: root.appending(path: "firma2/index.html"))
        try Data("<p>".utf8).write(to: root.appending(path: "plain/index.html"))
        try Data("{}".utf8).write(to: root.appending(path: ".hidden/wrangler.jsonc"))
        try Data("{}".utf8).write(to: base.appending(path: "outside/wrangler.jsonc"))
        try fm.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: base.appending(path: "outside"))
        return (root, base)
    }

    @Test func findsTheAppOfARequest() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let api = ArtifactApps.app(forRequestPath: "/firma/api/x", root: root)
        #expect(api?.app == "firma")
        #expect(api?.rest == "/api/x")
        // The app's own root, with and without the slash.
        #expect(ArtifactApps.app(forRequestPath: "/firma", root: root)?.rest == "/")
        #expect(ArtifactApps.app(forRequestPath: "/firma/", root: root)?.rest == "/")
        // A trailing slash is part of the Worker's path; the query is not.
        #expect(ArtifactApps.app(forRequestPath: "/firma/api/?a=1", root: root)?.rest == "/api/")
        #expect(ArtifactApps.app(forRequestPath: "/firma/a%20b", root: root)?.rest == "/a b")
    }

    @Test func aFolderWhoseNameStartsLikeAnAppsIsNotThatApp() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ArtifactApps.app(forRequestPath: "/firma2/api/x", root: root) == nil)
        #expect(ArtifactApps.app(forRequestPath: "/plain/index.html", root: root) == nil)
        #expect(ArtifactApps.app(forRequestPath: "/", root: root) == nil)
    }

    @Test func theNearestFolderWithAManifestWins() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let inner = ArtifactApps.app(forRequestPath: "/firma/tools/inner/api", root: root)
        #expect(inner?.app == "firma/tools/inner")
        #expect(inner?.rest == "/api")
        #expect(ArtifactApps.app(forRequestPath: "/firma/tools/x", root: root)?.app == "firma")
    }

    @Test func hiddenFoldersDotsAndLinksOutAreNeverApps() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ArtifactApps.app(forRequestPath: "/.hidden/x", root: root) == nil)
        #expect(ArtifactApps.app(forRequestPath: "/firma/../firma/x", root: root) == nil)
        #expect(ArtifactApps.app(forRequestPath: "/firma/%2e%2e/x", root: root) == nil)
        #expect(ArtifactApps.app(forRequestPath: "/escape/api", root: root) == nil)
        #expect(ArtifactApps.app(forRequestPath: "/firma/x%00y", root: root) == nil)
    }

    @Test func findsTheAppOfAnArtifactTab() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ArtifactApps.app(forArtifactPath: "firma/app.tsx", root: root) == "firma")
        #expect(ArtifactApps.app(forArtifactPath: "firma/tools/inner/index.html", root: root) == "firma/tools/inner")
        #expect(ArtifactApps.app(forArtifactPath: "firma2/index.html", root: root) == nil)
        #expect(ArtifactApps.app(forArtifactPath: "index.html", root: root) == nil)
        // A file is not its own folder, even when it is named like one.
        #expect(ArtifactApps.app(forArtifactPath: "firma", root: root) == nil)
    }

    @Test func listsApps() throws {
        let (root, base) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ArtifactApps.list(in: root) == ["firma", "firma/tools/inner"])
        #expect(ArtifactApps.list(in: base.appending(path: "nowhere")) == [])
    }

    @Test func appPathsArePlainRelativePaths() {
        #expect(ArtifactApps.isValidAppPath("firma"))
        #expect(ArtifactApps.isValidAppPath("tools/firma"))
        for bad in ["", "/firma", "firma/", "a//b", "../x", "a/../b", ".git", "a/.b", "a\0b"] {
            #expect(!ArtifactApps.isValidAppPath(bad), "\(bad)")
        }
    }

    @Test func routesFilesFirstThenTheWorker() {
        #expect(ArtifactApps.route(method: "GET", hasFile: true, inApp: true) == .file)
        #expect(ArtifactApps.route(method: "HEAD", hasFile: true, inApp: true) == .file)
        #expect(ArtifactApps.route(method: "GET", hasFile: false, inApp: true) == .worker)
        // Anything but a read is the Worker's, even where a file has the same path.
        #expect(ArtifactApps.route(method: "POST", hasFile: true, inApp: true) == .worker)
        #expect(ArtifactApps.route(method: "DELETE", hasFile: false, inApp: true) == .worker)
        // Outside an app nothing changed: files only, GET and HEAD only.
        #expect(ArtifactApps.route(method: "GET", hasFile: false, inApp: false) == .file)
        #expect(ArtifactApps.route(method: "GET", hasFile: true, inApp: false) == .file)
        #expect(ArtifactApps.route(method: "POST", hasFile: true, inApp: false) == .notAllowed)
    }

    @Test func onlyTheServersOwnOriginReachesAWorker() {
        let own = "http://127.0.0.1:5000"
        #expect(ArtifactApps.mayReachWorker(method: "GET", secFetchSite: nil, origin: nil, serverOrigin: own))
        #expect(ArtifactApps.mayReachWorker(method: "GET", secFetchSite: "same-origin", origin: nil, serverOrigin: own))
        #expect(ArtifactApps.mayReachWorker(method: "GET", secFetchSite: "none", origin: nil, serverOrigin: own))
        #expect(ArtifactApps.mayReachWorker(method: "POST", secFetchSite: "same-origin", origin: own, serverOrigin: own))
        // Another port on 127.0.0.1 is the same *site* (so the cookie is sent) but not the same origin.
        #expect(!ArtifactApps.mayReachWorker(method: "GET", secFetchSite: "same-site", origin: nil, serverOrigin: own))
        #expect(!ArtifactApps.mayReachWorker(method: "GET", secFetchSite: "cross-site", origin: nil, serverOrigin: own))
        #expect(!ArtifactApps.mayReachWorker(method: "GET", secFetchSite: nil, origin: "http://127.0.0.1:3000", serverOrigin: own))
        #expect(!ArtifactApps.mayReachWorker(method: "POST", secFetchSite: nil, origin: nil, serverOrigin: own))
        #expect(!ArtifactApps.mayReachWorker(method: "POST", secFetchSite: "same-origin", origin: "http://127.0.0.1:3000", serverOrigin: own))
        #expect(!ArtifactApps.mayReachWorker(method: "DELETE", secFetchSite: nil, origin: "null", serverOrigin: own))
    }

    @Test func theWorkerNeverSeesTheSpacesToken() {
        let headers = ArtifactApps.headersForWorker([
            ("Authorization", "Bearer secret"),
            ("Cookie", "theme=dark; singularity_token=secret; lang=et"),
            ("Accept", "application/json"),
        ])
        #expect(headers.map(\.0) == ["Cookie", "Accept"])
        #expect(headers[0].1 == "theme=dark; lang=et")
        // Only our cookie: the header goes altogether.
        #expect(ArtifactApps.headersForWorker([("cookie", "singularity_token=secret")]).isEmpty)
    }

    /// What a Worker's process writes as headers and status is not trusted to be well-formed.
    @Test func malformedHeadersAndStatusesFromAWorkerAreDropped() {
        let headers = ArtifactApps.headersFromWorker([
            ("X-Ok", "fine"),
            ("X-Split", "a\r\nSet-Cookie: singularity_token=bad"),
            ("X-Newline", "a\nb"),
            ("X-Nul", "a\0b"),
            ("Bad Name", "x"),
            ("", "x"),
            ("X-Tab", "a\tb"),
        ])
        #expect(headers.map(\.0) == ["X-Ok", "X-Tab"])
        #expect(ArtifactApps.isResponseStatus(200) && ArtifactApps.isResponseStatus(404) && ArtifactApps.isResponseStatus(599))
        for bad in [0, 99, 100, 101, 199, 600, -1] { #expect(!ArtifactApps.isResponseStatus(bad), "\(bad)") }
    }

    @Test func theWorkerCannotReplaceTheAuthCookie() {
        let headers = ArtifactApps.headersFromWorker([
            ("Set-Cookie", "singularity_token=x; Path=/"),
            ("set-cookie", " singularity_token =y"),
            ("Set-Cookie", "session=abc; Path=/"),
            ("Content-Type", "application/json"),
        ])
        #expect(headers.map(\.1) == ["session=abc; Path=/", "application/json"])
    }
}

@Suite struct AppRecordTests {
    @Test func aSpaceFileWithoutAppsHasNone() throws {
        let json = ##"{"id":"11111111-1111-1111-1111-111111111111","name":"Work","slug":"work","colorHex":"#000000"}"##
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.apps.isEmpty)
    }

    @Test func aMalformedAppsValueReadsAsNothingAllowed() throws {
        let json = ##"{"id":"11111111-1111-1111-1111-111111111111","name":"Work","slug":"work","colorHex":"#000000","apps":"oops"}"##
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.apps.isEmpty)
    }

    @Test func appsRoundTripAndBadPathsAreDropped() throws {
        var space = Space(name: "Work", slug: "work", colorHex: "#000000")
        space.apps["firma"] = AppRecord(hosts: ["api.example.com"], keys: [AppKey(name: "API_KEY", host: "api.example.com")])
        space.apps["../evil"] = AppRecord(hosts: ["evil.example"])
        let decoded = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        #expect(decoded.apps.keys.sorted() == ["firma"])
        #expect(decoded.apps["firma"]?.keys.first?.readable == false)
        #expect(decoded.apps["firma"]?.isEmpty == false)
        #expect(AppRecord().isEmpty)
    }

    /// Data folders are never inside one another: an app in a subfolder gets one folder name.
    @Test func dataFoldersAreFlat() {
        let paths = Paths(root: URL(filePath: "/tmp/sg"))
        #expect(paths.appDataDirectory("work", app: "firma/sub").path == "/tmp/sg/spaces/work/app-data/firma%2Fsub")
        #expect(paths.appDataDirectory("work", app: "50%").lastPathComponent == "50%25")
        for app in ["firma", "firma/sub", "a/b/c", "50%", "a%2Fb", "tmp"] {
            let name = ArtifactApps.dataFolderName(for: app)
            #expect(!name.contains("/"))
            #expect(ArtifactApps.app(fromDataFolderName: name) == app, "\(app)")
        }
        // "a%2Fb" (a folder really named so) and "a/b" are different apps with different folders.
        #expect(ArtifactApps.dataFolderName(for: "a%2Fb") != ArtifactApps.dataFolderName(for: "a/b"))
        for stray in ["Library", ".hidden", "a%2", "%2Fx", "x%2F"] {
            #expect(ArtifactApps.app(fromDataFolderName: stray) == (stray == "Library" ? "Library" : nil), "\(stray)")
        }
    }

    @Test func appDataIsOutsideTheArtifactsFolder() {
        let paths = Paths(root: URL(filePath: "/tmp/sg"))
        #expect(paths.appDataDirectory("work", app: "firma").path == "/tmp/sg/spaces/work/app-data/firma")
        #expect(!paths.appDataDirectory("work", app: "firma").path.hasPrefix(paths.artifactsDirectory("work").path))
    }
}
