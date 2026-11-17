import Foundation
import SingularityCore

/// Takes an extension from wherever it comes from (a folder, a .zip/.xpi, a .crx, Chrome Web Store)
/// to an unpacked folder in a private staging folder, ready for the approval sheet. Nothing here
/// installs: `ExtensionCenter.approve` moves the staged folder into `extensions/<id>/` only after
/// the owner pressed Install.
///
/// No new dependency: zips are unpacked with macOS's own `/usr/bin/ditto`, which keeps every entry
/// inside the target folder (`../` and absolute names land inside it). Symbolic links, hard links
/// and anything but plain files and folders are then refused by `PluginFingerprint.listFiles`.
enum ExtensionInstaller {
    struct Staged: Sendable {
        /// The staging folder (deleted after install or cancel).
        let stage: URL
        /// The unpacked extension (has `manifest.json` at its top).
        let root: URL
        /// The Chrome id, when the file was a verified .crx (store or file).
        let chromeID: String?
    }

    enum Failure: LocalizedError {
        case notAnExtension
        case damaged(String)
        case download(String)

        var errorDescription: String? {
            switch self {
            case .notAnExtension: return "This isn't a browser extension: there is no manifest.json in it."
            case .damaged(let detail): return "This extension file is damaged or not what it claims to be. (\(detail))"
            case .download(let detail): return "The extension couldn't be downloaded: \(detail)"
            }
        }
    }

    /// Largest download or file we take (uBlock Origin Lite is about 10 MB).
    static let maxBytes = 200 * 1024 * 1024

    /// Unpacks `source` (a folder, .zip, .xpi or .crx) into a new folder under `installDirectory`.
    static func stage(_ source: URL, installDirectory: URL) throws -> Staged {
        let stage = try newStage(installDirectory)
        do {
            let target = stage.appending(path: "x", directoryHint: .isDirectory)
            var chromeID: String?
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else { throw Failure.notAnExtension }
            if isFolder.boolValue {
                // A copy keeps symbolic links as links; listFiles refuses them below.
                try FileManager.default.copyItem(at: source, to: target)
            } else {
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                guard data.count <= maxBytes else { throw Failure.damaged("too large") }
                if data.prefix(4) == Data("Cr24".utf8) {
                    let crx = try verified(data, expectedID: nil)
                    chromeID = crx.id
                    try unzip(crx.zip, stage: stage, into: target)
                } else {
                    try unzip(data, stage: stage, into: target)
                }
            }
            return Staged(stage: stage, root: try findRoot(target), chromeID: chromeID)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    /// Unpacks a .crx downloaded from the store, checked to be extension `id`.
    static func stage(crx data: Data, id: String, installDirectory: URL) throws -> Staged {
        let stage = try newStage(installDirectory)
        do {
            let crx = try verified(data, expectedID: id)
            let target = stage.appending(path: "x", directoryHint: .isDirectory)
            try unzip(crx.zip, stage: stage, into: target)
            return Staged(stage: stage, root: try findRoot(target), chromeID: crx.id)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    /// Downloads extension `id` from Google's update server: the address is fixed in code, the id
    /// (checked) is the only part that varies, and only Google's two hosts may answer.
    static func downloadFromStore(id: String) async throws -> Data {
        guard let url = ChromeWebStore.downloadURL(id: id) else { throw Failure.download("not a Chrome Web Store id") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.download("no answer") }
        guard ChromeWebStore.isDownloadHost(http.url?.host()) else { throw Failure.download("answered from an unexpected host") }
        guard http.statusCode == 200 else {
            throw Failure.download(http.statusCode == 204 ? "Chrome Web Store has no file for it" : "status \(http.statusCode)")
        }
        guard data.count <= maxBytes else { throw Failure.download("too large") }
        return data
    }

    private static func verified(_ data: Data, expectedID: String?) throws -> CRXFile {
        do {
            return try CRXFile.verified(data, expectedID: expectedID)
        } catch let failure as CRXFile.Failure {
            throw Failure.damaged("\(failure)")
        }
    }

    private static func newStage(_ installDirectory: URL) throws -> URL {
        let stage = installDirectory.appending(path: "install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return stage
    }

    private static func unzip(_ zip: Data, stage: URL, into target: URL) throws {
        let file = stage.appending(path: "package.zip")
        try zip.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", file.path, target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.damaged("it couldn't be unpacked") }
    }

    /// The folder with `manifest.json`: the top, or a zip's single top folder.
    private static func findRoot(_ target: URL) throws -> URL {
        let fm = FileManager.default
        var root = target
        if !fm.fileExists(atPath: target.appending(path: "manifest.json").path) {
            let entries = (try? fm.contentsOfDirectory(atPath: target.path))?.filter { $0 != "__MACOSX" && $0 != ".DS_Store" } ?? []
            guard entries.count == 1 else { throw Failure.notAnExtension }
            root = target.appending(path: entries[0], directoryHint: .isDirectory)
            guard fm.fileExists(atPath: root.appending(path: "manifest.json").path) else { throw Failure.notAnExtension }
        }
        do {
            _ = try PluginFingerprint.listFiles(folder: root)
        } catch {
            throw Failure.damaged("it contains links or special files")
        }
        return root
    }
}
