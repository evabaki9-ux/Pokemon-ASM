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

# terrain the player can stand on: sand and shallow water are walkable
# (you surf out onto the lake), rock is the cave floor, rug is indoors
WALKABLE = set(".,LDF:~srg")

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


def load_npcs():
    """{map index: {(x, y)}} -- people stand in the way, so the walk has to
    know about them: an NPC on the road is a wall, not a step"""
    src = open(DATA).read()
    out = {}
    for m in re.finditer(r"^\.globl map(\d+)_npcs\n((?:(?!\.globl).)*)",
                         src, re.M | re.S):
        out[int(m.group(1))] = set(
            (int(a), int(b)) for a, b in
            re.findall(r"    \.byte (\d+),(\d+),", m.group(2)))
    return out


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


# Ground that can throw a wild POKeMON at you.  A route that crosses it is
# still legal, but it costs more, so the walk prefers the road: a scripted
# playthrough must not be ambushed halfway to where it is going.
WILD = set(",~r")
WILD_COST = 12


def path(rows, start, goal, avoid=()):
    """Cheapest route (list of 'u'/'d'/'l'/'r') from start to goal, or None.

    Dijkstra rather than BFS: encounter ground is walkable but expensive."""
    import heapq
    h = len(rows)
    w = max(len(r) for r in rows)
    if start == goal:
        return []
    best = {start: 0}
    prev = {}
    heap = [(0, start)]
    while heap:
        cost, cur = heapq.heappop(heap)
        if cur == goal:
            out = []
            node = cur
            while node in prev:
                node, k = prev[node]
                out.append(k)
            return list(reversed(out))
        if cost > best.get(cur, 1 << 30):
            continue
        for k, (dx, dy) in DIRS.items():
            x, y = cur[0] + dx, cur[1] + dy
            nxt = (x, y)
            if not (0 <= x < w and 0 <= y < h):
                continue
            if nxt != goal:
                if not walkable(rows[y][x]):
                    continue
                if nxt in avoid:
                    continue
            step = WILD_COST if rows[y][x] in WILD else 1
            ncost = cost + step
            if ncost < best.get(nxt, 1 << 30):
                best[nxt] = ncost
                prev[nxt] = (cur, k)
                heapq.heappush(heap, (ncost, nxt))
    return None


def script(idx, start, goal, gap=6):
    """walk from start to goal, as a tests/play.py input string"""
    npcs = load_npcs().get(idx, set())
    steps = path(grid(idx), start, goal, avoid=npcs - {goal})
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
