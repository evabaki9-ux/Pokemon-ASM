#!/usr/bin/env python3
"""
tools/ptyrender.py -- run the game in a real pty, then render the final screen
as a PNG using the ANSI palette the vt emulator recorded, plus a colour map in
text form (one letter per foreground colour) for quick reading.

usage: python3 tools/ptyrender.py OUT.png <keys...>     keys as in ptykeys.py
       python3 tools/ptyrender.py OUT.png --scenario ow --extra --quickstart
"""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import vt  # noqa: E402

from PIL import Image, ImageDraw  # noqa: E402

# ANSI colour 0..15 as xterm shows them
RGB = [(0, 0, 0), (0xAA, 0, 0), (0, 0xAA, 0), (0xAA, 0x55, 0), (0, 0, 0xAA),
       (0xAA, 0, 0xAA), (0, 0xAA, 0xAA), (0xAA, 0xAA, 0xAA), (0x55, 0x55, 0x55),
       (0xFF, 0x55, 0x55), (0x55, 0xFF, 0x55), (0xFF, 0xFF, 0x55),
       (0x55, 0x55, 0xFF), (0xFF, 0x55, 0xFF), (0x55, 0xFF, 0xFF),
       (0xFF, 0xFF, 0xFF)]
# index 0..15: black,red,green,yellow,blue,magenta,cyan,white,
#              gray,bright red,green,yellow,blue,magenta,cyan,white
LETTERS = ".rgybmcwKRGYBMCW"

KEYMAP = {"u": "w", "d": "s", "l": "a", "r": "d", "a": "z", "b": "x",
          "s": "\r", "q": "q", ".": ""}


def capture(keys, gap=0.05, extra=("--fast",), cols=80, rows=24, settle=0.6):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execv(os.path.join(ROOT, "pokemon"), ["pokemon"] + list(extra))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    time.sleep(0.4)
    out = bytearray()

    def pump(sec):
        t0 = time.time()
        while time.time() - t0 < sec:
            r, _, _ = select.select([fd], [], [], 0.02)
            if not r:
                continue
            try:
                chunk = os.read(fd, 1 << 20)
            except OSError:
                return
            if not chunk:
                return
            out.extend(chunk)

    for k in keys:
        s = KEYMAP.get(k, k)
        if s:
            os.write(fd, s.encode())
        pump(gap)
    pump(settle)
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except OSError:
        pass
    sc = vt.Screen(cols, rows)
    vt.apply_stream(sc, bytes(out))
    return sc


def render(sc, path, scale=9):
    im = Image.new("RGB", (sc.w * scale, sc.h * scale), (0, 0, 0))
    px = im.load()
    d = ImageDraw.Draw(im)
    for y in range(sc.h):
        for x in range(sc.w):
            ch = sc.ch[y][x]
            if not ch or ch == " ":
                continue
            fg, bg = sc.at[y][x]
            fg &= 0x0F
            col = RGB[fg] if fg else (200, 200, 200)
            bx, by = x * scale, y * scale
            if bg:
                d.rectangle([bx, by, bx + scale - 1, by + scale - 1],
                            fill=RGB[bg & 0x0F])
            # 5x7-ish glyph sketch: draw the character itself
            d.text((bx + 1, by + 1), ch, fill=col)
    im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
    im.save(path)
    return path


def colourmap(sc):
    out = []
    for y in range(sc.h):
        row = []
        for x in range(sc.w):
            ch = sc.ch[y][x]
            if not ch or ch == " ":
                row.append(" ")
                continue
            fg, bg = sc.at[y][x]
            row.append(LETTERS[(fg & 0x0F)])
        out.append("".join(row))
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    path = args[0]
    extra = ["--fast"]
    if "--quickstart" in args:
        extra.append("--quickstart")
    if "--scenario" in args:
        sys.path.insert(0, os.path.join(ROOT, "tests"))
        import play
        script = play.scenario(args[args.index("--scenario") + 1])
        keys = list(script)
    else:
        keys = [a for a in args[1:] if not a.startswith("--")
                and a not in ("--quickstart", "--fast")]
        # a whole key string may arrive as one shell argument: split it
        keys = [k for a in keys for k in (a if len(a) > 1 else [a])]
    sc = capture(keys, extra=extra)
    render(sc, path)
    print(colourmap(sc))
    print("\nrendered", path)


if __name__ == "__main__":
    main()
