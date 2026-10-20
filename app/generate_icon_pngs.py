"""
Render EasySave adaptive icon assets to PNG fallbacks for pre-API-26 devices.
Usage: python generate_icon_pngs.py
Requires: PIL (pip install Pillow)
"""
from PIL import Image, ImageDraw, ImageFilter
import os

# ── colour palette ──────────────────────────────────────────────────────────
C_START   = (252,  73,  76)   # #FC494C  gradient top-left
C_END     = (250, 102,  46)   # #FA662E  gradient bottom-right
C_WHITE   = (255, 255, 255)
C_RED     = (240,  68,  63)   # #F0443F  arrow colour

# ── icon drawing (vector geometry) ───────────────────────────────────────────
def draw_icon(out: ImageDraw.Image, size: int) -> None:
    """
    Draw the full EasySave icon onto a pre-allocated RGBA image `out`.

    Icon anatomy (fits inside the square canvas):
      • Gradient rounded-rect background
      • White filled circle, ~52 % of size, centred
      • Red (#F0443F) download arrow + baseline inside the circle
    """
    cx, cy = size // 2, size // 2
    circle_r = round(size * 0.52 / 2)       # ~26 % of size per radius
    stroke   = round(size * 0.05)          # stroke ≈ 5 % of size

    # ── 1. gradient background ──────────────────────────────────────────────
    gradient = Image.new("RGBA", (size, size))
    grad_d   = ImageDraw.Draw(gradient)
    for y in range(size):
        t = y / (size - 1)                  # 0 → 1 top→bottom
        # rotate gradient 135°: blend along diagonal
        s = t * 0.5 + 0.0                   # approximate 135° diagonal mix
        r = int(C_START[0] * (1 - s) + C_END[0] * s)
        g = int(C_START[1] * (1 - s) + C_END[1] * s)
        b = int(C_START[2] * (1 - s) + C_END[2] * s)
        grad_d.rectangle([0, y, size, y + 1], fill=(r, g, b, 255))
    out.paste(gradient)

    # ── 2. white filled circle ──────────────────────────────────────────────
    bbox = [cx - circle_r, cy - circle_r, cx + circle_r, cy + circle_r]
    ImageDraw.Draw(out).ellipse(bbox, fill=C_WHITE + (255,))

    # ── 3. red arrow + baseline ─────────────────────────────────────────────
    d = ImageDraw.Draw(out)
    # arrow tip at top of circle, arrow pointing down
    # arrow shaft
    shaft_h  = circle_r * 0.82
    tip_y    = cy - circle_r * 0.18        # slightly below top of circle
    shaft_y0 = tip_y
    shaft_y1 = tip_y + shaft_h
    shaft_x0 = cx - stroke // 2
    shaft_x1 = cx + stroke // 2
    d.rectangle([shaft_x0, shaft_y0, shaft_x1, shaft_y1], fill=C_RED + (255,))
    # arrowhead: two angled wings meeting at shaft bottom
    awing_w = round(circle_r * 0.38)       # half-width of each wing
    awing_h = round(circle_r * 0.35)
    # left wing: from shaft bottom-left outward to tip
    lx0, ly0 = shaft_x0, shaft_y1
    lx1, ly1 = shaft_x0 - awing_w, shaft_y1 + awing_h
    lx2, ly2 = shaft_x0, shaft_y1 + awing_h
    d.polygon([(lx0, ly0), (lx1, ly1), (lx2, ly2)], fill=C_RED + (255,))
    # right wing
    rx0, ry0 = shaft_x1, shaft_y1
    rx1, ry1 = shaft_x1 + awing_w, shaft_y1 + awing_h
    rx2, ry2 = shaft_x1, shaft_y1 + awing_h
    d.polygon([(rx0, ry0), (rx1, ry1), (rx2, ry2)], fill=C_RED + (255,))
    # baseline: horizontal line below circle
    base_y   = cy + circle_r + round(size * 0.05)
    base_y1  = base_y + stroke
    base_x0  = cx - circle_r
    base_x1  = cx + circle_r
    d.rectangle([base_x0, base_y, base_x1, base_y1], fill=C_RED + (255,))


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
