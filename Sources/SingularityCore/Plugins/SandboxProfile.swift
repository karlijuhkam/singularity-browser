import Foundation

/// The macOS sandbox profile (SBPL, for `sandbox-exec -p`) that confines one plugin's Bun process.
/// The minimum was measured against the bundled Bun with sandbox-exec; everything not allowed is denied.
public enum SandboxProfile {
    public static func make(pluginFolder: URL, dataFolder: URL, runtime: URL, extraReadable: [URL] = []) -> String {
        let runtimePath = quote(runtime)
        var rules: [String] = [
            "(version 1)",
            // Everything is forbidden unless a rule below allows it.
            "(deny default)",
            // Bun may start itself, and nothing else (no spawning other programs).
            "(allow process-exec (literal \(runtimePath)))",
            // Bun reads its own binary.
            "(allow file-read* (literal \(runtimePath)))",
            // Bun stats the root directory at startup (the directory itself, not its contents).
            "(allow file-read* (literal \"/\"))",
            // The plugin's own files, read-only: it cannot rewrite itself.
            "(allow file-read* (subpath \(quote(pluginFolder))))",
            // Bun crashes at startup without reading sysctl values.
            "(allow sysctl-read)",
        ]
        // Read-only extras, e.g. the folder with the app's plugin host script.
        for url in extraReadable { rules.append("(allow file-read* (subpath \(quote(url))))") }
        rules += [
            // The plugin's data folder: its only writable place (Task 6 points TMPDIR here, so no shared /tmp).
            "(allow file-read* file-write* (subpath \(quote(dataFolder))))",
            // No network at all (also the default; spelled out so the intent is visible).
            "(deny network*)",
        ]
        return rules.joined(separator: "\n") + "\n"
    }

    /// An SBPL string literal for the real path of `url`. The sandbox matches real paths, so
    /// symlinks are resolved (/var -> /private/var); backslash and double quote are escaped.
    private static func quote(_ url: URL) -> String {
        let escaped = realPath(url.path)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

    /// realpath() of the deepest existing ancestor, with the not-yet-existing rest appended
    /// (the data folder may be created after the profile is made).
    private static func realPath(_ path: String) -> String {
        var existing = path
        var rest: [String] = []
        while existing != "/", access(existing, F_OK) != 0 {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(existing, &buffer) != nil ? String(cString: buffer) : existing
        return rest.isEmpty ? resolved : (resolved == "/" ? "" : resolved) + "/" + rest.joined(separator: "/")
    }
}
