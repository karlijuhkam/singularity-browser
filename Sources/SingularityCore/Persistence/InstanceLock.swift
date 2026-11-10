import Darwin
import Foundation

/// Makes sure only one copy of Singularity works on a data folder at a time. Two copies would
/// take each other's agent socket and overwrite each other's Space files with stale tabs.
///
/// It is an advisory `flock` on `<root>/.run/lock`: the system drops it when the process ends,
/// crashes included, so a stale lock can't keep the app from starting.
public final class InstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Returns the held lock, or nil if another running copy holds it. If the lock file can't be
    /// created at all (read-only disk…), that is not "another copy": the caller gets a lock object
    /// anyway and the app starts, as it did before this check existed.
    public static func acquire(paths: Paths) -> InstanceLock? {
        let folder = paths.root.appending(path: ".run", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(folder.appending(path: "lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return InstanceLock(descriptor: -1) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return InstanceLock(descriptor: fd)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
