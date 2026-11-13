import AppKit
import Observation
import SingularityCore
import WebKit

/// One download shown in the sidebar.
struct DownloadItem: Identifiable {
    let id = UUID()
    var filename: String
    var destination: URL
    var phase: DownloadPhase = .running
    var received: Int64 = 0
    var total: Int64?
}

/// The downloads of this run of the app (all Spaces), for the sidebar's Downloads list.
/// Nothing is stored: the list is empty again after a restart, the files stay in ~/Downloads.
@MainActor
@Observable
final class DownloadCenter {
    /// Newest first.
    private(set) var items: [DownloadItem] = []

    /// WebKit's object for each running download, to read progress from and to cancel.
    @ObservationIgnored private var running: [UUID: WKDownload] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?

    /// Where downloads are saved: ~/Downloads. Tests point it at their own folder.
    @ObservationIgnored var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    /// Called when WebKit asks where to save. Picks a free name in ~/Downloads and lists the download.
    func begin(_ download: WKDownload, suggestedFilename: String, expectedBytes: Int64) -> URL {
        let destination = DownloadNaming.destination(suggestedFilename: suggestedFilename, folder: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let item = DownloadItem(filename: destination.lastPathComponent, destination: destination,
                                total: expectedBytes > 0 ? expectedBytes : nil)
        items.insert(item, at: 0)
        running[item.id] = download
        startPolling()
        return destination
    }

    func finished(_ download: WKDownload) {
        guard let id = id(of: download) else { return }
        readProgress(id, download)
        running[id] = nil
        update(id) { $0.phase = .finished }
        // Makes the Downloads stack in the Dock bounce, as Safari does.
        if let item = items.first(where: { $0.id == id }) {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                         object: item.destination.path)
        }
    }

    func failed(_ download: WKDownload, error: Error) {
        guard let id = id(of: download) else { return }
        running[id] = nil
        // A cancelled download also arrives here; keep "Cancelled".
        update(id) { if $0.phase == .running { $0.phase = .failed(error.localizedDescription) } }
    }

    func cancel(_ id: UUID) {
        guard let download = running.removeValue(forKey: id) else { return }
        let destination = items.first { $0.id == id }?.destination
        update(id) { $0.phase = .cancelled }
        // WebKit tells the download's delegate nothing about a cancel; the page's controller
        // stays alive for its download until told that it is over.
        WebTabController.downloadEnded(download)
        download.cancel { _ in
            // Half a file is of no use to anyone. The name was free when we picked it, so this
            // can only remove what this download wrote.
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }
    }

    /// Removes everything that is no longer running from the list (the files stay).
    func clearFinished() {
        items.removeAll { $0.phase != .running }
    }

    func remove(_ id: UUID) {
        guard running[id] == nil else { return }
        items.removeAll { $0.id == id }
    }

    func open(_ item: DownloadItem) {
        guard item.phase == .finished else { return }
        NSWorkspace.shared.open(item.destination)
    }

    func showInFinder(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
    }

    var hasRunning: Bool { !running.isEmpty }

    // MARK: - Internals

    private func id(of download: WKDownload) -> UUID? {
        running.first { $0.value === download }?.key
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func readProgress(_ id: UUID, _ download: WKDownload) {
        // `Progress` counts bytes for downloads; totalUnitCount is -1 or 0 when unknown.
        let received = download.progress.completedUnitCount
        let total = download.progress.totalUnitCount
        update(id) {
            if $0.received != received { $0.received = received }
            if total > 0, $0.total != total { $0.total = total }
        }
    }

    /// Reads the running downloads' byte counts a few times a second. (Progress can also be
    /// observed with KVO, but that calls back on background threads for every chunk.)
    private func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while let self, !self.running.isEmpty {
                for (id, download) in self.running { self.readProgress(id, download) }
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.poller = nil
        }
    }
}
