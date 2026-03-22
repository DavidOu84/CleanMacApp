#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
ICON_DIR = DIST / "icon"
MASTER_PNG = ICON_DIR / "AppIcon-1024.png"
ICONSET = ICON_DIR / "AppIcon.iconset"
ICNS = ICON_DIR / "AppIcon.icns"


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def gradient_bg(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()

    c1 = (32, 86, 246)
    c2 = (0, 174, 239)
    c3 = (15, 224, 188)
    cx, cy = size * 0.3, size * 0.25
    maxd = math.hypot(size, size)

    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / maxd
            t = min(1.0, max(0.0, d * 1.7))
            if t < 0.55:
                tt = t / 0.55
                r = int(lerp(c1[0], c2[0], tt))
                g = int(lerp(c1[1], c2[1], tt))
                b = int(lerp(c1[2], c2[2], tt))
            else:
                tt = (t - 0.55) / 0.45
                r = int(lerp(c2[0], c3[0], tt))
                g = int(lerp(c2[1], c3[1], tt))
                b = int(lerp(c2[2], c3[2], tt))
            px[x, y] = (r, g, b, 255)

    return img


def build_master_icon() -> Image.Image:
    size = 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Shadow
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((70, 86, 954, 970), radius=220, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    canvas.alpha_composite(shadow)

    # Rounded square background
    bg = gradient_bg(size)
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((62, 62, 962, 962), radius=210, fill=255)
    canvas.paste(bg, (0, 0), mask)

    # Stylized C
    c_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cd = ImageDraw.Draw(c_layer)
    cd.ellipse((240, 240, 784, 784), fill=(255, 255, 255, 240))
    cd.ellipse((334, 334, 690, 690), fill=(0, 0, 0, 0))
    cd.rectangle((586, 290, 850, 734), fill=(0, 0, 0, 0))

    # Accent slash for "clean" motion
    cd.rounded_rectangle((540, 520, 835, 610), radius=42, fill=(255, 255, 255, 232))
    cd.rounded_rectangle((614, 546, 900, 636), radius=42, fill=(0, 0, 0, 0))

    canvas.alpha_composite(c_layer)

    # Sparkle accent
    sp = ImageDraw.Draw(canvas)
    star = [(760, 190), (784, 250), (844, 274), (784, 298), (760, 358), (736, 298), (676, 274), (736, 250)]
    sp.polygon(star, fill=(255, 214, 74, 250))

    return canvas


def write_iconset(master: Image.Image) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True, exist_ok=True)

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for name, size in sizes:
        icon = master.resize((size, size), Image.Resampling.LANCZOS)
        icon.save(ICONSET / name, "PNG")


def make_icns() -> None:
    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
        check=True,
    )


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    icon = build_master_icon()
    icon.save(MASTER_PNG, "PNG")
    write_iconset(icon)
    make_icns()
    print(f"Generated icon: {ICNS}")


if __name__ == "__main__":
    main()
