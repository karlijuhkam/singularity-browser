import Foundation
import UniformTypeIdentifiers

/// File-system rules for a Space's `artifacts/` folder: which file a request may read,
/// which files count as artifact pages, and what MIME type to send.
public enum ArtifactFiles {
    /// Maps a URL path from an HTTP request ("/report/index.html") to a file inside `root`.
    ///
    /// Returns nil, so the server answers 404, when the path:
    /// - is malformed, contains a NUL byte, or has a ".." component (even percent-encoded);
    /// - touches a hidden file or folder (".git", ".env", …);
    /// - resolves outside `root` after following symlinks (a link pointing out of the folder);
    /// - is not a regular file.
    /// A path that names a folder serves that folder's `index.html`.
    public static func resolve(requestPath: String, root: URL) -> URL? {
        guard let decoded = requestPath.removingPercentEncoding, !decoded.contains("\0") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        for component in components {
            if component == ".." || component == "." || component.hasPrefix(".") { return nil }
        }

        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var candidate = URL(fileURLWithPath: rootPath, isDirectory: true)
        for component in components {
            candidate.append(path: String(component))
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            candidate.append(path: "index.html")
        }

        // Follow symlinks, then require the real file to still be inside the root.
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPath + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    /// Whether an artifact tab's file (a path relative to `root`, not percent-encoded) can be
    /// served right now. False after the file was deleted, renamed or moved out of the folder.
    public static func exists(relativePath: String, root: URL) -> Bool {
        // `resolve` takes a request path, so encode what a URL would encode ("%", "?", "#", spaces).
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%")
        guard let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: allowed) else { return false }
        return resolve(requestPath: "/" + encoded, root: root) != nil
    }

    /// Whether a path relative to the artifacts folder is an artifact *page* that gets its own tab.
    public static func isArtifactPage(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty else { return false }
        if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return false }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    /// The same, counting scripts too: `app.tsx`, `index.tsx` or `main.tsx` (see
    /// `ArtifactScripts.entryNames`) is a page when its folder has no HTML page of its own.
    public static func isArtifactPage(_ relativePath: String, root: URL) -> Bool {
        if isArtifactPage(relativePath) { return true }
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty, !components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }),
              ArtifactScripts.isEntryScript(relativePath) else { return false }
        let folder = root.appending(path: (relativePath as NSString).deletingLastPathComponent)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !names.contains { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return !name.hasPrefix(".") && (ext == "html" || ext == "htm")
        }
    }

    /// `file` relative to `root` ("report/index.html"), or nil if it isn't inside it.
    public static func relativePath(of file: URL, in root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        if !filePath.hasPrefix(rootPath), !FileManager.default.fileExists(atPath: file.path) {
            // A file that was just deleted can't be resolved itself, so a symlink somewhere above
            // it (e.g. /tmp → /private/tmp) stays in its path. Resolve its folder instead.
            let folder = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            filePath = folder.appending(path: file.lastPathComponent).path
        }
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    /// All artifact pages under `root`, sorted, at most `limit` (skips hidden folders and node_modules).
    public static func listPages(in root: URL, limit: Int = 500) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var pages: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            guard let relative = relativePath(of: url, in: root), isArtifactPage(relative, root: root) else { continue }
            pages.append(relative)
            if pages.count == limit { break }
        }
        return pages.sorted()
    }

    /// Content-Type for a file. JavaScript must be `text/javascript`, or browsers refuse to run
    /// it as an ES module; text types get an explicit UTF-8 charset.
    public static func mimeType(for file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        let overrides: [String: String] = [
            "html": "text/html; charset=utf-8",
            "htm": "text/html; charset=utf-8",
            "js": "text/javascript; charset=utf-8",
            "mjs": "text/javascript; charset=utf-8",
            // Served compiled (see ArtifactScripts); without this macOS calls .ts a video.
            "ts": "text/javascript; charset=utf-8",
            "tsx": "text/javascript; charset=utf-8",
            "jsx": "text/javascript; charset=utf-8",
            "mts": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "json": "application/json; charset=utf-8",
            "map": "application/json; charset=utf-8",
            "svg": "image/svg+xml",
            "wasm": "application/wasm",
            "txt": "text/plain; charset=utf-8",
            "md": "text/markdown; charset=utf-8",
            "csv": "text/csv; charset=utf-8",
            "woff2": "font/woff2",
        ]
        if let type = overrides[ext] { return type }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// The page an artifact tab shows when its file is gone (deleted, renamed or moved), instead of a
/// bare "Not Found". The tab keeps its address, so it reloads into the real page if the file returns.
public enum ArtifactMissingPage {
    /// Whether a request with this `Accept` header is a page load (as opposed to a script, image
    /// or `fetch()`), i.e. whether a person will look at the answer.
    public static func wantsHTML(accept: String?) -> Bool {
        accept?.lowercased().contains("text/html") == true
    }

    /// A self-contained page: no scripts, nothing loaded from anywhere. `requestPath` comes from
    /// the request, so it is escaped.
    public static func html(requestPath: String) -> String {
        var path = requestPath.removingPercentEncoding ?? requestPath
        if path.hasPrefix("/") { path.removeFirst() }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>\(LoadErrorPage.escape((path as NSString).lastPathComponent))</title>
        <style>
          body { font: 14px -apple-system, sans-serif; margin: 18vh auto 0; max-width: 520px; padding: 0 24px; color: CanvasText; background: Canvas; }
          h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px; }
          p { line-height: 1.5; margin: 0 0 12px; }
          .path { color: GrayText; word-break: break-all; font-family: ui-monospace, monospace; }
        </style></head>
        <body>
          <h1>This artifact’s file is missing</h1>
          <p>It was deleted, renamed or moved out of the Space’s artifacts folder.</p>
          <p class="path">\(LoadErrorPage.escape(path))</p>
          <p>The tab reloads by itself when the file is back.</p>
        </body></html>
        """
    }
}

/// The `Range` request header, so the server can send part of a file. Browsers need this to seek
/// in video and audio (WebKit won't play media from a server that ignores ranges).
public enum ArtifactRange: Equatable, Sendable {
    /// No usable range: send the whole file (200).
    case full
    /// Send these bytes (206). Both ends are inside the file.
    case partial(ClosedRange<Int>)
    /// The range starts beyond the end of the file (416).
    case unsatisfiable

    /// Understands one range: "bytes=0-499", "bytes=500-" (from 500 to the end) and "bytes=-500"
    /// (the last 500 bytes). Anything else, including several ranges at once, means the whole
    /// file, which the HTTP rules allow.
    public static func parse(header: String?, fileSize: Int) -> ArtifactRange {
        guard let header else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = trimmed.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .full }
        func number(_ text: String) -> Int? {
            // Digits only: Int("+5") and Int("-5") would otherwise slip through.
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(text)
        }

        if parts[0].isEmpty {
            // "-N": the last N bytes.
            guard let count = number(parts[1]) else { return .full }
            guard count > 0, fileSize > 0 else { return .unsatisfiable }
            return .partial(max(0, fileSize - count)...(fileSize - 1))
        }
        guard let first = number(parts[0]) else { return .full }
        guard first < fileSize else { return .unsatisfiable }
        if parts[1].isEmpty { return .partial(first...(fileSize - 1)) }
        guard let last = number(parts[1]), last >= first else { return .full }
        return .partial(first...min(last, fileSize - 1))
    }
}
