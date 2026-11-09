import Foundation

/// Decides what a terminal tab is called in the sidebar.
///
/// - At the shell prompt: the current directory ("~/Developer/app").
/// - While a program runs: the title it set with an escape sequence (Claude Code, vim and
///   others do this), otherwise the program's name plus the folder ("claude · app").
public enum TerminalTitle {
    public static func make(
        foregroundProgram: String?,
        isShellInForeground: Bool,
        programTitle: String?,
        directory: String?,
        home: String = NSHomeDirectory()
    ) -> String {
        let shortDirectory = directory.map { HomePath.abbreviate($0, home: home) }

        if isShellInForeground || foregroundProgram == nil {
            return shortDirectory ?? "Terminal"
        }

        if let programTitle = programTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !programTitle.isEmpty {
            return programTitle
        }

        let program = foregroundProgram ?? "Terminal"
        guard let directory, directory != home, directory != "/" else { return program }
        return "\(program) · \((directory as NSString).lastPathComponent)"
    }
}
