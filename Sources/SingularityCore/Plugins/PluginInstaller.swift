import Foundation

/// Copying a plugin into `~/Singularity/plugins/` (Settings → Plugins → Add Plugin…) and making
/// its data folder. Blocking file work: call it off the main thread.
public enum PluginInstaller {
    public enum AddError: Error, Equatable, Sendable {
        /// The chosen folder isn't a valid plugin.
        case invalid(PluginError)
        /// `plugins/<id>` exists already (remove that plugin first).
        case alreadyInstalled(String)
        /// The chosen folder is inside the plugins folder already.
        case alreadyInPluginsFolder
        case copyFailed(String)

        public var userMessage: String {
            switch self {
            case .invalid(let error): return "This folder isn't a plugin Singularity can use: \(error.userMessage)."
            case .alreadyInstalled(let id): return "A plugin with the id “\(id)” is already installed. Remove it first."
            case .alreadyInPluginsFolder: return "That folder is already in the plugins folder."
            case .copyFailed(let why): return "Couldn't copy the plugin: \(why)"
            }
        }
    }

    /// Checks `source`, copies it to `<pluginsDirectory>/<manifest id>` and returns the id.
    ///
    /// 1. The manifest is checked in place. Its folder name may differ from its id (it is copied
    ///    to a folder named after the id), anything else wrong is refused.
    /// 2. The folder must hold only regular files and folders: no symbolic links, nothing special.
    /// 3. It is copied (FileManager copies a link as a link, never what it points to) into a
    ///    staging folder on the same disk, checked again there (it could have changed meanwhile,
    ///    and now the folder name matches the id), then moved into place in one step. A plugin
    ///    with the same id is never replaced.
    public static func add(from source: URL, pluginsDirectory: URL) throws(AddError) -> String {
        let fm = FileManager.default
        // realpath(3), like everywhere else in the plugin code (URL.resolvingSymlinksInPath maps
        // /private/var back to /var, so two spellings of one folder could compare unequal). A
        // plugins folder that doesn't exist yet can't contain the source; a source that doesn't
        // exist fails below, when its manifest is read.
        if let sourcePath = try? PluginProcess.realPath(source),
           let pluginsPath = try? PluginProcess.realPath(pluginsDirectory),
           sourcePath == pluginsPath || sourcePath.hasPrefix(pluginsPath + "/") {
            throw .alreadyInPluginsFolder
        }

        let id: String
        do {
            id = try PluginManifest.load(from: source).id
        } catch .idDoesNotMatchFolder(let manifestID, _) {
            id = manifestID   // the id's format was checked before the folder name
        } catch {
            throw .invalid(error)
        }
        try checkFiles(source)

        let destination = pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
        if exists(destination) { throw .alreadyInstalled(id) }

        let staging: URL
        do {
            try fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            // A temporary folder on the same volume as the plugins folder, so the final move is a rename.
            staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: pluginsDirectory, create: true)
        } catch {
            throw .copyFailed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appending(path: id, directoryHint: .isDirectory)
        do { try fm.copyItem(at: source, to: staged) } catch { throw .copyFailed(error.localizedDescription) }

        do { _ = try PluginManifest.load(from: staged) } catch { throw .invalid(error) }
        try checkFiles(staged)

        if exists(destination) { throw .alreadyInstalled(id) }
        // moveItem refuses to overwrite, so a plugin that appeared meanwhile is kept.
        do { try fm.moveItem(at: staged, to: destination) } catch {
            if exists(destination) { throw .alreadyInstalled(id) }
            throw .copyFailed(error.localizedDescription)
        }
        return id
    }

    /// Creates a plugin's data folder (and its parent) readable by this user only (0700).
    public static func makeDataFolder(_ folder: URL) throws {
        let fm = FileManager.default
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: ownerOnly)
        // Also when they existed already (createDirectory leaves existing folders alone).
        try fm.setAttributes(ownerOnly, ofItemAtPath: folder.deletingLastPathComponent().path)
        try fm.setAttributes(ownerOnly, ofItemAtPath: folder.path)
    }

    private static func checkFiles(_ folder: URL) throws(AddError) {
        do {
            _ = try PluginFingerprint.listFiles(folder: folder)
        } catch let error as PluginError {
            throw .invalid(error)
        } catch {
            throw .invalid(.unreadable(error.localizedDescription))
        }
    }

    /// Without following a symlink (a dangling link still counts as existing).
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
