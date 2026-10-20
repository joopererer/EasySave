"""
Render EasySave adaptive icon assets to PNG fallbacks for pre-API-26 devices.
Usage: python generate_icon_pngs.py
Requires: PIL (pip install Pillow)
"""
from PIL import Image, ImageDraw
import math, os

# ── colour palette ──────────────────────────────────────────────────────────
C_START   = (252,  73,  76)   # #FC494C  gradient top-left (red)
C_END     = (250, 102,  46)   # #FA662E  gradient bottom-right (orange)
C_WHITE   = (255, 255, 255)
C_RED     = (240,  68,  63)   # #F0443F  arrow colour

# ── icon drawing (vector geometry) ───────────────────────────────────────────
def draw_icon(out: ImageDraw.Image, size: int) -> None:
    """
    Draw the full EasySave icon onto a pre-allocated RGBA image `out`.

    Icon anatomy (matches ic_launcher_foreground.xml / ic_launcher_background.xml):
      • Diagonal gradient background: #FC494C (top-left) → #FA662E (bottom-right)
      • White filled circle, ~61 % of size, centred near top of canvas
      • Red (#F0443F) stroked download arrow + baseline, round caps
    """
    cx = size // 2

    # ── 1. gradient background (top-left red → bottom-right orange) ───────────
    gradient = Image.new("RGBA", (size, size))
    grad_d   = ImageDraw.Draw(gradient)
    for y in range(size):
        t = y / (size - 1)           # 0 → 1 top→bottom
        r = int(C_START[0] * (1 - t) + C_END[0] * t)
        g = int(C_START[1] * (1 - t) + C_END[1] * t)
        b = int(C_START[2] * (1 - t) + C_END[2] * t)
        grad_d.rectangle([0, y, size, y + 1], fill=(r, g, b, 255))
    out.paste(gradient)

    # ── 2. white filled circle (~61 % of size, radius 33dp on 108dp canvas) ─
    circle_r = round(size * 0.61 / 2)    # radius ≈ 30.5% of size
    cy       = circle_r - 0.5             # centre shifted so top of circle ≈ y=0
    bbox     = [cx - circle_r, cy - circle_r, cx + circle_r, cy + circle_r]
    ImageDraw.Draw(out).ellipse(bbox, fill=C_WHITE + (255,))

    # ── 3. red stroked arrow + baseline (round caps, stroke ≈ 5 % of size) ───
    sw = max(round(size * 0.05), 1)      # stroke width ≈ 5% of icon size
    d  = ImageDraw.Draw(out)

    # Arrow tip: near top of circle
    tip_y    = cy - circle_r + round(size * 0.06)
    shaft_y0 = tip_y
    shaft_y1 = cy + circle_r * 0.38       # shaft ends mid-circle
    shaft_x0 = cx - sw // 2
    shaft_x1 = cx + sw // 2

    # Draw shaft
    d.rectangle([shaft_x0, shaft_y0, shaft_x1, shaft_y1], fill=C_RED + (255,))

    # Arrowhead wings (angled lines from shaft bottom meeting at tip)
    wing_out = round(circle_r * 0.52)     # how far wings spread outward
    wing_dn  = round(circle_r * 0.52)     # how far wings extend downward
    wing_h   = wing_dn                    # wing height = shaft height ratio

    # Left wing
    d.line([(shaft_x0, shaft_y1), (shaft_x0 - wing_out, shaft_y1 + wing_h)], fill=C_RED + (255,), width=sw)
    # Right wing
    d.line([(shaft_x1, shaft_y1), (shaft_x1 + wing_out, shaft_y1 + wing_h)], fill=C_RED + (255,), width=sw)
    # Shaft top segment (from tip to shaft body)
    d.line([(cx, tip_y), (cx, shaft_y0 + sw)], fill=C_RED + (255,), width=sw)

    # Baseline: centred, same width as circle diameter, below circle
    base_y  = cy + circle_r + round(size * 0.06)
    base_x0 = cx - circle_r
    base_x1 = cx + circle_r
    d.rectangle([base_x0, base_y, base_x1, base_y + sw], fill=C_RED + (255,))


# ── main ─────────────────────────────────────────────────────────────────────
TARGETS = [
    ("mdpi",     48),
    ("hdpi",     72),
    ("xhdpi",    96),
    ("xxhdpi",  144),
    ("xxxhdpi", 192),
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RES_DIR    = os.path.join(SCRIPT_DIR, "android", "app", "src", "main", "res")

for density, size in TARGETS:
    folder = os.path.join(RES_DIR, f"mipmap-{density}")
    os.makedirs(folder, exist_ok=True)

    png_path = os.path.join(folder, "ic_launcher.png")
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_icon(img, size)
    img.save(png_path, "PNG")
    print(f"  wrote {density}/ic_launcher.png  ({size}x{size})")

print("\nDone.")
