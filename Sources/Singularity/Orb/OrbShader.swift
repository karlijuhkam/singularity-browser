import CoreGraphics
import Metal
import simd

/// The Singularity orb, drawn by the GPU: a port of the three.js shader on singularity.rroosa.ee
/// (`IridescentWaveMaterial`), by way of `scripts/icon/render_orb.py`, which is the reference.
/// The maths below follows that script line for line; only the plumbing is Metal's.
///
/// How it draws: one triangle large enough to cover the whole view. For every pixel the fragment
/// shader shoots a ray from the camera, intersects it with the sphere and shades the hit point.
/// Pixels whose ray misses get alpha 0, and the silhouette is antialiased over about one pixel.
/// Colours are written as they are (sRGB values into a plain `bgra8Unorm` target), as three.js
/// writes them to a canvas. Output alpha is premultiplied, which Core Animation expects.
@MainActor
enum OrbRenderer {
    /// Scene constants, as on the site (and in `render_orb.py`).
    static let radius: Float = 2.2
    static let cameraZ: Float = 6
    /// tan of the silhouette's half-angle; the view shows `silhouette / 0.96` either side of the
    /// centre, so the sphere fills 96 % of the square.
    static let silhouette = radius / (cameraZ * cameraZ - radius * radius).squareRoot()
    static let halfExtent = silhouette / 0.96
    /// The ripple origin before the pointer moves.
    static let defaultCursor = SIMD3<Float>(-1.5, -1.5, 0.5)

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// What drawing needs: the GPU, a queue for it, and the compiled shader.
    struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLRenderPipelineState
    }

    /// Compiled once, on first use. Nil without a Metal device, or if the shader fails to compile
    /// (the view then falls back to the PNG).
    static let pipeline: Pipeline? = makePipeline()

    /// The shader's uniforms. Same layout as `Uniforms` in the Metal source: `float3` is 16 bytes
    /// in Metal, like `SIMD3<Float>` in Swift, so the fields line up (0, 16, 32; 48 in all).
    private struct Uniforms {
        var color: SIMD3<Float>
        var cursor: SIMD3<Float>
        var time: Float
    }

    /// Encodes one frame into a render pass that has a `bgra8Unorm` colour target.
    static func draw(into encoder: MTLRenderCommandEncoder, time: Float, whiteOrb: Bool, cursor: SIMD3<Float>) {
        guard let pipeline else { return }
        var uniforms = Uniforms(color: whiteOrb ? SIMD3(1, 1, 1) : SIMD3(0, 0, 0), cursor: cursor, time: time)
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Renders one frame off screen, `pixels` × `pixels`, with the same pipeline the view uses.
    static func image(pixels: Int, time: Float, whiteOrb: Bool, cursor: SIMD3<Float>) -> CGImage? {
        guard let pipeline, pixels > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: pixels,
                                                                  height: pixels, mipmapped: false)
        descriptor.usage = .renderTarget
        // Apple Silicon shares memory between CPU and GPU; elsewhere the texture needs a copy
        // the CPU can read (`.managed`, synchronised below).
        descriptor.storageMode = pipeline.device.hasUnifiedMemory ? .shared : .managed
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor),
              let commands = pipeline.queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        draw(into: encoder, time: time, whiteOrb: whiteOrb, cursor: cursor)
        encoder.endEncoding()
        if texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()

        let bytesPerRow = pixels * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixels)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        }
        // bgra8Unorm in memory is B, G, R, A: a little-endian 32-bit pixel with alpha first.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The point under the pointer, as the unit vector from the sphere's centre to where the ray
    /// through that point hits the sphere (view space, like the site's cursor). `point` is in the
    /// view's coordinates with y up, `side` the view's width (= height). Nil off the sphere.
    static func sphereDirection(at point: CGPoint, side: CGFloat) -> SIMD3<Float>? {
        guard side > 0 else { return nil }
        let x = Float(point.x / side * 2 - 1) * halfExtent
        let y = Float(point.y / side * 2 - 1) * halfExtent
        let direction = simd_normalize(SIMD3<Float>(x, y, -1))
        let center = SIMD3<Float>(0, 0, -cameraZ)
        let b = simd_dot(direction, center)
        let disc = b * b - (cameraZ * cameraZ - radius * radius)
        guard disc > 0 else { return nil }
        let hit = direction * (b - disc.squareRoot())
        return simd_normalize(hit - center)
    }

    private static func makePipeline() -> Pipeline? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            // Compiled from source at run time: SwiftPM has no step for .metal files.
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "orbVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "orbFragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            return Pipeline(device: device, queue: queue, state: state)
        } catch {
            NSLog("Singularity: the orb shader did not compile, showing the still image: \(error)")
            return nil
        }
    }

    // The Metal Shading Language source. Names follow the site's GLSL (and `render_orb.py`).
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float RADIUS = 2.2;
    constant float CAMERA_Z = 6.0;

    struct Uniforms {
        float3 color;   // uColor: (1,1,1) white orb, (0,0,0) black orb
        float3 cursor;  // uCursor: ripple origin, view space
        float time;     // uTime, seconds
    };

    struct VertexOut {
        float4 position [[position]];
        float2 plane;   // the point on the image plane z = -1 this pixel looks through
    };

    // ---- Ashima simplex noise (the GLSL `snoise`) ----

    float3 mod289(float3 x) { return x - 289.0 * floor(x / 289.0); }
    float4 mod289(float4 x) { return x - 289.0 * floor(x / 289.0); }
    float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }

    float snoise(float3 v) {
        const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
        float3 i = floor(v + dot(v, float3(C.y)));
        float3 x0 = v - i + dot(i, float3(C.x));

        float3 g = step(x0.yzx, x0.xyz);
        float3 l = 1.0 - g;
        float3 i1 = min(g, l.zxy);
        float3 i2 = max(g, l.zxy);
        float3 x1 = x0 - i1 + C.x;
        float3 x2 = x0 - i2 + 2.0 * C.x;
        float3 x3 = x0 - 1.0 + 3.0 * C.x;

        i = mod289(i);
        float4 p = permute(permute(permute(
                  i.z + float4(0.0, i1.z, i2.z, 1.0))
                + i.y + float4(0.0, i1.y, i2.y, 1.0))
                + i.x + float4(0.0, i1.x, i2.x, 1.0));

        float n_ = 1.0 / 7.0;
        float3 ns = float3(2.0 * n_, 0.5 * n_ - 1.0, n_);   // n_ * D.wyz - D.xzx
        float4 j = p - 49.0 * floor(p * ns.z * ns.z);
        float4 x_ = floor(j * ns.z);
        float4 y_ = floor(j - 7.0 * x_);
        float4 x = x_ * ns.x + ns.y;
        float4 y = y_ * ns.x + ns.y;
        float4 h = 1.0 - abs(x) - abs(y);

        float4 b0 = float4(x.xy, y.xy);
        float4 b1 = float4(x.zw, y.zw);
        float4 s0 = floor(b0) * 2.0 + 1.0;
        float4 s1 = floor(b1) * 2.0 + 1.0;
        float4 sh = -step(h, float4(0.0));
        float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
        float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

        float3 p0 = float3(a0.xy, h.x);
        float3 p1 = float3(a0.zw, h.y);
        float3 p2 = float3(a1.xy, h.z);
        float3 p3 = float3(a1.zw, h.w);
        float4 norm = 1.79284291400159 - 0.85373472095314 * float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3));
        p0 *= norm.x;
        p1 *= norm.y;
        p2 *= norm.z;
        p3 *= norm.w;

        float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
        m = m * m;
        return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
    }

    // ---- the orb ----

    // One triangle covering the view: (-1,-1), (3,-1), (-1,3) in clip space.
    vertex VertexOut orbVertex(uint id [[vertex_id]]) {
        float2 clip = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
        float silhouette = RADIUS / sqrt(CAMERA_Z * CAMERA_Z - RADIUS * RADIUS);
        float halfExtent = silhouette / 0.96;
        VertexOut out;
        out.position = float4(clip, 0.0, 1.0);
        out.plane = clip * halfExtent;   // clip y points up, as view space does
        return out;
    }

    fragment float4 orbFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        // Edge coverage: distance to the silhouette circle on the image plane, in pixels.
        float silhouette = RADIUS / sqrt(CAMERA_Z * CAMERA_Z - RADIUS * RADIUS);
        float pixel = fwidth(in.plane.x);
        float coverage = saturate((silhouette - length(in.plane)) / pixel + 0.5);
        if (coverage <= 0.0) {
            return float4(0.0);
        }

        // Ray/sphere intersection; camera at the origin looking down -z, sphere centre (0, 0, -6).
        // Rays just outside the silhouette (the antialiased edge) are clamped to graze it.
        float3 dir = normalize(float3(in.plane, -1.0));
        float3 center = float3(0.0, 0.0, -CAMERA_Z);
        float b = dot(dir, center);
        float disc = max(b * b - (CAMERA_Z * CAMERA_Z - RADIUS * RADIUS), 0.0);
        float3 P = dir * (b - sqrt(disc));

        float3 uColor = u.color;
        float3 uCursor = u.cursor;
        float uTime = u.time;

        float3 normal = normalize(P - center);   // vNormal
        float3 vViewPosition = -P;
        float3 viewDir = normalize(vViewPosition);

        float noise = snoise(normal * 1.2 + uTime * 0.1);
        float3 rippleOrigin = normalize(uCursor);
        float dist = length(normal - rippleOrigin);
        float distortionStrength = smoothstep(0.1, 2.0, dist) * 0.3;
        float distortedDist = dist + noise * distortionStrength;
        float nonLinearDist = pow(max(distortedDist, 0.001), 0.5);
        float wavePhase = nonLinearDist * 80.0 - uTime * 3.0;
        float wave = sin(wavePhase);
        float waveSlope = cos(wavePhase);

        float colorNoise = snoise(normal * 0.8 + uTime * 0.1);
        float lightness = dot(uColor, float3(0.299, 0.587, 0.114));
        float3 cBlue = float3(0.3, 0.35, 0.4) + uColor * 0.5;
        float3 cCyan = float3(0.35, 0.4, 0.45) + uColor * 0.5;
        float3 cOrange = float3(0.4, 0.35, 0.3) + uColor * 0.5;
        float t = colorNoise * 0.5 + 0.5;
        float3 cool = mix(cBlue, cCyan, t);
        float3 warm = mix(cCyan, cOrange, t);
        float3 waveColor = mix(cool, warm, t);
        waveColor = mix(waveColor, float3(1.0), lightness * 0.8);

        float wavePattern = smoothstep(0.3, 0.7, wave * 0.5 + 0.5);
        float3 darkState = float3(0.02, 0.02, 0.03) + uColor * 0.94;
        float3 lightState = waveColor * (0.25 + lightness * 1.15);
        float3 finalColor = mix(darkState, lightState, wavePattern);

        float3 direction = normalize(normal - rippleOrigin + 0.001);
        float3 tangent = normalize(direction - dot(direction, normal) * normal);
        float3 perturbedNormal = normalize(normal - tangent * waveSlope * 0.15);
        float3 lightDir = normalize(float3(5.0, 5.0, 5.0));
        float diff = max(dot(perturbedNormal, lightDir), 0.0);
        float ambient = 0.2 + lightness * 0.2;
        finalColor = finalColor * (ambient + diff * 0.7);

        float3 reflectDir = reflect(-lightDir, perturbedNormal);
        float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0);
        float fresnel = pow(1.0 - max(dot(viewDir, perturbedNormal), 0.0), 3.0);
        finalColor = finalColor + spec * 0.3 + fresnel * 0.2;

        // RGB rim light: three lobes circling the edge at different speeds.
        float rimPower = pow(1.0 - max(dot(viewDir, normal), 0.0), 3.0);
        float angle = atan2(vViewPosition.y, vViewPosition.x);
        float rAngle = sin(uTime * 0.5) * 3.0;
        float gAngle = sin(uTime * 0.7 + 2.0) * 3.0;
        float bAngle = sin(uTime * 0.3 + 4.0) * 3.0;
        float3 rim = float3(smoothstep(0.0, 1.0, cos(angle - rAngle)),
                            smoothstep(0.0, 1.0, cos(angle - gAngle)),
                            smoothstep(0.0, 1.0, cos(angle - bAngle)));
        finalColor = finalColor + rim * rimPower * 0.6;

        // Premultiplied alpha: the colour is scaled by the edge coverage.
        return float4(saturate(finalColor) * coverage, coverage);
    }
    """
}
