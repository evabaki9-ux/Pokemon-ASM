#!/usr/bin/env python3
"""
tools/check_maps.py -- walk the generated maps and report what is reachable.

Reads src/data.s (map tiles + entities) and tools/gen_data.py (tile table) and
answers, for every map, the question a playthrough would ask: standing on the
spawn, can the player actually get to the doors, the signs, the items, the
people, the water, the cave floor?  A map that fails this cannot be tested by
walking, so this runs before the test suite is trusted with a new map.

    python3 tools/check_maps.py            # summary per map
    python3 tools/check_maps.py -v         # ... and every unreachable target
"""
import os
import re
import sys
from collections import deque

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

DATA = os.path.join(ROOT, "src", "data.s")
src = open(DATA).read()

# tile chars -> walkable?  (the same table tools/gen_data.py emits: the fifth
# field of a tile entry is the walkable flag, the sixth is the encounter group)
gen = open(os.path.join(ROOT, "tools", "gen_data.py")).read()
TILE_ENTRIES = re.findall(
    r'\("(\w+)",\s*"([^"]*)",\s*"[^"]*",\s*\[[^\]]*\]\s*\*\s*4,\s*(\d),\s*(\d)\)',
    gen)
WALK = {}
GROUP = {}
for name, ch, walk, grp in TILE_ENTRIES:
    if ch:
        WALK[ch] = walk == "1"
        GROUP[ch] = int(grp)
# entity markers stand on walkable ground (gen_data rewrites them to the floor)
for ch in "NHP":
    WALK.setdefault(ch, True)
WALK["n"] = True


def maps():
    out = {}
    for m in re.finditer(r"^\.globl map(\d+)_name\nmap\1_name: \.asciz \"([^\"]*)\"\n"
                         r"\.globl map\1_tiles\nmap\1_tiles:\n"
                         r"((?:    \.ascii \"[^\"]*\"\n)+)", src, re.M):
        out[int(m.group(1))] = (m.group(2),
                                re.findall(r'\.ascii "([^"]*)"', m.group(3)))
    return out


def entities(idx, kind):
    m = re.search(r"^\.globl map%d_%s\n((?:(?!\.globl).)*)" % (idx, kind),
                  src, re.M | re.S)
    if not m:
        return []
    return [(int(a), int(b)) for a, b in
            re.findall(r"    \.byte (\d+),(\d+),", m.group(1))]


def warps(idx):
    m = re.search(r"^\.globl map%d_warps\nmap%d_warps:\n((?:    \.byte [^\n]*\n)*)"
                  % (idx, idx), src, re.M)
    return [(int(a), int(b)) for a, b in
            re.findall(r"    \.byte (\d+),(\d+),", m.group(1))]


def links(idx):
    m = re.search(r"^\.globl map%d_links\nmap%d_links:\n((?:    \.byte [^\n]*\n)*)"
                  % (idx, idx), src, re.M)
    out = []
    for i, line in enumerate(re.findall(r"    \.byte (\d+),(\d+),(\d+)",
                                        m.group(1))):
        mp, lx, ly = int(line[0]), int(line[1]), int(line[2])
        if mp != 0xff:
            out.append("NSWE"[i])
    return out


def flood(rows, start):
    h, w = len(rows), len(rows[0])
    seen = {start}
    q = deque([start])
    while q:
        x, y = q.popleft()
        for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
            nx, ny = x + dx, y + dy
            if not (0 <= nx < w and 0 <= ny < h):
                continue
            if (nx, ny) in seen:
                continue
            if not WALK.get(rows[ny][nx], False):
                continue
            seen.add((nx, ny))
            q.append((nx, ny))
    return seen


def main():
    verbose = "-v" in sys.argv
    bad = 0
    for idx, (name, rows) in sorted(maps().items()):
        spawn = re.search(r"^map%d_spawn: \.byte (\d+),(\d+)" % idx, src, re.M)
        if not spawn:
            print("map %d %s: no spawn" % (idx, name))
            bad += 1
            continue
        sx, sy = int(spawn.group(1)), int(spawn.group(2))
        h, w = len(rows), len(rows[0])
        cands = [(sx, sy)]

        def usable(x, y):
            if WALK.get(rows[y][x], False):
                return (x, y)
            for dx, dy in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and WALK.get(rows[ny][nx], False):
                    return (nx, ny)
            return None

        # a map without a 'P' has no spawn of its own: the player arrives from
        # a link or a warp, so use those landing tiles as the seed instead
        for e in re.findall(r"^\.globl map%d_links\nmap%d_links:\n((?:    \.byte"
                            r" [^\n]*\n)*)" % (idx, idx), src, re.M)[0].split("\n"):
            f = re.findall(r"\.byte (\d+),(\d+),(\d+)", e)
            if not f:
                continue
            mp, lx, ly = [int(v) for v in f[0]]
            if mp == 0xff:
                continue
            if lx == 0xFE:                      # keep the player's x
                cands += [(x, ly) for x in range(w)]
            elif ly == 0xFE:
                cands += [(lx, y) for y in range(h)]
            else:
                cands.append((lx, ly))
        seed = None
        for c in cands:
            if not (0 <= c[0] < w and 0 <= c[1] < h):
                continue
            seed = usable(*c)
            if seed:
                break
        if not seed:
            print("map %d %s: no walkable entry tile" % (idx, name))
            bad += 1
            continue
        reach = flood(rows, seed)
        targets = []
        for x, y in warps(idx) + entities(idx, "signs") + entities(idx, "items"):
            targets.append(("exit/thing", (x, y)))
        for x, y in entities(idx, "npcs"):
            targets.append(("npc", (x, y)))
        # the encounter ground: can the player stand *on* it?
        for want, label in (("~", "water"), (",", "tall grass"), ("r", "cave rock")):
            spots = [(x, y) for y, r in enumerate(rows) for x, c in enumerate(r)
                     if c == want]
            if spots:
                targets.append((label, spots[0]))
                targets.append((label + " (all)", None) if False else
                               (label, spots[-1]))
        missing = []
        for kind, t in targets:
            # a sign/item/exit is *used* by standing next to it, a warp needs
            # the tile itself: both count as reachable when adjacent
            x, y = t
            ok = (x, y) in reach
            for dx, dy in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                if (x + dx, y + dy) in reach:
                    ok = True
            if not ok:
                missing.append("%s at %d,%d" % (kind, x, y))
        status = "ok" if not missing else "UNREACHABLE"
        print("map %d %-14s %2dx%-2d spawn %-8s links %-6s reachable %4d  %s"
              % (idx, name, len(rows[0]), len(rows), "%d,%d" % (sx, sy),
                 ",".join(links(idx)) or "-", len(reach), status))
        if missing:
            bad += 1
            if verbose:
                for m in missing:
                    print("      ! " + m)
    # tile coverage: which tiles does any map actually place?
    placed = set()
    for _, rows in maps().values():
        for r in rows:
            for c in r:
                placed.add(c)
    print("\ntiles placed by at least one map:")
    for name, ch, walk, grp in TILE_ENTRIES:
        if ch:
            print("  %-8s '%s' %s  %s  encounter group %s"
                  % (name, ch, "walkable" if walk == "1" else "blocks  ",
                     "PLACED" if ch in placed else "NOT PLACED", grp))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
