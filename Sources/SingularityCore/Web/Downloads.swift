import Foundation

/// Where a download is saved, and how its progress reads in the sidebar.
public enum DownloadNaming {
    /// The file to save to inside `folder`: the suggested name, or "name (2).ext", "name (3).ext", …
    /// when that is taken. `exists` is a parameter so this can be tested without touching the disk.
    public static func destination(suggestedFilename: String, folder: URL, exists: (URL) -> Bool) -> URL {
        // Never trust a path from the server: keep only the last component, and no hidden files.
        var name = (suggestedFilename as NSString).lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == "/" { name = "download" }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var counter = 2
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appending(path: numbered)
            counter += 1
        }
        return candidate
    }
}

public enum DownloadPhase: Equatable, Sendable {
    case running
    case finished
    case failed(String)
    case cancelled
}

public enum DownloadText {
    /// The small line under a download's name: "3.1 MB of 12 MB", "12 MB", "Cancelled", the error.
    /// `total` is nil or ≤ 0 when the server didn't say how big the file is.
    public static func status(phase: DownloadPhase, received: Int64, total: Int64?) -> String {
        switch phase {
        case .running:
            if let total, total > 0 { return "\(size(received)) of \(size(total))" }
            return size(received)
        case .finished:
            return size(max(received, total ?? 0))
        case .failed(let message):
            return message.isEmpty ? "Failed" : "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// 0…1 for the progress bar, or nil when the size is unknown (the bar then just pulses).
    public static func fraction(received: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// "850 KB", "3.1 MB". Decimal units, as Finder shows them.
    public static func size(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) bytes" }
        // One decimal below 10 ("3.1 MB"), none above ("12 MB").
        let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return "\(text) \(units[unit])"
    }
}
