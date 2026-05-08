"""
Render the Deks app icon at 1024x1024 with a Liquid Glass treatment.

Why a Python renderer instead of an SVG -> PNG pipeline:
- Faithful gaussian blur for the soft drop shadow (Pillow's
  ImageFilter.GaussianBlur). librsvg / inkscape aren't installed,
  and we want to avoid a build dep.
- 4x supersample + LANCZOS downsample produces clean pill caps
  and crisp specular highlights at small render sizes.

The SVG (deks-icon.svg) remains the documented spec. This script
is the source of truth for the actual raster.

Run:
    python3 mobile/design/icons/render_icons.py

Output (overwrites in place):
    mobile/PersonalDashboard/Resources/Assets.xcassets/AppIcon.appiconset/
        AppIcon.png

Saved with no alpha channel (RGB), 1024x1024, sRGB.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------
# Geometry — must match deks-icon.svg exactly.
# ---------------------------------------------------------------------------
CANVAS = 1024
SUPERSAMPLE = 4  # render at 4096, downsample to 1024 with LANCZOS

# Bars: common left edge x=77, height 88, pill caps via radius=44.
# Vertical rhythm: y=300, 468, 636.
BAR_X = 77
BAR_H = 88
BAR_RADIUS = BAR_H // 2  # 44
BAR_YS = (300, 468, 636)
BAR_WIDTHS = (563, 870, 717)  # 55% / 85% / 70%

# Accent dot — right of top bar, vertically centered.
DOT_CX = 700
DOT_CY = 344
DOT_R = 24

# Gradient extent for the bar body — top of top bar to bottom of bottom bar.
GRADIENT_TOP_Y = 300
GRADIENT_BOTTOM_Y = 636 + BAR_H  # 724

# ---------------------------------------------------------------------------
# Liquid Glass tuning. All values are in 1024-space and get *SUPERSAMPLE'd
# at draw time.
# ---------------------------------------------------------------------------

# Background: warm dark vertical gradient. Top is a touch lighter so the
# eye reads "ambient light from above" without becoming busy.
BG_TOP = (26, 22, 32)        # #1A1620
BG_BOTTOM = (15, 14, 20)     # #0F0E14

# Bar body: bright at top, warming to cream at bottom (whole-stack span).
BAR_TOP = (255, 255, 255)        # #FFFFFF
BAR_BOTTOM = (245, 241, 234)     # #F5F1EA

# Edge rim: a hairline lighter outline so the glass body has a defined edge.
RIM_COLOR = (255, 255, 255)
RIM_ALPHA = 90               # ~35% opacity, layered as a 1px stroke at 1024
RIM_WIDTH_PX = 1             # at final 1024 — so 4px in supersample

# Top specular highlight: a bright band along the top ~30% of each bar.
# This is the single most recognisable Liquid Glass cue and survives at 60x60.
SPECULAR_HEIGHT_FRAC = 0.45  # fraction of bar height covered by the highlight
SPECULAR_TOP_ALPHA = 235     # near-opaque white at the very top edge
SPECULAR_BOTTOM_ALPHA = 0    # fades to invisible

# Drop shadow: gaussian blur, displaced down a few px, low opacity.
SHADOW_OFFSET_Y = 3          # px at 1024
SHADOW_BLUR_RADIUS = 7       # px at 1024
SHADOW_ALPHA = 60            # ~24% — the bars need to feel grounded

# Accent dot: same treatment but smaller. The solid white core stays punchy
# and a small specular cap on top sells the "glass bead" feel.
DOT_RIM_ALPHA = 110
DOT_SPECULAR_R = 18          # specular cap circle radius
DOT_SPECULAR_OFFSET_Y = -6   # nudged toward the top of the dot


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        round(a[0] + (b[0] - a[0]) * t),
        round(a[1] + (b[1] - a[1]) * t),
        round(a[2] + (b[2] - a[2]) * t),
    )


def make_vertical_gradient(
    size: int,
    top_color: tuple[int, int, int],
    bottom_color: tuple[int, int, int],
    top_y: int = 0,
    bottom_y: int | None = None,
) -> Image.Image:
    """RGB vertical gradient image, full canvas size. Anything outside
    [top_y, bottom_y] is clamped to the end colors (matches SVG pad)."""
    if bottom_y is None:
        bottom_y = size
    img = Image.new("RGB", (1, size))
    px = img.load()
    span = max(1, bottom_y - top_y)
    for y in range(size):
        if y <= top_y:
            color = top_color
        elif y >= bottom_y:
            color = bottom_color
        else:
            t = (y - top_y) / span
            color = lerp(top_color, bottom_color, t)
        px[0, y] = color
    return img.resize((size, size), Image.NEAREST)


def make_specular_alpha(width: int, height: int, frac: float, top_a: int, bottom_a: int) -> Image.Image:
    """Greyscale alpha mask: bright at top, fading to 0 by `frac` of height,
    transparent below. Used as a mask to paint the white highlight band."""
    mask = Image.new("L", (1, height), 0)
    mpx = mask.load()
    band_h = max(1, int(height * frac))
    for y in range(band_h):
        t = y / band_h
        # Smooth ease-out so the highlight doesn't have a hard horizon.
        eased = (1 - t) ** 2
        alpha = int(round(bottom_a + (top_a - bottom_a) * eased))
        mpx[0, y] = alpha
    return mask.resize((width, height), Image.NEAREST)


def shape_mask(size: int, draw_shapes) -> Image.Image:
    """Build an L-mode mask of all bar/dot shapes for shadow / clipping."""
    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    draw_shapes(mdraw, fill=255)
    return mask


def render() -> None:
    scale = SUPERSAMPLE
    size = CANVAS * scale

    # 1) Background — warm dark vertical gradient.
    canvas = make_vertical_gradient(size, BG_TOP, BG_BOTTOM, top_y=0, bottom_y=size)

    # Helper that draws every solid shape (3 bars + accent dot) onto a
    # given drawing context with a given fill. Used for both the shadow
    # mask and the body fill mask.
    def draw_all_shapes(d: ImageDraw.ImageDraw, fill) -> None:
        for y, w in zip(BAR_YS, BAR_WIDTHS):
            d.rounded_rectangle(
                (BAR_X * scale, y * scale, (BAR_X + w) * scale, (y + BAR_H) * scale),
                radius=BAR_RADIUS * scale,
                fill=fill,
            )
        d.ellipse(
            (
                (DOT_CX - DOT_R) * scale,
                (DOT_CY - DOT_R) * scale,
                (DOT_CX + DOT_R) * scale,
                (DOT_CY + DOT_R) * scale,
            ),
            fill=fill,
        )

    # 2) Drop shadow — render the shape silhouette as a black layer with
    #    low alpha, gaussian-blurred, displaced downward, then composited
    #    onto the background.
    shadow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow_layer)
    draw_all_shapes(sdraw, fill=(0, 0, 0, SHADOW_ALPHA))
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(SHADOW_BLUR_RADIUS * scale))
    # Offset down. We do this by pasting onto a fresh layer.
    shadow_offset = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_offset.paste(shadow_layer, (0, SHADOW_OFFSET_Y * scale), shadow_layer)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow_offset)

    # 3) Bar body — vertical gradient from #FFFFFF (top of top bar)
    #    to #F5F1EA (bottom of bottom bar), pasted through the shape mask.
    body_gradient = make_vertical_gradient(
        size,
        BAR_TOP,
        BAR_BOTTOM,
        top_y=GRADIENT_TOP_Y * scale,
        bottom_y=GRADIENT_BOTTOM_Y * scale,
    )
    body_mask = shape_mask(size, draw_all_shapes)
    canvas.paste(body_gradient, (0, 0), body_mask)

    # 4) Hairline rim — draw the same shapes but as a stroked outline.
    rim_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rdraw = ImageDraw.Draw(rim_layer)
    rim_stroke = (RIM_COLOR[0], RIM_COLOR[1], RIM_COLOR[2], RIM_ALPHA)
    sw = max(1, RIM_WIDTH_PX * scale)
    for y, w in zip(BAR_YS, BAR_WIDTHS):
        rdraw.rounded_rectangle(
            (BAR_X * scale, y * scale, (BAR_X + w) * scale, (y + BAR_H) * scale),
            radius=BAR_RADIUS * scale,
            outline=rim_stroke,
            width=sw,
        )
    # Accent dot rim is slightly stronger so it survives at thumbnail size.
    dot_rim = (RIM_COLOR[0], RIM_COLOR[1], RIM_COLOR[2], DOT_RIM_ALPHA)
    rdraw.ellipse(
        (
            (DOT_CX - DOT_R) * scale,
            (DOT_CY - DOT_R) * scale,
            (DOT_CX + DOT_R) * scale,
            (DOT_CY + DOT_R) * scale,
        ),
        outline=dot_rim,
        width=sw,
    )
    canvas = Image.alpha_composite(canvas, rim_layer)

    # 5) Top specular highlight — a bright band on the top ~45% of each
    #    bar, produced by painting a white layer through a per-bar
    #    vertical alpha mask. This is the iconic Liquid Glass cue.
    spec_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for y, w in zip(BAR_YS, BAR_WIDTHS):
        bar_left = BAR_X * scale
        bar_top = y * scale
        bar_right = (BAR_X + w) * scale
        bar_bottom = (y + BAR_H) * scale
        bar_w = bar_right - bar_left
        bar_h = bar_bottom - bar_top

        # Per-bar specular: white band fading down.
        spec_alpha = make_specular_alpha(
            bar_w, bar_h, SPECULAR_HEIGHT_FRAC, SPECULAR_TOP_ALPHA, SPECULAR_BOTTOM_ALPHA
        )
        white_band = Image.new("RGBA", (bar_w, bar_h), (255, 255, 255, 255))
        # Clip to the rounded-rect shape of THIS bar so the highlight
        # follows the pill cap, not the bounding box.
        bar_clip = Image.new("L", (bar_w, bar_h), 0)
        bcd = ImageDraw.Draw(bar_clip)
        bcd.rounded_rectangle(
            (0, 0, bar_w, bar_h),
            radius=BAR_RADIUS * scale,
            fill=255,
        )
        # Combine the band's vertical falloff with the rounded-rect clip.
        combined_mask = ImageChops.multiply(spec_alpha, bar_clip)
        spec_layer.paste(white_band, (bar_left, bar_top), combined_mask)
    canvas = Image.alpha_composite(canvas, spec_layer)

    # 6) Accent dot specular cap — small bright crescent on top of the dot
    #    so it reads as a glass bead rather than a flat circle.
    dot_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ddraw = ImageDraw.Draw(dot_layer)
    spec_cy = DOT_CY + DOT_SPECULAR_OFFSET_Y
    ddraw.ellipse(
        (
            (DOT_CX - DOT_SPECULAR_R) * scale,
            (spec_cy - DOT_SPECULAR_R) * scale,
            (DOT_CX + DOT_SPECULAR_R) * scale,
            (spec_cy + DOT_SPECULAR_R) * scale,
        ),
        fill=(255, 255, 255, 200),
    )
    # Clip to the dot's silhouette so the spec cap doesn't overflow.
    dot_clip = Image.new("L", (size, size), 0)
    dcdraw = ImageDraw.Draw(dot_clip)
    dcdraw.ellipse(
        (
            (DOT_CX - DOT_R) * scale,
            (DOT_CY - DOT_R) * scale,
            (DOT_CX + DOT_R) * scale,
            (DOT_CY + DOT_R) * scale,
        ),
        fill=255,
    )
    # Soften the spec cap with a small blur so the edge isn't a hard arc.
    dot_layer = dot_layer.filter(ImageFilter.GaussianBlur(2 * scale))
    # Apply the dot clip after blur so we don't get a halo outside.
    r, g, b, a = dot_layer.split()
    a = ImageChops.multiply(a, dot_clip)
    dot_layer = Image.merge("RGBA", (r, g, b, a))
    canvas = Image.alpha_composite(canvas, dot_layer)

    # 7) Downsample and save without alpha (iOS clips the corner radius).
    final = canvas.convert("RGB").resize((CANVAS, CANVAS), Image.LANCZOS)

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
    out_path = out_dir / "AppIcon.png"
    final.save(out_path, format="PNG", optimize=True)
    print(f"wrote {out_path} ({CANVAS}x{CANVAS}, no alpha)")


if __name__ == "__main__":
    render()
