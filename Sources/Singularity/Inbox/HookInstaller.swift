import Darwin
import Foundation
import SingularityCore

/// Reads and writes Claude Code's `~/.claude/settings.json` for the "Show questions in the inbox"
/// row (Settings → Agents). The edit itself is `ClaudeHookSettings` (Core, text in, text out);
/// this class only does the file work around it.
///
/// That file belongs to the owner and to Claude Code. It is written **only** when the owner
/// presses Install / Update / Remove, and carefully:
/// - a file that is not UTF-8 or not JSON we understand is never rewritten (`Failure.unreadable`);
/// - the new text is written to a temp file in the same folder, then renamed over the old one
///   (`rename(2)` is atomic: Claude Code reads either the old file or the new one, never half);
/// - the file keeps its permissions (a new file gets 0600: it can hold tokens in `env`);
/// - a symlink (dotfile managers do this) is written *through*: its target is replaced, the link
///   stays a link;
/// - afterwards the file is read again and must say what we meant to write.
/// `~/.claude/` is created only by Install, never by reading.
@MainActor final class HookInstaller {
    enum Failure: Error, Equatable {
        /// Not UTF-8, not JSON, or a `hooks` shape we don't understand. The file was left alone.
        case unreadable
        /// No `singularity-hook` next to the running program (bare debug binary).
        case helperMissing
        /// Written, but reading it back did not give the expected status.
        case notAsIntended
        /// The file system said no; the system's own words.
        case io(String)

        /// The text for the row. `file` is the path as shown to the owner.
        func message(file: String) -> String {
            switch self {
            case .unreadable: return "\(file) couldn't be read as JSON; it was left alone."
            case .helperMissing: return "This copy of Singularity runs without its app bundle, and the hook needs the app bundle."
            case .notAsIntended: return "\(file) was written, but reading it back didn't show the expected hooks."
            case .io(let text): return text
            }
        }
    }

    let settingsFile: URL
    /// The helper our hook entries run: `Contents/MacOS/singularity-hook` of this copy of the app.
    let helper: String
    let timeoutSeconds: Int

    /// The defaults are the real thing: this app's helper, and Claude Code's settings file unless
    /// `SINGULARITY_CLAUDE_SETTINGS` or `SINGULARITY_HOME` is set (see `ClaudeHookSettings.file`).
    /// Tests always pass a temp file.
    init(settingsFile: URL = HookInstaller.defaultSettingsFile,
         helper: String = HookInstaller.thisAppHelper,
         timeoutSeconds: Int = ClaudeHookSettings.hookTimeoutSeconds) {
        self.settingsFile = settingsFile
        self.helper = helper
        self.timeoutSeconds = timeoutSeconds
    }

    /// The only place the two environment variables are read.
    static var defaultSettingsFile: URL {
        ClaudeHookSettings.file(environment: ProcessInfo.processInfo.environment,
                                home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Same idea as `AgentConnector.thisAppLauncher`: inside the bundle. For the bare debug binary
    /// `bundleURL` is the build folder, so this path does not exist and the row says so (the
    /// SwiftPM build folder does hold a `singularity-hook`, but the owner's settings must never
    /// point at a build folder).
    static var thisAppHelper: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(ClaudeHookSettings.helperName)").path
    }

    /// The file path as the row shows it (`~/.claude/settings.json`).
    var displayPath: String { HomePath.abbreviate(settingsFile.path) }

    // MARK: - Status

    func status() -> ClaudeHookSettings.Status {
        let text: String?
        switch read() {
        case .unreadable: return .unreadable
        case .missing: text = nil
        case .text(let found): text = found
        }
        return ClaudeHookSettings.status(settingsText: text, helper: helper, timeoutSeconds: timeoutSeconds)
    }

    /// What the row should show: translocated / no helper come first (no file is read then).
    func rowState() -> InboxHookRow.State {
        if AgentConnect.isTranslocated(helper) { return .translocated }
        if !FileManager.default.isExecutableFile(atPath: helper) { return .helperMissing }
        return .status(status())
    }

    // MARK: - Install / Remove

    /// Adds our three hooks (or repoints them at this copy). Already installed: nothing is written.
    func install() throws {
        guard !AgentConnect.isTranslocated(helper), FileManager.default.isExecutableFile(atPath: helper) else {
            throw Failure.helperMissing
        }
        let current: String?
        switch read() {
        case .unreadable: throw Failure.unreadable
        case .missing: current = nil
        case .text(let text): current = text
        }
        if ClaudeHookSettings.status(settingsText: current, helper: helper, timeoutSeconds: timeoutSeconds) == .installed {
            return
        }
        let updated: String
        do {
            updated = try ClaudeHookSettings.install(settingsText: current, helper: helper, timeoutSeconds: timeoutSeconds)
        } catch {
            throw Failure.unreadable
        }
        try write(updated)
        guard status() == .installed else { throw Failure.notAsIntended }
    }

    /// Takes our hooks out (any helper path), leaving everything else. No file: nothing happens.
    func remove() throws {
        let current: String
        switch read() {
        case .unreadable: throw Failure.unreadable
        case .missing: return
        case .text(let text): current = text
        }
        let updated: String
        do {
            updated = try ClaudeHookSettings.remove(settingsText: current)
        } catch {
            throw Failure.unreadable
        }
        if updated != current { try write(updated) }
        guard status() == .notInstalled else { throw Failure.notAsIntended }
    }

    // MARK: - File work

    private enum ReadResult: Equatable {
        case missing
        case unreadable
        case text(String)
    }

    /// Follows symlinks (reading a link reads its target). A dangling link counts as missing.
    private func read() -> ReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: settingsFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        // `String(data:encoding:)` returns nil for bytes that are not valid UTF-8; `String(decoding:)`
        // would quietly replace them, and writing that back would change the file.
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .text(text)
    }

    private func write(_ text: String) throws {
        let target = try Self.resolvingLinks(settingsFile)
        let folder = target.deletingLastPathComponent()
        let manager = FileManager.default

        // Keep the file's permissions; a new file is private to the owner.
        var mode: mode_t = 0o600
        if let existing = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int {
            mode = mode_t(existing & 0o7777)
        } else if !manager.fileExists(atPath: folder.path) {
            // Only Install gets here with a missing folder (Remove stops when there is no file).
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            } catch {
                throw Failure.io(error.localizedDescription)
            }
        }

        // Temp file next to the target, so the rename stays on one volume (rename is only atomic
        // there). O_EXCL: never reuse an existing file; the random name makes a clash unlikely.
        let temp = folder.appending(path: ".\(target.lastPathComponent).singularity-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(text.utf8))
            // `open` applies the umask to `mode`; set it exactly (e.g. 0644 stays 0644).
            guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
            try handle.close()
        } catch {
            unlink(temp.path)
            throw (error as? Failure) ?? Failure.io(error.localizedDescription)
        }
        guard rename(temp.path, target.path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temp.path)
            throw Failure.io(message)
        }
    }

    /// The file a symlink finally points at (relative links are relative to the link's folder).
    /// Not a link: the URL itself. Links in the *folders* above need no care: `rename` follows them.
    static func resolvingLinks(_ url: URL) throws -> URL {
        var current = url
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appending(path: destination)
        }
        throw Failure.io("Too many levels of symbolic links: \(url.path)")
    }
}
