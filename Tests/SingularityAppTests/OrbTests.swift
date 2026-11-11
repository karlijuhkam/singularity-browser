import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import Testing
@testable import Singularity

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

extension AppTests {
    /// The Metal orb against stills from `scripts/icon/render_orb.py` (the site's shader in numpy).
    /// Skipped, with a note, on a machine without a Metal device.
    @MainActor @Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "No Metal device on this machine"))
    struct OrbTests {
        @Test(arguments: [true, false]) func matchesTheSiteShader(whiteOrb: Bool) throws {
            _ = MainRunLoopGuard.start
            let image = try #require(OrbRenderer.image(pixels: 256, time: 4.0, whiteOrb: whiteOrb,
                                                      cursor: SIMD3(-1.5, -1.5, 0.5)))
            let reference = try fixtureImage(whiteOrb ? "orb-white-t4.png" : "orb-black-t4.png")
            // Mean absolute difference per channel, 0…255, over pixels well inside the sphere
            // (the edge is antialiased differently). The port is the same maths, so it is small.
            //
            // Why 8 for white (not 6) and 2 for black: the black orb differs by about 0.7, the white
            // one by about 6.0. Nearly all of that is one quirk of the reference, not of the port.
            // In `snoise`, seven of the 49
            // gradient corners have h = 1 - |x| - |y| exactly 0 in exact maths; numpy (float64) and
            // the GPU (float32, like the site's GLSL) round that 0 to opposite signs, so `step(h, 0)`
            // picks opposite gradient signs there and one smooth patch of ripples shifts. With the
            // reference's h rounded as float32 the difference drops to about 0.2 for both orbs.
            #expect(meanDifference(image, reference, insideRadiusFraction: 0.9) < (whiteOrb ? 8 : 2))
        }

        @Test func isTransparentOutsideTheSphere() throws {
            _ = MainRunLoopGuard.start
            let image = try #require(OrbRenderer.image(pixels: 64, time: 0, whiteOrb: true, cursor: SIMD3(-1.5, -1.5, 0.5)))
            #expect(alpha(of: image, x: 0, y: 0) == 0)
            #expect(alpha(of: image, x: 32, y: 32) == 255)
        }

        /// The pointer's position becomes the ripple origin: a unit vector from the sphere's
        /// centre to the point under the pointer (view space, y up), or nil off the sphere.
        @Test func pointerBecomesAPointOnTheSphere() throws {
            _ = MainRunLoopGuard.start
            let centre = try #require(OrbRenderer.sphereDirection(at: CGPoint(x: 48, y: 48), side: 96))
            #expect(simd_distance(centre, SIMD3(0, 0, 1)) < 1e-5)
            let upperRight = try #require(OrbRenderer.sphereDirection(at: CGPoint(x: 72, y: 72), side: 96))
            #expect(upperRight.x > 0 && upperRight.y > 0 && upperRight.z > 0)
            #expect(abs(simd_length(upperRight) - 1) < 1e-5)
            #expect(OrbRenderer.sphereDirection(at: CGPoint(x: 2, y: 2), side: 96) == nil)
        }
    }
}

extension AppTests {
    /// When the live orb animates (`OrbAnimation.shouldAnimate`). Pure logic: no Metal needed.
    @MainActor @Suite struct OrbAnimationTests {
        /// Everything in favour of animating; each test changes one fact.
        private func animates(key: Bool = true, visible: Bool = true, hidden: Bool = false,
                              reduceMotion: Bool = false, stopsWhenIdle: Bool = true,
                              idle: TimeInterval = 0) -> Bool {
            OrbAnimation.shouldAnimate(windowIsKey: key, windowIsVisible: visible, appIsHidden: hidden,
                                       reduceMotion: reduceMotion, stopsWhenIdle: stopsWhenIdle,
                                       secondsSincePointerMoved: idle)
        }

        @Test func animatesInTheKeyWindowWhileThePointerWasRecent() {
            #expect(animates())
            #expect(animates(idle: 29.9))
        }

        @Test func notInTheKeyWindowItStops() {
            #expect(!animates(key: false))
            // Also where it does not stop when idle (the welcome flow).
            #expect(!animates(key: false, stopsWhenIdle: false))
        }

        @Test func coveredHiddenOrReduceMotionStops() {
            #expect(!animates(visible: false))
            #expect(!animates(hidden: true))
            #expect(!animates(reduceMotion: true))
            #expect(!animates(reduceMotion: true, stopsWhenIdle: false))
        }

        @Test func thirtySecondsWithoutThePointerStopsOnlyWhenAskedTo() {
            #expect(OrbAnimation.idleLimit == 30)
            #expect(!animates(idle: 30))
            #expect(!animates(idle: 3600))
            #expect(animates(stopsWhenIdle: false, idle: 30))
            #expect(animates(stopsWhenIdle: false, idle: 3600))
        }
    }
}

// MARK: - Helpers

private struct FixtureMissing: Error { let name: String }

private func fixtureImage(_ name: String) throws -> CGImage {
    let url = fixtures.appending(path: name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FixtureMissing(name: name) }
    return image
}

/// The image's pixels as RGBA bytes, top row first. Drawn into a context in the image's own
/// colour space, so the values are not colour-converted.
private func rgba(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
}

/// Mean absolute difference per colour channel (0…255) over the pixels whose centre lies within
/// `insideRadiusFraction` of the sphere's radius. The sphere fills 96 % of the square.
private func meanDifference(_ a: CGImage, _ b: CGImage, insideRadiusFraction: Double) -> Double {
    precondition(a.width == b.width && a.height == b.height, "images differ in size")
    let pa = rgba(a), pb = rgba(b)
    let size = Double(a.width)
    let limit = size / 2 * 0.96 * insideRadiusFraction
    var total = 0.0, count = 0
    for y in 0..<a.height {
        for x in 0..<a.width {
            let dx = Double(x) + 0.5 - size / 2, dy = Double(y) + 0.5 - size / 2
            guard (dx * dx + dy * dy).squareRoot() < limit else { continue }
            let i = (y * a.width + x) * 4
            for c in 0..<3 { total += abs(Double(pa[i + c]) - Double(pb[i + c])) }
            count += 3
        }
    }
    return count == 0 ? .infinity : total / Double(count)
}

private func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
    rgba(image)[(y * image.width + x) * 4 + 3]
}
