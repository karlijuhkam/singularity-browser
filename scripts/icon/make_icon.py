"""Composes the app icon: the orb (render_orb.py) on a macOS-style rounded tile.

    python3 scripts/icon/make_icon.py --variant white --out AppIcon-dark-1024.png

Follows Apple's macOS icon grid: a 1024 px canvas with an 824 px rounded square ("squircle",
approximated by a superellipse) centred in it, plus the soft drop shadow macOS icons use. The orb
takes about 72 % of the tile.

Variants (the app uses white for dark mode and light for light mode, like the site):
  white  white orb on a dark tile (the site's dark theme)
  light  black orb on a light tile (the site's light theme)
  dark   black orb on a dark tile (not used)
"""
import argparse

import numpy as np
from PIL import Image, ImageFilter

from render_orb import render

CANVAS = 1024
TILE = 824
ORB_FRACTION = 0.72


def squircle_mask(size, exponent=5.0):
    """Superellipse |x|^n + |y|^n <= 1, antialiased by 4x supersampling."""
    n = size * 4
    c = (np.arange(n) + 0.5) / n * 2.0 - 1.0
    x, y = np.meshgrid(c, c)
    inside = (np.abs(x) ** exponent + np.abs(y) ** exponent) <= 1.0
    mask = Image.fromarray((inside * 255).astype(np.uint8), "L")
    return mask.resize((size, size), Image.LANCZOS)


def tile_background(variant):
    """A subtle radial gradient, lighter at the top centre, like light falling on the tile."""
    c = (np.arange(TILE) + 0.5) / TILE
    x, y = np.meshgrid(c, c)
    r = np.sqrt((x - 0.5) ** 2 + (y - 0.35) ** 2)
    t = np.clip(r / 0.85, 0.0, 1.0)[..., None]
    if variant == "light":
        inner, outer = np.array([248, 248, 250]), np.array([224, 224, 230])
    else:
        inner, outer = np.array([34, 34, 42]), np.array([8, 8, 11])
    rgb = inner * (1 - t) + outer * t
    alpha = np.full((TILE, TILE, 1), 255.0)
    return Image.fromarray(np.concatenate([rgb, alpha], axis=-1).astype(np.uint8), "RGBA")


def make_icon(variant, time):
    base = "white" if variant == "white" else "black"
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - TILE) // 2

    # Drop shadow under the tile (macOS icon convention): soft, slightly below.
    mask = squircle_mask(TILE)
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_layer = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 90))
    shadow.paste(shadow_layer, (offset, offset + 12), mask)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))

    # The tile, with the orb in its centre.
    tile = tile_background(variant)
    orb_size = int(TILE * ORB_FRACTION)
    orb = render(orb_size, time, base, supersample=3)
    tile.alpha_composite(orb, ((TILE - orb_size) // 2, (TILE - orb_size) // 2))
    clipped = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    clipped.paste(tile, (0, 0), mask)
    canvas.alpha_composite(clipped, (offset, offset))
    return canvas


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", choices=["dark", "white", "light"], default="dark")
    parser.add_argument("--time", type=float, default=7.0, help="moment of the orb animation (see render_orb.py)")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    make_icon(args.variant, args.time).save(args.out)


if __name__ == "__main__":
    main()
