#!/usr/bin/env python3
"""
tools/gui_tour.py -- stack the window front-end's screenshots into one image
with captions, for the README and docs/GUI.md.

    python3 tools/gui_tour.py [out.png]

Reads docs/gui/{title,route1,battle}.png, which `make gui-shots` writes.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "docs", "gui")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SHOTS, "tour.png")

FRAMES = [
    ("title.png", "THE TITLE SCREEN - the generated picture, not a terminal"),
    ("route1.png", "ROUTE 1 - 32x32 tiles, and people are sprites now"),
    ("battle.png", "A WILD BATTLE - backdrop picture, creature art, the game's "
                   "own boxes"),
]

FONT_FILES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]

BAR = 34
FOOT = 46


def font(size):
    for path in FONT_FILES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def main():
    ims = []
    for name, caption in FRAMES:
        path = os.path.join(SHOTS, name)
        if not os.path.exists(path):
            print("gui_tour: missing %s -- run: make gui-shots" % path)
            return 1
        ims.append((Image.open(path).convert("RGB"), caption))

    w = ims[0][0].width
    h = sum(im.height + BAR for im, _ in ims) + FOOT
    out = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(out)
    cap_font = font(19)
    foot_font = font(20)

    y = 0
    for im, caption in ims:
        d.rectangle([0, y, w, y + BAR - 1], fill=(16, 16, 48))
        d.text((8, y + 6), caption, font=cap_font, fill=(255, 255, 140))
        y += BAR
        out.paste(im, (0, y))
        y += im.height

    d.rectangle([0, y, w, y + FOOT - 1], fill=(16, 16, 48))
    d.text((8, y + 12),
           "one window, no terminal: ./pokemon-gui   --   the game itself is "
           "x86-64 assembly, raw syscalls, no libc",
           font=foot_font, fill=(200, 230, 255))
    out.save(OUT)
    print("wrote %s (%dx%d)" % (os.path.relpath(OUT, ROOT), out.width, out.height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
