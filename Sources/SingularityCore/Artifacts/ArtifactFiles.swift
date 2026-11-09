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

    /// Whether a path relative to the artifacts folder is an artifact *page* that gets its own tab.
    public static func isArtifactPage(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty else { return false }
        if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return false }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    /// `file` relative to `root` ("report/index.html"), or nil if it isn't inside it.
    public static func relativePath(of file: URL, in root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
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
            guard let relative = relativePath(of: url, in: root), isArtifactPage(relative) else { continue }
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
