#!/usr/bin/env python3
"""Decode a --dump file into an 80x24 glyph grid.

Usage: python3 tools/dumpframe.py dump.txt [frame]
Prints one row per terminal row, one column per terminal CELL (wide glyphs
that occupy 2 columns are shown as a single character plus '.' continuation).
"""
import sys

NAMES = {
    "\u00b7": "·", "\u2591": "▒", "\u2592": "▓", "\u2593": "▓", "\u2588": "█",
    "\u2584": "▄", "\u2580": "▀", "\u258c": "▌", "\u2590": "▐", "\u25c9": "◉",
    "\u25d8": "◘", "\u2248": "≈", "\u273f": "✿", "\u2500": "-", "\u2502": "|",
    "\u250c": "+", "\u2510": "+", "\u2514": "+", "\u2518": "+", "\u2192": ">",
    "\u25ba": ">", "\u25c4": "<", "\u25b2": "^", "\u25bc": "v", "\u25cf": "*",
}
WIDE = set("\u2593\u2592\u2591\u2588\u2584\u2580\u258c\u2590")


def cells(raw):
    out, i = [], 0
    while i < len(raw):
        b = raw[i]
        n = 1 if b < 0x80 else (2 if b < 0xE0 else 3 if b < 0xF0 else 4)
        out.append(raw[i:i + n].decode("utf8", "replace"))
        i += n
    return out


def show(frames, want):
    body = frames[want + 1]
    rows = body.split(b"\n")
    print("--- frame %d ---" % want)
    for r, raw in enumerate(rows[:24]):
        cs = cells(raw)
        line = []
        for c in cs[:80]:
            line.append(NAMES.get(c, c if c.isprintable() else "?"))
        print("%2d|%s" % (r, "".join(line)))


def main():
    """usage: dumpframe.py FILE [frame|all]   (default: all frames)"""
    path = sys.argv[1]
    frames = open(path, "rb").read().split(b"===== FRAME =====\n")
    nf = len(frames) - 1
    if nf == 0:
        sys.exit("no frames in " + path)
    arg = sys.argv[2] if len(sys.argv) > 2 else "all"
    if arg == "all":
        want = range(nf)
    else:
        want = [int(arg)]
    want = list(want)
    for i, w in enumerate(want):
        if w >= nf:
            sys.exit("dump has %d frame(s); asked for %d" % (nf, w))
        show(frames, w)
        if i != len(want) - 1:
            print()


if __name__ == "__main__":
    main()
