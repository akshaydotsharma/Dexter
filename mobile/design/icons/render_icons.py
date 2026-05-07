"""
Render the Deks app icon PNGs (light + dark) at 1024x1024.

Why a Python renderer instead of an SVG -> PNG pipeline:
- The icon geometry is trivial (3 rounded rects + 1 circle + 1 linear gradient).
- No rsvg/inkscape on this machine, and we want to avoid adding a build dep.
- Pillow with 4x supersample + LANCZOS downsample produces perfectly clean
  pill caps and is exactly the pipeline the previous light-only render used.

The two SVGs in this directory remain the source of truth for designers /
diffing. This script just keeps the rasters in lockstep.

Run:
    python3 mobile/design/icons/render_icons.py

Outputs (overwrites in place):
    mobile/PersonalDashboard/Resources/Assets.xcassets/AppIcon.appiconset/
        AppIcon-Light.png
        AppIcon-Dark.png

Both files are saved with no alpha channel (RGB), 1024x1024, sRGB.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

# Geometry — must match deks-icon.svg / deks-icon-dark.svg exactly.
CANVAS = 1024
SUPERSAMPLE = 4  # render at 4096, downsample to 1024 with LANCZOS

# Bars: common left edge x=77, height 88, pill caps via radius=44.
# Vertical rhythm: y=300, 468, 636.
BAR_X = 77
BAR_H = 88
BAR_RADIUS = BAR_H // 2  # 44
BAR_YS = (300, 468, 636)
BAR_WIDTHS = (563, 870, 717)  # 55% / 85% / 70%

# Accent dot — right of top bar, vertically centered on it.
DOT_CX = 700
DOT_CY = 344
DOT_R = 24

# Gradient extent for the dark variant — top of top bar to bottom of bottom bar.
GRADIENT_TOP_Y = 300
GRADIENT_BOTTOM_Y = 636 + BAR_H  # 724

# Palettes.
LIGHT_BG = (245, 241, 234)   # #F5F1EA — warm cream
LIGHT_INK = (31, 26, 31)     # #1F1A1F — warm dark

DARK_BG = (20, 19, 26)       # #14131A — warm dark, NOT pure black
DARK_GRADIENT_TOP = (255, 255, 255)         # #FFFFFF
DARK_GRADIENT_BOTTOM = (245, 241, 234)      # #F5F1EA — same cream as light bg
DARK_DOT = (255, 255, 255)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        round(a[0] + (b[0] - a[0]) * t),
        round(a[1] + (b[1] - a[1]) * t),
        round(a[2] + (b[2] - a[2]) * t),
    )


def make_dark_gradient_image(scale: int) -> Image.Image:
    """Build a 1xH gradient image spanning GRADIENT_TOP_Y to GRADIENT_BOTTOM_Y, then
    stretch to full canvas. Anything above/below the gradient stops is clamped to
    the end colors — matches SVG userSpaceOnUse + default spreadMethod=pad."""
    h = CANVAS * scale
    img = Image.new("RGB", (1, h))
    px = img.load()
    top = GRADIENT_TOP_Y * scale
    bottom = GRADIENT_BOTTOM_Y * scale
    span = bottom - top
    for y in range(h):
        if y <= top:
            color = DARK_GRADIENT_TOP
        elif y >= bottom:
            color = DARK_GRADIENT_BOTTOM
        else:
            t = (y - top) / span
            color = lerp(DARK_GRADIENT_TOP, DARK_GRADIENT_BOTTOM, t)
        px[0, y] = color
    return img.resize((CANVAS * scale, h), Image.NEAREST)


def render(variant: str, out_path: Path) -> None:
    scale = SUPERSAMPLE
    size = CANVAS * scale

    if variant == "light":
        canvas = Image.new("RGB", (size, size), LIGHT_BG)
        draw = ImageDraw.Draw(canvas)
        for y, w in zip(BAR_YS, BAR_WIDTHS):
            draw.rounded_rectangle(
                (BAR_X * scale, y * scale, (BAR_X + w) * scale, (y + BAR_H) * scale),
                radius=BAR_RADIUS * scale,
                fill=LIGHT_INK,
            )
        draw.ellipse(
            (
                (DOT_CX - DOT_R) * scale,
                (DOT_CY - DOT_R) * scale,
                (DOT_CX + DOT_R) * scale,
                (DOT_CY + DOT_R) * scale,
            ),
            fill=LIGHT_INK,
        )

    elif variant == "dark":
        canvas = Image.new("RGB", (size, size), DARK_BG)
        gradient = make_dark_gradient_image(scale)

        # Build a mask of all bars + dot, then paste the gradient through it.
        mask = Image.new("L", (size, size), 0)
        mdraw = ImageDraw.Draw(mask)
        for y, w in zip(BAR_YS, BAR_WIDTHS):
            mdraw.rounded_rectangle(
                (BAR_X * scale, y * scale, (BAR_X + w) * scale, (y + BAR_H) * scale),
                radius=BAR_RADIUS * scale,
                fill=255,
            )
        canvas.paste(gradient, (0, 0), mask)

        # Accent dot painted on top, solid white (top of gradient stop).
        ddraw = ImageDraw.Draw(canvas)
        ddraw.ellipse(
            (
                (DOT_CX - DOT_R) * scale,
                (DOT_CY - DOT_R) * scale,
                (DOT_CX + DOT_R) * scale,
                (DOT_CY + DOT_R) * scale,
            ),
            fill=DARK_DOT,
        )

    else:
        raise ValueError(f"unknown variant: {variant}")

    out = canvas.resize((CANVAS, CANVAS), Image.LANCZOS)
    # Save without alpha. PNG with mode=RGB has no alpha channel.
    out.save(out_path, format="PNG", optimize=True)
    print(f"wrote {out_path} ({CANVAS}x{CANVAS}, no alpha)")


def main() -> None:
    repo_root = Path(__file__).resolve().parents[3]
    out_dir = (
        repo_root
        / "mobile"
        / "PersonalDashboard"
        / "Resources"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    render("light", out_dir / "AppIcon-Light.png")
    render("dark", out_dir / "AppIcon-Dark.png")


if __name__ == "__main__":
    main()
