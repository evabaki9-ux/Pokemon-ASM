#!/usr/bin/env python3
"""
tools/pathfind.py -- read the maps out of src/data.s and work out walking
routes, so the test scripts do not have to hard-code step counts.

    from pathfind import script
    script(0, (19, 10), (10, 7))   ->  "dddddd....uuu"   (script key letters)

Walkable tiles come from tools/gen_data.py's tile table:
    .  grass   ,  tall grass   L  floor   D  door   F  flower   :  path
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "src", "data.s")

WALKABLE = set(".,LDF:")

# tmap -> (map label in data.s, entity markers that sit on walkable ground)
MAP_LABELS = {}

DIRS = {"u": (0, -1), "d": (0, 1), "l": (-1, 0), "r": (1, 0)}


def load_tiles():
    """{map index: [row strings]} from the generated data.s"""
    src = open(DATA).read()
    maps = {}
    for m in re.finditer(r"^map(\d+)_tiles:\n((?:    \.ascii \"[^\"]*\"\n)+)",
                         src, re.M):
        idx = int(m.group(1))
        maps[idx] = re.findall(r'\.ascii "([^"]*)"', m.group(2))
    return maps


def grid(idx, maps=None):
    """the raw characters of one map, as a list of strings"""
    maps = maps or load_tiles()
    return maps[idx]


def walkable(ch):
    return ch in WALKABLE


def find(grid_rows, ch):
    for y, row in enumerate(grid_rows):
        x = row.find(ch)
        if x >= 0:
            return (x, y)
    return None


def path(rows, start, goal, avoid=()):
    """shortest route (list of 'u'/'d'/'l'/'r') from start to goal, or None"""
    h = len(rows)
    w = max(len(r) for r in rows)
    if start == goal:
        return []
    seen = {start: None}
    queue = [start]
    while queue:
        cur = queue.pop(0)
        for k, (dx, dy) in DIRS.items():
            nxt = (cur[0] + dx, cur[1] + dy)
            if nxt in seen:
                continue
            x, y = nxt
            if not (0 <= x < w and 0 <= y < h):
                continue
            if nxt != goal:
                if not walkable(rows[y][x]):
                    continue
                if nxt in avoid:
                    continue
            seen[nxt] = (cur, k)
            if nxt == goal:
                out = []
                node = nxt
                while seen[node]:
                    prev, k2 = seen[node]
                    out.append(k2)
                    node = prev
                return list(reversed(out))
            queue.append(nxt)
    return None


def script(idx, start, goal, gap=6):
    """walk from start to goal, as a tests/play.py input string"""
    steps = path(grid(idx), start, goal)
    if steps is None:
        raise SystemExit("no path on map %d from %s to %s" % (idx, start, goal))
    return "".join("." * gap + s for s in steps)


def steps(idx, start, goal):
    return path(grid(idx), start, goal)


def _main():
    maps = load_tiles()
    for i in sorted(maps):
        rows = maps[i]
        print("map %d: %dx%d" % (i, len(rows[0]), len(rows)))
    if len(sys.argv) >= 6:
        idx, sx, sy, gx, gy = (int(a) for a in sys.argv[1:6])
        s = steps(idx, (sx, sy), (gx, gy))
        print(len(s), "steps:" if s else "no route", "".join(s or []))


if __name__ == "__main__":
    _main()
