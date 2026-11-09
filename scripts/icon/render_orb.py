"""Renders the Singularity orb as a still image.

A direct port of the three.js shader on singularity.rroosa.ee (`IridescentWaveMaterial`):
a sphere with water-like ripples, embossed lighting, a glassy fresnel edge and an RGB rim light
whose three lobes circle the edge (the "rainbow edge"). Instead of the GPU, numpy evaluates the
fragment shader for every pixel of a ray-traced sphere.

    python3 scripts/icon/render_orb.py --time 4.2 --base black --size 1024 --out orb.png

Scene, as on the site: camera at z=6 looking at the origin, sphere radius 2.2, ripple origin at
the default cursor (-1.5, -1.5, 0.5). The vertex displacement (0.005) is too small to see and is
left out. The background is transparent.
"""
import argparse

import numpy as np
from PIL import Image


# ---- Ashima simplex noise (same constants as the GLSL `snoise`) ---------------------------------

def _mod289(x):
    return x - 289.0 * np.floor(x / 289.0)


def _permute(x):
    return _mod289(((x * 34.0) + 1.0) * x)


def snoise(v):
    """3D simplex noise for an array of points, shape (N, 3) -> (N,)."""
    C = np.array([1.0 / 6.0, 1.0 / 3.0])
    i = np.floor(v + np.sum(v, axis=1, keepdims=True) * C[1])
    x0 = v - i + np.sum(i, axis=1, keepdims=True) * C[0]

    g = (x0 >= x0[:, [1, 2, 0]]).astype(float)        # step(x0.yzx, x0.xyz)
    l = 1.0 - g
    i1 = np.minimum(g, l[:, [2, 0, 1]])
    i2 = np.maximum(g, l[:, [2, 0, 1]])
    x1 = x0 - i1 + C[0]
    x2 = x0 - i2 + 2.0 * C[0]
    x3 = x0 - 1.0 + 3.0 * C[0]

    i = _mod289(i)
    zero = np.zeros(len(v))
    one = np.ones(len(v))
    p = _permute(_permute(_permute(
        i[:, 2:3] + np.stack([zero, i1[:, 2], i2[:, 2], one], axis=1))
        + i[:, 1:2] + np.stack([zero, i1[:, 1], i2[:, 1], one], axis=1))
        + i[:, 0:1] + np.stack([zero, i1[:, 0], i2[:, 0], one], axis=1))

    n_ = 1.0 / 7.0
    ns = np.array([2.0 * n_, 0.5 * n_ - 1.0, n_])     # n_ * D.wyz - D.xzx
    j = p - 49.0 * np.floor(p * ns[2] * ns[2])
    x_ = np.floor(j * ns[2])
    y_ = np.floor(j - 7.0 * x_)
    x = x_ * ns[0] + ns[1]
    y = y_ * ns[0] + ns[1]
    h = 1.0 - np.abs(x) - np.abs(y)

    b0 = np.stack([x[:, 0], x[:, 1], y[:, 0], y[:, 1]], axis=1)
    b1 = np.stack([x[:, 2], x[:, 3], y[:, 2], y[:, 3]], axis=1)
    s0 = np.floor(b0) * 2.0 + 1.0
    s1 = np.floor(b1) * 2.0 + 1.0
    sh = -(h <= 0.0).astype(float)                   # -step(h, 0)
    a0 = b0[:, [0, 2, 1, 3]] + s0[:, [0, 2, 1, 3]] * sh[:, [0, 0, 1, 1]]
    a1 = b1[:, [0, 2, 1, 3]] + s1[:, [0, 2, 1, 3]] * sh[:, [2, 2, 3, 3]]

    p0 = np.stack([a0[:, 0], a0[:, 1], h[:, 0]], axis=1)
    p1 = np.stack([a0[:, 2], a0[:, 3], h[:, 1]], axis=1)
    p2 = np.stack([a1[:, 0], a1[:, 1], h[:, 2]], axis=1)
    p3 = np.stack([a1[:, 2], a1[:, 3], h[:, 3]], axis=1)
    dots = np.stack([np.sum(q * q, axis=1) for q in (p0, p1, p2, p3)], axis=1)
    norm = 1.79284291400159 - 0.85373472095314 * dots
    p0, p1, p2, p3 = (q * norm[:, k:k + 1] for k, q in enumerate((p0, p1, p2, p3)))

    m = np.maximum(0.6 - np.stack([np.sum(q * q, axis=1) for q in (x0, x1, x2, x3)], axis=1), 0.0)
    m = m * m
    grads = np.stack([np.sum(p0 * x0, axis=1), np.sum(p1 * x1, axis=1),
                      np.sum(p2 * x2, axis=1), np.sum(p3 * x3, axis=1)], axis=1)
    return 42.0 * np.sum(m * m * grads, axis=1)


# ---- helpers matching GLSL built-ins -------------------------------------------------------------

def normalize(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def mix(a, b, t):
    return a * (1.0 - t) + b * t


def dot(a, b):
    return np.sum(a * b, axis=-1, keepdims=True)


# ---- the orb ---------------------------------------------------------------------------------------

def render(size, time, base, supersample=2):
    n = size * supersample
    radius, camera_z = 2.2, 6.0
    # Frame the sphere so its silhouette fills ~96 % of the image (the site's camera crops it).
    silhouette = radius / np.sqrt(camera_z ** 2 - radius ** 2)   # tan of the silhouette's half-angle
    half_extent = silhouette / 0.96

    # One ray per (sub)pixel, in view space (camera at the origin looking down -z).
    coords = (np.arange(n) + 0.5) / n * 2.0 - 1.0
    px, py = np.meshgrid(coords * half_extent, -coords * half_extent)
    dirs = normalize(np.stack([px, py, -np.ones_like(px)], axis=-1))

    # Ray/sphere intersection; the sphere's centre is at (0, 0, -6) in view space.
    center = np.array([0.0, 0.0, -camera_z])
    b = np.sum(dirs * center, axis=-1)
    disc = b * b - (camera_z ** 2 - radius ** 2)
    hit = disc > 0
    t_hit = b - np.sqrt(np.where(hit, disc, 0.0))
    P = dirs[hit] * t_hit[hit][:, None]                          # hit points, view space

    uColor = np.array([0.0, 0.0, 0.0]) if base == "black" else np.array([1.0, 1.0, 1.0])
    uCursor = np.array([-1.5, -1.5, 0.5])
    uTime = time

    normal = normalize(P - center)                               # vNormal (view-space normal)
    vViewPosition = -P
    viewDir = normalize(vViewPosition)

    noise = snoise(normal * 1.2 + uTime * 0.1)[:, None]
    rippleOrigin = normalize(uCursor)
    dist = np.linalg.norm(normal - rippleOrigin, axis=-1, keepdims=True)
    distortionStrength = smoothstep(0.1, 2.0, dist) * 0.3
    distortedDist = dist + noise * distortionStrength
    nonLinearDist = np.power(np.maximum(distortedDist, 0.001), 0.5)
    wavePhase = nonLinearDist * 80.0 - uTime * 3.0
    wave = np.sin(wavePhase)
    waveSlope = np.cos(wavePhase)

    colorNoise = snoise(normal * 0.8 + uTime * 0.1)[:, None]
    lightness = float(np.dot(uColor, [0.299, 0.587, 0.114]))
    cBlue = np.array([0.3, 0.35, 0.4]) + uColor * 0.5
    cCyan = np.array([0.35, 0.4, 0.45]) + uColor * 0.5
    cOrange = np.array([0.4, 0.35, 0.3]) + uColor * 0.5
    t = colorNoise * 0.5 + 0.5
    cool = mix(cBlue, cCyan, t)
    warm = mix(cCyan, cOrange, t)
    waveColor = mix(cool, warm, t)
    waveColor = mix(waveColor, np.ones(3), lightness * 0.8)

    wavePattern = smoothstep(0.3, 0.7, wave * 0.5 + 0.5)
    darkState = np.array([0.02, 0.02, 0.03]) + uColor * 0.94
    lightState = waveColor * (0.25 + lightness * 1.15)
    finalColor = mix(darkState, lightState, wavePattern)

    direction = normalize(normal - rippleOrigin + 0.001)
    tangent = normalize(direction - dot(direction, normal) * normal)
    perturbedNormal = normalize(normal - tangent * waveSlope * 0.15)
    lightDir = normalize(np.array([5.0, 5.0, 5.0]))
    diff = np.maximum(dot(perturbedNormal, lightDir), 0.0)
    ambient = 0.2 + lightness * 0.2
    finalColor = finalColor * (ambient + diff * 0.7)

    reflectDir = -lightDir - 2.0 * dot(-lightDir, perturbedNormal) * perturbedNormal
    spec = np.power(np.maximum(dot(viewDir, reflectDir), 0.0), 32.0)
    fresnel = np.power(1.0 - np.maximum(dot(viewDir, perturbedNormal), 0.0), 3.0)
    finalColor = finalColor + spec * 0.3 + fresnel * 0.2

    # RGB rim light: three lobes circling the edge at different speeds.
    rimPower = np.power(1.0 - np.maximum(dot(viewDir, normal), 0.0), 3.0)
    angle = np.arctan2(vViewPosition[:, 1], vViewPosition[:, 0])[:, None]
    rAngle = np.sin(uTime * 0.5) * 3.0
    gAngle = np.sin(uTime * 0.7 + 2.0) * 3.0
    bAngle = np.sin(uTime * 0.3 + 4.0) * 3.0
    rim = np.concatenate([smoothstep(0.0, 1.0, np.cos(angle - a)) for a in (rAngle, gAngle, bAngle)], axis=1)
    finalColor = finalColor + rim * rimPower * 0.6

    # Into an RGBA image; the sphere's edge is antialiased by the supersampling below.
    image = np.zeros((n, n, 4))
    image[hit, :3] = np.clip(finalColor, 0.0, 1.0)
    image[hit, 3] = 1.0
    # sRGB output as on the web (three.js writes the shader colour as-is to the canvas).
    image8 = (image * 255.0 + 0.5).astype(np.uint8)
    out = Image.fromarray(image8, "RGBA")
    if supersample > 1:
        out = out.resize((size, size), Image.LANCZOS)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--time", type=float, default=4.0, help="moment of the site's animation, in seconds")
    parser.add_argument("--base", choices=["black", "white"], default="black", help="orb colour (site: light mode = black)")
    parser.add_argument("--size", type=int, default=1024)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    render(args.size, args.time, args.base).save(args.out)


if __name__ == "__main__":
    main()
