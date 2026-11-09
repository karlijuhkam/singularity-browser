import Foundation

extension PluginError {
    /// One short, plain sentence for Settings and the approval sheet ("Problem: <this>").
    /// No raw decoder dumps: those go in `detail`, shown behind a "Details" disclosure.
    /// Names and paths in here come from the plugin, so show the result as plain text.
    public var userMessage: String {
        switch self {
        case .invalidSitePattern(let site): return "“\(site)” isn't a valid site pattern"
        case .invalidJSON(let text):
            // package.json problems carry a short text of their own; plugin.json ones a decoder dump.
            if text.hasPrefix("package.json") { return "package.json isn't valid" }
            if text.hasPrefix("bun.lock") { return "bun.lock isn't valid" }
            return "plugin.json isn't valid JSON"
        case .invalidID(let id): return "“\(id)” isn't a valid plugin id (lowercase letters, digits and dashes)"
        case let .idDoesNotMatchFolder(id, folder): return "its id “\(id)” doesn't match its folder name “\(folder)”"
        case .missingFile(let path): return "the file \(path) is missing"
        case .unknownPermission(let name): return "it asks for an unknown permission “\(name)”"
        case .refusedCommand(let name): return "it may not run “\(name)”"
        case .networkNotAvailable: return "it asks for internet access, which plugins can't have yet"
        case .missingLockfile: return "it uses packages but has no bun.lock"
        case .pageSiteNotPermitted(let site): return "its page script runs on \(site) without permission"
        case .symlinkNotAllowed(let path):
            return path == "." ? "its folder is a symbolic link" : "it contains a symbolic link (\(path))"
        case .unsupportedFile(let path): return "it contains a special file (\(path))"
        case .unreadable: return "its files can't be read"
        case .unsupportedPackage(let name):
            return "it uses “\(name)”, which isn't an exact npm registry version matching bun.lock"
        case .forbiddenFile(let name): return "it contains \(name), which plugins may not have"
        }
    }

    /// The full technical text (e.g. the JSON decoder's message), for a "Details" disclosure.
    public var detail: String {
        switch self {
        case .invalidJSON(let text), .unreadable(let text): return text
        default: return String(describing: self)
        }
    }
}
