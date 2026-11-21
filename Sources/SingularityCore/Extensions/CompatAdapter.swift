import Foundation

/// What `CompatAdapter` did to an extension (shown in the approval sheet and Settings, kept in the
/// record).
public struct CompatSummary: Codable, Equatable, Sendable {
    /// The missing members (`"ns.member"`) and namespaces (`"ns"`) the code uses, sorted.
    public var standIns: [String]
    /// The service-worker background runs as a page.
    public var backgroundPage: Bool
    /// The recipe's name, when one applied.
    public var recipe: String?

    public init(standIns: [String], backgroundPage: Bool, recipe: String?) {
        self.standIns = standIns
        self.backgroundPage = backgroundPage
        self.recipe = recipe
    }

    /// "stand-ins for 3 Chrome features, background as a page, 1Password recipe"
    public var short: String {
        var parts: [String] = []
        if !standIns.isEmpty { parts.append("stand-ins for \(standIns.count) Chrome feature\(standIns.count == 1 ? "" : "s")") }
        if backgroundPage { parts.append("background as a page") }
        if let recipe { parts.append("\(recipe) recipe") }
        return parts.joined(separator: ", ")
    }

    public var text: String { "Singularity adapts this extension to run here: \(short)." }
}

/// Builds the adapted copy of a Chrome extension WebKit can't run as it is (spec
/// `docs/superpowers/specs/2026-11-21-extension-compat-design.md`). Pure file work, no WebKit.
///
/// The original folder is never changed. The output depends only on the original's files, the
/// extension id and `version`, so the same input always gives the same folder (and fingerprint).
/// Steps, each only when it applies:
/// 1. Real uses of members WebKit lacks are rewritten to read from `__sg` (`CompatSource.rewrite`).
/// 2. `sg-compat.js` (`CompatStandIns`) is added and loaded first: first in each content script's
///    `js` list (not in `world: "MAIN"` ones, whose `chrome` is the page's), first in every HTML
///    page's `<head>`, and before the background's code (a generated entry next to the worker).
/// 3. A service worker that constructs a WebSocket (in its file or a file it imports) runs as a
///    background page instead: WebKit's service-worker background hangs on `new WebSocket`.
/// 4. The extension's recipe (`CompatRecipe`), if it has one.
/// 5. `update_url` and `_metadata/` are dropped. The adapted manifest asks for exactly the
///    original's permissions and match patterns: checked, and adapting fails otherwise.
public enum CompatAdapter {
    /// Bump whenever the adapter's output changes: every adapted copy is rebuilt at the next launch.
    public static let version = 1

    public static let workerEntryName = "sg-worker.js"
    public static let backgroundPageName = "sg-background.html"
    static let importScriptsShimName = "sg-import-scripts.js"

    public enum Failure: Error, LocalizedError, Equatable {
        case unreadableManifest
        case recipeMismatch(String, expected: Int, found: Int)
        case permissionsChanged
        case unreadableFile(String)
        case nameTaken(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableManifest: return "Its manifest.json can't be read."
            case .recipeMismatch(let file, let expected, let found):
                return "This version's code isn't what Singularity's adaptation expects (\(file): \(found) matches, \(expected) expected)."
            case .permissionsChanged: return "Adapting it would change what it asks for."
            case .unreadableFile(let file): return "\(file) can't be read."
            case .nameTaken(let file): return "It has its own file named \(file), which Singularity's adaptation needs."
            }
        }
    }

    /// Adapts `original` into `into` (which must not exist; created only when something is needed).
    /// Returns nil when the extension needs nothing (then `into` isn't created), and also when its
    /// manifest isn't JSON this can read (WebKit may still load it, as it did before adapting
    /// existed). On any failure `into` is removed.
    public static func adapt(original: URL, into: URL, extensionID: String) throws -> CompatSummary? {
        guard let manifestData = try? Data(contentsOf: original.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            return nil
        }
        let files = try PluginFingerprint.listFiles(folder: original).filter { !$0.path.hasPrefix("_metadata/") && $0.path != "_metadata" }
        let paths = Set(files.map(\.path))

        // What the code needs.
        var texts: [String: String] = [:]          // every UTF-8 .js file, as written
        var rewritten: [String: String] = [:]      // the ones the rewrite changed
        var used: Set<String> = []
        for file in files where file.path.lowercased().hasSuffix(".js") || file.path.lowercased().hasSuffix(".mjs") {
            guard let data = try? Data(contentsOf: file.url) else { throw Failure.unreadableFile(file.path) }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            texts[file.path] = text
            let result = CompatSource.rewrite(text)
            if !result.members.isEmpty { rewritten[file.path] = result.text }
            used.formUnion(result.members)
            used.formUnion(CompatSource.usedNamespaces(text))
        }
        var background = manifest["background"] as? [String: Any]
        let worker = (background?["service_worker"] as? String).map(normalised).flatMap { paths.contains($0) ? $0 : nil }
        let isModule = (background?["type"] as? String) == "module"
        let workerFiles = worker.map { workerClosure($0, isModule: isModule, texts: texts, paths: paths) } ?? []
        let webSocket = workerFiles.contains { texts[$0].map(CompatSource.constructsWebSocket) ?? false }
        let recipe = CompatRecipe.all[extensionID]
        guard !used.isEmpty || webSocket || recipe != nil else { return nil }
        let asPage = worker != nil && (webSocket || recipe?.backgroundAsPage == true)

        // The files this adds must not replace the extension's own.
        var generated = [CompatStandIns.fileName]
        if let worker {
            generated.append(directory(of: worker) + (asPage ? backgroundPageName : workerEntryName))
            if asPage && !isModule { generated.append(importScriptsShimName) }
        }
        let taken = Set(paths.map { $0.lowercased() })
        if let clash = generated.first(where: { taken.contains($0.lowercased()) }) { throw Failure.nameTaken(clash) }

        let fm = FileManager.default
        if fm.fileExists(atPath: into.path) { try fm.removeItem(at: into) }
        do {
            // Copy, with the rewritten files.
            try fm.createDirectory(at: into, withIntermediateDirectories: true)
            var out: [String: Data] = [:]
            for file in files {
                if let text = rewritten[file.path] {
                    out[file.path] = Data(text.utf8)
                } else {
                    guard let data = try? Data(contentsOf: file.url) else { throw Failure.unreadableFile(file.path) }
                    out[file.path] = data
                }
            }
            // HTML pages load the stand-ins first.
            for path in out.keys where path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm") {
                guard let text = String(data: out[path]!, encoding: .utf8) else { continue }
                out[path] = Data(insertingStandIns(into: text).utf8)
            }
            // The recipe, on the rewritten text.
            if let recipe {
                for replacement in recipe.replacements {
                    guard let data = out[replacement.file], let text = String(data: data, encoding: .utf8) else {
                        throw Failure.recipeMismatch(replacement.file, expected: replacement.count, found: 0)
                    }
                    out[replacement.file] = Data(try apply(replacement, to: text).utf8)
                }
            }
            out[CompatStandIns.fileName] = Data(CompatStandIns.script.utf8)

            // The manifest.
            var adapted = manifest
            adapted["update_url"] = nil
            if var scripts = adapted["content_scripts"] as? [[String: Any]] {
                for index in scripts.indices {
                    guard (scripts[index]["world"] as? String)?.uppercased() != "MAIN",
                          let js = scripts[index]["js"] as? [String], !js.isEmpty else { continue }
                    scripts[index]["js"] = [CompatStandIns.fileName] + js
                }
                adapted["content_scripts"] = scripts
            }
            if let worker {
                let folder = directory(of: worker)
                let name = String(worker.split(separator: "/").last ?? Substring(worker))
                if asPage {
                    var tags = [script("/" + CompatStandIns.fileName, module: false)]
                    if !isModule {
                        out[importScriptsShimName] = Data("globalThis.importScripts = globalThis.importScripts || function () {};\n".utf8)
                        tags.append(script("/" + importScriptsShimName, module: false))
                        for argument in CompatSource.importScriptsArguments(texts[worker] ?? "") where !argument.contains(":") {
                            tags.append(script(argument, module: false))
                        }
                    }
                    tags.append(script(name, module: isModule))
                    let page = folder + backgroundPageName
                    out[page] = Data(("<!doctype html><meta charset=\"utf-8\">" + tags.joined()).utf8)
                    adapted["background"] = ["page": page, "persistent": false]
                } else {
                    let entry = folder + workerEntryName
                    let text = isModule
                        ? "import \"/\(CompatStandIns.fileName)\";\nimport \"./\(name)\";\n"
                        : "importScripts(\"/\(CompatStandIns.fileName)\", \"\(name)\");\n"
                    out[entry] = Data(text.utf8)
                    background?["service_worker"] = entry
                    adapted["background"] = background
                }
            } else if var scripts = background?["scripts"] as? [String], !scripts.isEmpty {
                scripts.insert(CompatStandIns.fileName, at: 0)
                background?["scripts"] = scripts
                adapted["background"] = background
            }
            guard sameRequests(manifest, adapted) else { throw Failure.permissionsChanged }
            out["manifest.json"] = try JSONSerialization.data(withJSONObject: adapted, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

            for path in out.keys.sorted() {
                let url = into.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try out[path]!.write(to: url)
            }
        } catch {
            try? fm.removeItem(at: into)
            throw error
        }
        return CompatSummary(standIns: used.sorted(), backgroundPage: asPage, recipe: recipe?.name)
    }

    // MARK: - Parts

    /// The worker file and every file it loads statically (module imports, or classic
    /// `importScripts` with literal names), as paths in the extension.
    static func workerClosure(_ worker: String, isModule: Bool, texts: [String: String], paths: Set<String>) -> [String] {
        var seen: [String] = []
        var queue = [worker]
        while let path = queue.first {
            queue.removeFirst()
            guard !seen.contains(path) else { continue }
            seen.append(path)
            guard let text = texts[path] else { continue }
            // Module imports resolve against the importing file; a classic worker's importScripts
            // against the worker's own address.
            let base = isModule ? directory(of: path) : directory(of: worker)
            let names = isModule ? CompatSource.staticImports(text) : CompatSource.importScriptsArguments(text)
            for name in names where !name.contains(":") {
                guard name.hasPrefix("./") || name.hasPrefix("../") || name.hasPrefix("/") || !isModule else { continue }
                let resolved = normalised(name.hasPrefix("/") ? name : base + name)
                if paths.contains(resolved) { queue.append(resolved) }
            }
        }
        return seen
    }

    /// `a/./b/../c.js` → `a/c.js`; a leading `/` means the extension's top.
    static func normalised(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// The folder part with its trailing slash, or "" at the top.
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    static func script(_ src: String, module: Bool) -> String {
        let escaped = src.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<script\(module ? " type=\"module\"" : "") src=\"\(escaped)\"></script>"
    }

    /// The stand-ins' `<script>` right after `<head…>`, else after `<html…>`, else after the doctype,
    /// else at the start.
    static func insertingStandIns(into html: String) -> String {
        let tag = script("/" + CompatStandIns.fileName, module: false)
        for pattern in [#"<head(\s[^>]*)?>"#, #"<html(\s[^>]*)?>"#, #"<!doctype[^>]*>"#] {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return html.replacingCharacters(in: range.upperBound..<range.upperBound, with: tag)
            }
        }
        return tag + html
    }

    static func apply(_ replacement: CompatRecipe.Replacement, to text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: replacement.pattern)
        let ns = text as NSString
        let all = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let matches = all.filter { match in
            guard var guardPattern = replacement.guardPattern else { return true }
            for group in stride(from: min(match.numberOfRanges - 1, 9), through: 1, by: -1) {
                let range = match.range(at: group)
                let value = range.location == NSNotFound ? "" : ns.substring(with: range)
                guardPattern = guardPattern.replacingOccurrences(of: "$\(group)", with: NSRegularExpression.escapedPattern(for: value))
            }
            return text.range(of: guardPattern, options: .regularExpression) != nil
        }
        guard matches.count == replacement.count else {
            throw Failure.recipeMismatch(replacement.file, expected: replacement.count, found: matches.count)
        }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let value = regex.replacementString(for: match, in: text, offset: 0, template: replacement.template)
            result.replaceCharacters(in: match.range, with: value)
        }
        return result as String
    }

    /// The two manifests ask for the same: equal once `update_url`, `background` and every content
    /// script's `js` list are set aside.
    static func sameRequests(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        func stripped(_ m: [String: Any]) -> NSDictionary {
            var m = m
            m["update_url"] = nil
            m["background"] = nil
            if let scripts = m["content_scripts"] as? [[String: Any]] {
                m["content_scripts"] = scripts.map { entry -> [String: Any] in
                    var entry = entry
                    entry["js"] = nil
                    return entry
                }
            }
            return m as NSDictionary
        }
        return stripped(a).isEqual(to: stripped(b) as! [AnyHashable: Any])
    }
}
