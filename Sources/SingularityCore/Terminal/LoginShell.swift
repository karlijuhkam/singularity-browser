import Foundation

/// The user's login shell.
public enum LoginShell {
    /// From the user database (what `chsh` sets), falling back to zsh. Used by terminal tabs and to
    /// resolve plugin commands the way a terminal would find them.
    public static func path() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}
