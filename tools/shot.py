#!/usr/bin/env python3
"""
shot.py -- render a --dump file produced by the game's headless mode into
readable screenshots (the game writes raw UTF-8 framebuffer cells).

usage:  python3 tools/shot.py dump.txt           # list frames
        python3 tools/shot.py dump.txt 3         # show frame 3
        python3 tools/shot.py dump.txt 3 --colour
"""
import sys

W, H = 80, 24

def parse_frames(path):
    frames = []
    cur = None
    for line in open(path, "rb").read().split(b"\n"):
        if line.strip() == b"===== FRAME =====":
            if cur is not None:
                frames.append(cur)
            cur = []
            continue
        if cur is None:
            continue
        cur.append(line)
    if cur:
        frames.append(cur)
    return frames

def cells(row):
    """split one dumped row back into 80 glyph cells"""
    out = []
    i = 0
    n = len(row)
    while i < n and len(out) < W:
        b = row[i]
        if b < 0x80:
            take = 1
        elif b < 0xC0:
            take = 1
        elif b < 0xE0:
            take = 2
        else:
            take = 3
        out.append(row[i:i+take])
        i += take
    while len(out) < W:
        out.append(b" ")
    return out

def show(frame, colour=False):
    for r in range(H):
        row = frame[r] if r < len(frame) else b""
        text = b"".join(cells(row)).decode("utf-8", "replace")
        print(f"{r:2d} |{text}|")

def main():
    path = sys.argv[1]
    frames = parse_frames(path)
    if len(sys.argv) == 2:
        print(f"{len(frames)} frame(s) in {path}")
        return
    idx = int(sys.argv[2])
    print(f"--- frame {idx} of {len(frames)-1} ---")
    show(frames[idx])

if __name__ == "__main__":
    main()
