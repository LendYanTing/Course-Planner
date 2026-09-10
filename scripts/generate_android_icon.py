#!/usr/bin/env python3
"""Generate the Android launcher icon for Course Planner.

Design: a check mark in the top-left and a pen in the bottom-right (task done,
still editable) on a Material Indigo 600 field.

Android icon model
------------------
* Adaptive icon (API 26+): two 108x108dp layers. Only the central 72x72dp is
  guaranteed visible; the outer 18dp is mask/parallax bleed. Both glyphs are
  kept inside the inscribed circle of that 72dp safe zone, so no launcher mask
  (circle, squircle, rounded square, teardrop) can clip them.
* Legacy (API 24-25): a plain bitmap. We crop the 108-space to the 72dp safe
  zone and scale it down, which is what Android Studio's Image Asset tool does.

The vector layers (drawable/*.xml) are authored by hand from the same
coordinates; keep them in sync if you change anything here.

Usage:  python scripts/generate_android_icon.py
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw

# --- palette (Material Design) ---------------------------------------------
BG = (0x39, 0x49, 0xAB, 255)  # Indigo 600
FG = (0xFF, 0xFF, 0xFF, 255)  # white glyphs

# --- geometry in the 108x108 adaptive viewport -----------------------------
VIEWPORT = 108.0
SAFE_MIN, SAFE_MAX = 18.0, 90.0  # central 72dp safe zone

# The two glyphs sit on a diagonal; pulling each toward the centre by this many
# units tightens the composition. Verified to stay inside the safe zone's
# inscribed circle (r=36 about the centre) and to leave a visible gap between
# the check's tail and the pen's nib.
PULL_TOGETHER = 7.0

# Check mark: polyline (25,37) -> (32,46) -> (50,27), round caps/joins,
# shifted down-right by PULL_TOGETHER.
CHECK = [
    (25.0 + PULL_TOGETHER, 37.0 + PULL_TOGETHER),
    (32.0 + PULL_TOGETHER, 46.0 + PULL_TOGETHER),
    (50.0 + PULL_TOGETHER, 27.0 + PULL_TOGETHER),
]
CHECK_STROKE = 7.0

# Pen: nib apex at (56,87), body running up-right at 45 degrees,
# shifted up-left by PULL_TOGETHER.
PEN = [
    (56.00 - PULL_TOGETHER, 87.00 - PULL_TOGETHER),  # nib apex
    (68.73 - PULL_TOGETHER, 82.75 - PULL_TOGETHER),  # tip base, right
    (88.51 - PULL_TOGETHER, 62.97 - PULL_TOGETHER),  # body top, right
    (80.03 - PULL_TOGETHER, 54.49 - PULL_TOGETHER),  # body top, left
    (60.24 - PULL_TOGETHER, 74.26 - PULL_TOGETHER),  # tip base, left
]

LEGACY_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

SS = 8  # supersampling factor for the 108-space render


def render_art(background: tuple[int, int, int, int] | None) -> Image.Image:
    """Renders the glyph art in 108-space at SS scale (optionally no field)."""
    side = int(VIEWPORT * SS)
    img = Image.new("RGBA", (side, side), background or (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    def px(p):
        return (p[0] * SS, p[1] * SS)

    # check mark
    draw.line([px(p) for p in CHECK], fill=FG, width=int(CHECK_STROKE * SS), joint="curve")
    r = CHECK_STROKE * SS / 2.0
    for p in CHECK:  # round caps
        x, y = px(p)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=FG)

    # pen
    draw.polygon([px(p) for p in PEN], fill=FG)

    return img


def safe_crop(img: Image.Image) -> Image.Image:
    """Crops 108-space to the central 72dp safe zone."""
    box = (
        int(SAFE_MIN * SS),
        int(SAFE_MIN * SS),
        int(SAFE_MAX * SS),
        int(SAFE_MAX * SS),
    )
    return img.crop(box)


def circular(img: Image.Image) -> Image.Image:
    """Applies a circular alpha mask (legacy round icon)."""
    size = img.size[0]
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size - 1, size - 1], fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res = os.path.join(root, "flutter", "android", "app", "src", "main", "res")

    art = render_art(BG)
    safe = safe_crop(art)

    for density, size in LEGACY_SIZES.items():
        out_dir = os.path.join(res, f"mipmap-{density}")
        os.makedirs(out_dir, exist_ok=True)

        square = safe.resize((size, size), Image.LANCZOS)
        square.save(os.path.join(out_dir, "ic_launcher.png"), optimize=True)

        round_icon = circular(safe.resize((size, size), Image.LANCZOS))
        round_icon.save(os.path.join(out_dir, "ic_launcher_round.png"), optimize=True)

        print(f"mipmap-{density}: {size}x{size} -> ic_launcher.png, ic_launcher_round.png")

    print("done")


if __name__ == "__main__":
    main()
