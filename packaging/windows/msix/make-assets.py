#!/usr/bin/env python3
"""Renders DeltaView's Microsoft Store images from the app icon, assets/brand/delta_view.svg.

Run it again after changing the icon:

    python3 packaging/windows/msix/make-assets.py

Needs cairosvg and Pillow (pip install cairosvg pillow). Writes:

  packaging/windows/msix/Assets/        the images AppxManifest.xml.in names
  packaging/windows/msix/store-logos/   Store listing art for Partner Center

The package images are drawn per size: the rounded body sits on whole pixels with a
1/16 margin, and the base of the delta lands on a pixel edge, so the 16 to 32 px
icons of the taskbar, Start and File Explorer stay sharp. On a light taskbar the pale
half of the body nearly disappears, so the altform-lightunplated set (which Windows
uses in light mode) gives the body a one-pixel indigo edge.
"""

import io
from pathlib import Path

import cairosvg
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ICON = (ROOT / "assets/brand/delta_view.svg").read_text()
ASSETS = HERE / "Assets"
STORE = HERE / "store-logos"

# Where the icon's parts sit on its 1024-unit canvas (see delta_view.svg).
VIEWBOX = 'viewBox="0 0 1024 1024"'
BODY_X, BODY_SIZE = 100, 824  # the rounded square
DELTA_BASE = "824,768 200,768"  # the two base corners of the delta
DELTA_BASE_Y = 768
BODY_END = "</g>\n</svg>"  # end of the group clipped to the body

SCALES = (100, 200, 400)
# Square44x44Logo sizes Windows looks for (taskbar, Start, Alt+Tab, File Explorer).
TARGET_SIZES = (16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256)


def replace(text: str, old: str, new: str, count: int = 1) -> str:
    """str.replace that fails when the icon no longer has what this script expects."""
    found = text.count(old)
    if found != count:
        raise SystemExit(f"delta_view.svg: expected {count} of {old!r}, found {found}")
    return text.replace(old, new)


def render(svg: str, width: int, height: int | None = None) -> Image.Image:
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=width, output_height=height or width)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def icon(size: int) -> Image.Image:
    """The icon as drawn, with its own transparent margin."""
    return render(ICON, size)


def fitted(size: int, light_edge: bool = False) -> Image.Image:
    """The icon at `size` px, its body fitted to whole pixels with a 1/16 margin."""
    margin = max(1, round(size / 16))
    k = (size - 2 * margin) / BODY_SIZE  # pixels per icon unit
    origin = BODY_X - margin / k
    svg = replace(ICON, VIEWBOX, f'viewBox="{origin:.4f} {origin:.4f} {size / k:.4f} {size / k:.4f}"')
    # Move the base of the delta to the nearest pixel edge.
    base_px = round(margin + (DELTA_BASE_Y - BODY_X) * k)
    base = BODY_X + (base_px - margin) / k
    svg = replace(svg, DELTA_BASE, f"824,{base:.3f} 200,{base:.3f}", count=2)
    if light_edge:
        # Twice one pixel wide, centred on the body's outline: the clip keeps the inner pixel.
        edge = (
            f'<rect x="{BODY_X}" y="{BODY_X}" width="{BODY_SIZE}" height="{BODY_SIZE}" rx="184" '
            f'fill="none" stroke="#4F46E5" stroke-opacity="0.35" stroke-width="{2 / k:.3f}"/>'
        )
        svg = replace(svg, BODY_END, f"  {edge}\n  {BODY_END}")
    return render(svg, size)


def centred(width: int, height: int, image: Image.Image, top: int | None = None,
            background: Image.Image | None = None) -> Image.Image:
    """`image` centred on a width x height canvas (or with its top at `top`)."""
    canvas = background.copy() if background else Image.new("RGBA", (width, height))
    y = (height - image.height) // 2 if top is None else top
    canvas.alpha_composite(image, ((width - image.width) // 2, y))
    return canvas


def store_background(width: int, height: int) -> Image.Image:
    """Deep indigo, lighter at the top, for the listing art."""
    return render(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">'
        '<defs><linearGradient id="b" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#312E81"/><stop offset="1" stop-color="#1E1B4B"/>'
        f'</linearGradient></defs><rect width="{width}" height="{height}" fill="url(#b)"/></svg>',
        width,
        height,
    )


def msix_assets() -> None:
    ASSETS.mkdir(exist_ok=True)
    for old in ASSETS.glob("*.png"):
        old.unlink()
    for scale in SCALES:
        f = scale // 100
        fitted(50 * f).save(ASSETS / f"StoreLogo.scale-{scale}.png")
        fitted(44 * f).save(ASSETS / f"Square44x44Logo.scale-{scale}.png")
        centred(150 * f, 150 * f, fitted(96 * f)).save(ASSETS / f"Square150x150Logo.scale-{scale}.png")
        centred(310 * f, 150 * f, fitted(96 * f)).save(ASSETS / f"Wide310x150Logo.scale-{scale}.png")
    for size in TARGET_SIZES:
        plain = fitted(size)
        plain.save(ASSETS / f"Square44x44Logo.targetsize-{size}.png")
        plain.save(ASSETS / f"Square44x44Logo.targetsize-{size}_altform-unplated.png")
        fitted(size, light_edge=True).save(ASSETS / f"Square44x44Logo.targetsize-{size}_altform-lightunplated.png")


def store_logos() -> None:
    # Key imagery stays out of the bottom third, where the Store may lay text over it.
    STORE.mkdir(exist_ok=True)
    icon(300).save(STORE / "app-tile-icon-300.png")
    centred(1080, 1080, icon(560), top=150, background=store_background(1080, 1080)).save(STORE / "box-art-1080.png")
    centred(1440, 2160, icon(800), top=460, background=store_background(1440, 2160)).save(
        STORE / "poster-art-1440x2160.png"
    )


def main() -> None:
    msix_assets()
    store_logos()


if __name__ == "__main__":
    main()
