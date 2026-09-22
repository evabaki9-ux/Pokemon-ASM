#!/usr/bin/env python3
"""tools/bmp2png.py -- turn the front-end's .bmp frame grabs into .png.

    python3 tools/bmp2png.py docs/gui
"""
import os
import sys

try:
    from PIL import Image
except ImportError:
    print("need Pillow: pip install pillow")
    sys.exit(1)


def main():
    where = sys.argv[1] if len(sys.argv) > 1 else "docs/gui"
    n = 0
    for f in sorted(os.listdir(where)):
        if not f.endswith(".bmp"):
            continue
        src = os.path.join(where, f)
        dst = src[:-4] + ".png"
        Image.open(src).convert("RGB").save(dst)
        os.remove(src)
        n += 1
        print("  %s -> %s" % (f, os.path.basename(dst)))
    print("converted %d frame(s) in %s" % (n, where))


if __name__ == "__main__":
    main()
