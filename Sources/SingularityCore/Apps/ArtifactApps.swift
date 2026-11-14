import Foundation

/// An **app** is a folder in a Space's `artifacts/` that has a `wrangler.jsonc`: its files are
/// served as any artifact's, and requests the folder has no file for go to its Worker (a
/// sandboxed Bun process, see `AppWorkerProcess`). This file holds the rules about which folder
/// is an app and which requests may reach a Worker. All pure, all tested.
///
/// Spec: docs/superpowers/specs/2026-11-13-apps-design.md
public enum ArtifactApps {
    /// The file that makes a folder an app (Cloudflare's own config file, so the folder deploys
    /// with `wrangler` as it is).
    public static let manifestNames = ["wrangler.jsonc", "wrangler.json"]

    /// The guide for agents that write apps, shipped in the app bundle with a starter template
    /// next to it (`Contents/Resources/app-guide/{AUTHORING.md, template/}`; the build scripts
    /// copy them from `docs/apps/` and `Apps/template/`). Nil in a copy that has none (a bare
    /// debug binary).
    public static func guideFile(resources: URL?) -> URL? {
        guard let file = resources?.appending(path: "app-guide/AUTHORING.md"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    // MARK: - Which folder

    /// The app a request path belongs to, and the path as the Worker sees it:
    /// "/firma/api/x" → ("firma", "/api/x"). The app is the *nearest* enclosing folder with a
    /// manifest, so an app inside an app's folder is its own app.
    ///
    /// Nil when the path is in no app, has a hidden or ".." component, or the folder is really
    /// somewhere outside `root` (a symlink). The artifacts folder itself is never an app: an app
    /// needs a name.
    public static func app(forRequestPath requestPath: String, root: URL) -> (app: String, rest: String)? {
        var path = requestPath
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        guard let decoded = path.removingPercentEncoding, !decoded.contains("\0") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard isSafe(components) else { return nil }

        // Deepest folder first. The last component may be a file or a route, so it is tried as a
        // folder too ("/firma" is the app's own root).
        for count in stride(from: components.count, through: 1, by: -1) {
            let folder = Array(components[..<count])
            guard hasManifest(folder, root: root) else { continue }
            let rest = "/" + components[count...].joined(separator: "/")
            // Keep a trailing slash: "/firma/api/" and "/firma/api" are different paths to a Worker.
            let slash = decoded.hasSuffix("/") && rest != "/" ? "/" : ""
            return (folder.joined(separator: "/"), rest + slash)
        }
        return nil
    }

    /// The app an artifact tab's file belongs to ("firma/app.tsx" → "firma"), if any.
    public static func app(forArtifactPath path: String, root: URL) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard isSafe(components), components.count > 1 else { return nil }
        // The file itself is not a folder: start at its parent.
        for count in stride(from: components.count - 1, through: 1, by: -1) {
            let folder = Array(components[..<count])
            if hasManifest(folder, root: root) { return folder.joined(separator: "/") }
        }
        return nil
    }

    /// Every app in the artifacts folder, as paths relative to it, sorted.
    public static func list(in root: URL) -> [String] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var apps = Set<String>()
        for case let file as URL in walker {
            // node_modules can hold thousands of files and never an app of ours.
            if file.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            guard manifestNames.contains(file.lastPathComponent) else { continue }
            let folder = file.deletingLastPathComponent().standardizedFileURL.path
            guard folder.hasPrefix(rootPath + "/") else { continue }
            let relative = String(folder.dropFirst(rootPath.count + 1))
            if isValidAppPath(relative), hasManifest(relative.split(separator: "/").map(String.init), root: root) {
                apps.insert(relative)
            }
        }
        return apps.sorted()
    }

    /// An app's path is also the name of its data folder and the key of its record in
    /// `space.json`, so it must be a plain relative path: no empty, hidden or ".." parts.
    public static func isValidAppPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !components.contains("") && isSafe(components)
    }

    /// The name of an app's data folder inside `app-data/`: the app's path as ONE folder name
    /// ("tools/firma" → "tools%2Ffirma"). Data folders must never be inside one another: a
    /// Worker can write its whole data folder, so a nested app's data would be the outer app's
    /// to read, change, or swap for a link to somewhere else.
    public static func dataFolderName(for app: String) -> String {
        app.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    /// The app a data folder's name stands for; nil when it is not one of ours.
    public static func app(fromDataFolderName name: String) -> String? {
        guard let app = name.removingPercentEncoding, isValidAppPath(app), dataFolderName(for: app) == name else { return nil }
        return app
    }

    private static func isSafe(_ components: [String]) -> Bool {
        !components.contains { $0 == ".." || $0 == "." || $0.hasPrefix(".") }
    }

    /// Whether `folder` (components below `root`) is a real folder inside `root` that holds a
    /// manifest file. Symlinks are followed first, as `ArtifactFiles.resolve` does: a link that
    /// points out of the artifacts folder is never an app.
    private static func hasManifest(_ folder: [String], root: URL) -> Bool {
        guard !folder.isEmpty else { return false }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var candidate = URL(fileURLWithPath: rootPath, isDirectory: true)
        for component in folder { candidate.append(path: component) }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPath + "/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return manifestNames.contains { name in
            var isFolder: ObjCBool = false
            let file = resolved.appending(path: name).path
            return FileManager.default.fileExists(atPath: file, isDirectory: &isFolder) && !isFolder.boolValue
        }
    }

    /// A header name as HTTP allows it: visible ASCII without separators.
    public static func isHeaderName(_ name: String) -> Bool {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return !name.isEmpty && name.unicodeScalars.allSatisfy(token.contains)
    }

    /// A header value that stays one header: no line breaks, NUL or other control characters.
    public static func isHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F || $0.value == 0x09 }
    }

    /// A status the server may send for a Worker; anything else is the Worker's mistake.
    public static func isResponseStatus(_ status: Int) -> Bool {
        (200...599).contains(status)
    }

    // MARK: - Which requests

    public enum Route: Equatable, Sendable {
        /// Answer with a file (or "not found"), as the artifact server always has.
        case file
        /// Hand the request to the app's Worker.
        case worker
        /// 405: only apps take anything but GET and HEAD.
        case notAllowed
    }

    /// Where a request goes. `hasFile`: the artifact server found a file for the path.
    /// As on Cloudflare: a file wins for GET and HEAD, everything else is the Worker's.
    public static func route(method: String, hasFile: Bool, inApp: Bool) -> Route {
        let reads = method == "GET" || method == "HEAD"
        guard inApp else { return reads ? .file : .notAllowed }
        return reads && hasFile ? .file : .worker
    }

    /// Whether a request may be handed to a Worker: only requests from the artifact server's own
    /// origin (or typed by hand: no page behind them).
    ///
    /// The auth cookie is `SameSite=Strict`, but for cookies "site" ignores the port, so a page on
    /// another 127.0.0.1 port in the same Space (a dev server opened as a web tab) would still
    /// send it. `Sec-Fetch-Site` and `Origin` are set by WebKit, not by page scripts.
    public static func mayReachWorker(method: String, secFetchSite: String?, origin: String?, serverOrigin: String) -> Bool {
        if let secFetchSite, secFetchSite != "same-origin", secFetchSite != "none" { return false }
        if method == "GET" || method == "HEAD" {
            // A GET rarely carries Origin; when it does, it must be ours.
            return origin == nil || origin == serverOrigin
        }
        return origin == serverOrigin
    }

    /// The request's headers as the Worker may see them: without the Space's token. The Worker
    /// has no network, but its code is not ours, and the token opens every artifact of the Space.
    public static func headersForWorker(_ headers: [(String, String)]) -> [(String, String)] {
        headers.compactMap { name, value in
            switch name.lowercased() {
            case "authorization":
                return nil
            case "cookie":
                let kept = value.split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix(ArtifactAuth.cookieName + "=") && !$0.isEmpty }
                return kept.isEmpty ? nil : (name, kept.joined(separator: "; "))
            default:
                return (name, value)
            }
        }
    }

    /// The Worker's response headers as the page may get them: it may not replace our auth cookie
    /// (that would lock the Space's artifacts out until the tab is opened again).
    ///
    /// A header that is not well-formed is dropped. The lines come from the Worker's process,
    /// whose code can write anything; a value with a line break in it would otherwise become a
    /// second header of its choosing (our cookie among them) when the answer is written out.
    public static func headersFromWorker(_ headers: [(String, String)]) -> [(String, String)] {
        headers.filter { name, value in
            guard isHeaderName(name), isHeaderValue(value) else { return false }
            guard name.lowercased() == "set-cookie" else { return true }
            let cookieName = value.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return cookieName != ArtifactAuth.cookieName
        }
    }
}
