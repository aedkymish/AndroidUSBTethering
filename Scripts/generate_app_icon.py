#!/usr/bin/env python3
"""Draws the app icon and writes App/Resources/Assets.xcassets/AppIcon.appiconset.

Requires Pillow (pip install pillow). Run from the repository root:

    python3 Scripts/generate_app_icon.py
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SCALE = 4                      # supersampling factor
SIZE = 1024 * SCALE
OUT = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset"

TOP = (52, 199, 123)           # Android green
BOTTOM = (14, 110, 134)        # deep teal
WHITE = (255, 255, 255, 255)


def s(v):
    return int(v * SCALE)


def squircle_mask():
    """macOS Big Sur grid: 824 pt body inset 100 pt, corner radius ~185 pt."""
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((s(100), s(100), s(924), s(924)), radius=s(185), fill=255)
    return mask


def gradient():
    img = Image.new("RGB", (SIZE, SIZE))
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        draw.line([(0, y), (SIZE, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def bezier(points, steps=200):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = points
    out = []
    for i in range(steps + 1):
        t = i / steps
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        out.append((a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3))
    return out


def thick_polyline(draw, pts, width):
    """Smooth round-capped stroke: stamps discs densely along the path."""
    r = width / 2
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        steps = max(1, int(math.hypot(x1 - x0, y1 - y0) / (r / 4)))
        for i in range(steps + 1):
            t = i / steps
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            draw.ellipse((x - r, y - r, x + r, y + r), fill=WHITE)


def glyph():
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Signal arcs above the phone (sharing the connection)
    cx, cy = s(352), s(318)
    for radius in (70, 118):
        r = s(radius)
        d.arc((cx - r, cy - r, cx + r, cy + r), start=228, end=312, fill=WHITE, width=s(22))

    # Phone
    d.rounded_rectangle((s(262), s(330), s(442), s(660)), radius=s(38), fill=WHITE)
    screen = (s(282), s(368), s(422), s(612))
    d.rounded_rectangle(screen, radius=s(14), fill=(255, 255, 255, 0))
    # punch the screen out so the background gradient shows through, tinted lighter
    hole = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(hole).rounded_rectangle(screen, radius=s(14), fill=150)
    layer.putalpha(ImageChops.subtract(layer.getchannel("A"), hole))
    d = ImageDraw.Draw(layer)

    # Laptop (the Mac)
    d.rounded_rectangle((s(548), s(440), s(828), s(636)), radius=s(22), outline=WHITE, width=s(24))
    d.rounded_rectangle((s(506), s(648), s(870), s(678)), radius=s(15), fill=WHITE)

    # USB cable from the phone to the laptop
    cable = bezier([(s(352), s(660)), (s(352), s(780)), (s(600), s(800)), (s(612), s(676))])
    thick_polyline(d, cable, s(22))
    # USB-C plug on the phone end
    d.rounded_rectangle((s(326), s(664), s(378), s(712)), radius=s(12), fill=WHITE)
    return layer


def render():
    body = gradient().convert("RGBA")
    # soft top highlight
    shine = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    ImageDraw.Draw(shine).ellipse((s(-200), s(-560), s(1224), s(480)), fill=(255, 255, 255, 30))
    shine = shine.filter(ImageFilter.GaussianBlur(s(60)))
    body = Image.alpha_composite(body, shine)

    g = glyph()
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 40, 40, 0))
    shadow.putalpha(g.getchannel("A").point(lambda a: int(a * 0.28)).filter(ImageFilter.GaussianBlur(s(10))))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -s(10)))
    body = Image.alpha_composite(Image.alpha_composite(body, shadow), g)

    mask = squircle_mask()
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    # drop shadow under the squircle
    drop = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    drop.putalpha(mask.point(lambda a: int(a * 0.35)).filter(ImageFilter.GaussianBlur(s(14))))
    drop = drop.transform(drop.size, Image.AFFINE, (1, 0, 0, 0, 1, -s(12)))
    icon = Image.alpha_composite(icon, drop)
    body.putalpha(mask)
    icon = Image.alpha_composite(icon, body)
    return icon.resize((1024, 1024), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    master = render()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(OUT / name, optimize=True)
            images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (OUT.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"Wrote {len(images)} icon sizes to {OUT}")


if __name__ == "__main__":
    main()
