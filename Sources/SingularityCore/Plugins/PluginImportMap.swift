import Foundation

/// Builds the import map for a plugin page: bare names like "preact/hooks" to files under
/// `/node_modules/`. Pure: the caller supplies a reader for `node_modules/<name>/package.json`.
public enum PluginImportMap {
    private static let conditions = ["browser", "import", "module", "default"]

    public static func make(dependencies: [String], packageJSON: (String) -> Data?) -> [String: String] {
        var map: [String: String] = [:]
        for name in dependencies {
            guard let data = packageJSON(name),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let exports = json["exports"] {
                addExports(exports, name: name, to: &map)
            } else if let file = (json["module"] as? String) ?? (json["main"] as? String) {
                // `main` is often written without "./" ("dist/index.js"); in `exports` that is not allowed.
                add(key: name, target: file, name: name, to: &map, allowBare: true)
            }
        }
        return map
    }

    private static func addExports(_ exports: Any, name: String, to map: inout [String: String]) {
        // `exports` can be a plain string, a conditions object, or an object of subpaths.
        if let file = exports as? String {
            add(key: name, target: file, name: name, to: &map)
            return
        }
        guard let object = exports as? [String: Any] else { return }
        let isSubpaths = object.keys.contains { $0.hasPrefix(".") }
        guard isSubpaths else {
            if let file = pick(object) { add(key: name, target: file, name: name, to: &map) }
            return
        }
        for (subpath, value) in object {
            if subpath == "./package.json" || subpath.contains("*") { continue }
            let key: String
            if subpath == "." { key = name } else if subpath.hasPrefix("./") { key = name + "/" + subpath.dropFirst(2) } else { continue }
            let file = (value as? String) ?? (value as? [String: Any]).flatMap(pick)
            if let file { add(key: key, target: file, name: name, to: &map) }
        }
    }

    /// The first of the conditions that is a usable file; looks one level into nested objects.
    private static func pick(_ object: [String: Any]) -> String? {
        for condition in conditions {
            guard let value = object[condition] else { continue }
            if let file = value as? String, isScript(file) { return file }
            if let nested = value as? [String: Any] {
                for inner in conditions {
                    if let file = nested[inner] as? String, isScript(file) { return file }
                }
            }
        }
        return nil
    }

    private static func isScript(_ file: String) -> Bool { file.hasSuffix(".js") || file.hasSuffix(".mjs") }

    private static func add(key: String, target: String, name: String, to map: inout [String: String], allowBare: Bool = false) {
        let file = target.hasPrefix("./") ? target : (allowBare && !target.hasPrefix("/") && !target.hasPrefix(".") ? "./" + target : nil)
        guard let file, !file.split(separator: "/").contains(".."), isScript(file) else { return }
        map[key] = "/node_modules/" + name + "/" + file.dropFirst(2)
    }
}
