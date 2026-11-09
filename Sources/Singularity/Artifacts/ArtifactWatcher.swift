import CoreServices
import Foundation
import SingularityCore

/// Watches a folder with FSEvents (macOS's file-change notification service) and reports which
/// files changed, as paths relative to the folder.
///
/// FSEvents is a C API: we hand it a plain C function as callback plus an opaque pointer to
/// ourselves, and it calls back on the main queue with arrays of paths and flags.
@MainActor
final class ArtifactWatcher {
    struct Change: Equatable {
        enum Kind { case changed, removed }
        let relativePath: String
        let kind: Kind
    }

    private let root: URL
    private let onChange: @MainActor ([Change]) -> Void
    private var stream: FSEventStreamRef?

    init(root: URL, onChange: @escaping @MainActor ([Change]) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        // The callback can't capture variables (it is a C function pointer), so `self` travels
        // through `context.info` and is turned back into an object inside.
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ArtifactWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes, `paths` is a CFArray of CFStrings.
            let pathList = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            // We scheduled the stream on the main queue, so we are on the main thread here.
            MainActor.assumeIsolated {
                watcher.handle(paths: pathList, flags: flagList)
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents   // report individual files, not just folders
            | kFSEventStreamCreateFlagUseCFTypes // paths as CFStrings
            | kFSEventStreamCreateFlagNoDefer    // deliver the first event of a burst right away
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, // seconds to batch events (editors often write a file in several steps)
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Must be called before the watcher is released: FSEvents holds an unretained pointer to it.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        var changes: [Change] = []
        var seen = Set<String>()
        for (path, flag) in zip(paths, flags) {
            guard flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
            let url = URL(fileURLWithPath: path)
            guard let relative = ArtifactFiles.relativePath(of: url, in: root),
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  seen.insert(relative).inserted
            else { continue }
            // Flags are unreliable across save strategies (in-place write vs. write-then-rename),
            // so ask the file system what is true now.
            let exists = FileManager.default.fileExists(atPath: url.path)
            changes.append(Change(relativePath: relative, kind: exists ? .changed : .removed))
        }
        if !changes.isEmpty { onChange(changes) }
    }
}
