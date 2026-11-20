import Foundation

/// The files an agent hands to a page's file chooser (`file_upload`): checked before the owner
/// is asked, so the card shows real files, resolved (symlinks followed).
public enum UploadFiles {
    public static let maxFiles = 20

    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Absolute paths of existing, readable regular files; at most `maxFiles`, and one unless the
    /// chooser takes several. An empty list is allowed (it cancels the chooser).
    public static func check(_ paths: [String], multiple: Bool, fileManager: FileManager = .default) throws -> [URL] {
        guard paths.count <= maxFiles else { throw Refusal(description: "At most \(maxFiles) files at once.") }
        guard multiple || paths.count <= 1 else { throw Refusal(description: "This file chooser takes one file.") }
        return try paths.map { path in
            guard path.hasPrefix("/") else { throw Refusal(description: "“\(path)” is not an absolute path.") }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw Refusal(description: "There is no file at “\(path)”.")
            }
            guard !isFolder.boolValue else { throw Refusal(description: "“\(path)” is a folder, not a file.") }
            guard fileManager.isReadableFile(atPath: url.path) else { throw Refusal(description: "“\(path)” can't be read.") }
            return url
        }
    }
}
