import AppKit
import Observation
import SingularityCore

/// Favicons cached as 64×64 PNGs in each Space's `favicons/` folder, plus an in-memory cache.
@MainActor
@Observable
final class FaviconStore {
    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Bumped whenever a new icon arrives, so views that asked for a missing icon re-render.
    private var version = 0

    init(paths: Paths) {
        self.paths = paths
    }

    func image(slug: String, host: String) -> NSImage? {
        _ = version // registers this view as depending on `version`
        let key = "\(slug)|\(host)"
        if let cached = cache[key] { return cached }
        let file = paths.faviconFile(slug, host: host)
        guard let image = NSImage(contentsOf: file) else { return nil }
        cache[key] = image
        return image
    }

    func hasIcon(slug: String, host: String) -> Bool {
        cache["\(slug)|\(host)"] != nil || FileManager.default.fileExists(atPath: paths.faviconFile(slug, host: host).path)
    }

    /// Downloads an icon and stores it as PNG. Failures are silent: the row shows a globe instead.
    func fetch(_ iconURL: URL, slug: String, host: String) async {
        let key = "\(slug)|\(host)"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        guard let (data, response) = try? await URLSession.shared.data(from: iconURL),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let source = NSImage(data: data),
              let png = Self.pngData(source, size: 64)
        else { return }

        let file = paths.faviconFile(slug, host: host)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
        } catch {
            return
        }
        cache[key] = NSImage(data: png)
        version += 1
    }

    /// Redraws any image (ICO, SVG, PNG…) into a square bitmap and encodes it as PNG.
    private static func pngData(_ image: NSImage, size: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
