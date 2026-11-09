#if DEBUG
import AppKit
import SingularityCore

/// Debug-only palette commands for the plugin system (not compiled into release builds).
@MainActor
enum PluginDebugCommands {
    /// Proves the 1Password CLI works with Touch ID when launched from Singularity:
    /// resolves `op`, lists Login items, and shows how many came back (or what went wrong).
    static func testOnePasswordCLI() {
        Task {
            let message = await onePasswordReport()
            let alert = NSAlert()
            alert.messageText = "Plugins: Test 1Password CLI"
            alert.informativeText = message
            alert.runModal()
        }
    }

    private static func onePasswordReport() async -> String {
        let shell = loginShell()
        // Resolving blocks (it waits for the login shell), so keep it off the main thread.
        guard let path = await Task.detached(operation: { CommandBroker.resolve("op", loginShell: shell) }).value else {
            return "Could not find the `op` command with \(shell). Is the 1Password CLI installed?"
        }
        let result = await CommandBroker.run(
            path: path, arguments: ["item", "list", "--categories", "Login", "--format", "json"], timeout: .seconds(60))
        if result.timedOut { return "\(path) timed out after 60 s (no Touch ID answer?)." }
        guard result.status == 0 else {
            return "\(path) exited with status \(result.status).\n\(result.stderr)"
        }
        guard let items = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [Any] else {
            return "\(path) succeeded but printed something other than a JSON list."
        }
        return "\(items.count) logins"
    }

    /// The user's login shell from the user database (same lookup as terminal tabs), falling back to zsh.
    private static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}
#endif
