#!/usr/bin/env python3
"""
tools/tour.py -- render docs/TOUR.md: real frames from a real playthrough.

Every screen in the tour is produced by running ./pokemon headlessly with a
scripted input and pulling the dumped framebuffer out of the dump file, so
the document cannot drift away from what the game actually draws.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import play          # noqa: E402
import dumpframe     # noqa: E402

BIN = os.path.join(ROOT, "pokemon")
TMP = os.path.join(ROOT, "build", "tour")


def frames(path, every=False):
    """[(header, [rows])] from a dump file"""
    raw = open(path, "rb").read().split(b"===== FRAME =====\n")[1:]
    out = []
    for body in raw:
        rows = body.split(b"\n")
        header = rows[0].decode("latin1", "replace")
        grid = []
        for r in rows[1:25]:
            cs = dumpframe.cells(r)
            grid.append("".join(dumpframe.NAMES.get(c, c if c.isprintable() else "?")
                                for c in cs[:80]))
        out.append((header, grid))
    return out


def run(name, script, quick=True, level=None, keep=None, frames_wanted=None):
    os.makedirs(TMP, exist_ok=True)
    dump = os.path.join(TMP, name + ".txt")
    args = [BIN, "--headless", "--fast", "--fixed-rng"]
    if quick:
        args.append("--quickstart")
        args += ["--level", str(level)] if level else []
    elif level:
        args += ["--level", str(level)]
    args += ["--script", script, "--dump", dump]
    subprocess.call(args, cwd=ROOT, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=600)
    fs = frames(dump)
    if not fs:
        raise SystemExit("no frames dumped for " + name)
    return fs


def block(title, header, grid, note=""):
    out = ["### %s\n" % title]
    if note:
        out.append(note + "\n")
    out.append("```")
    out.append("state: " + header.lstrip("# ").strip())
    out.append("+" + "-" * 80 + "+")
    for r in grid:
        out.append("|" + r + "|")
    out.append("+" + "-" * 80 + "+")
    out.append("```\n")
    return "\n".join(out)


def main():
    parts = []
    save = os.path.join(ROOT, "pokemon.sav")
    if os.path.exists(save):
        os.remove(save)

    # -- title with no save file ------------------------------------------
    fs = run("title", play.wait(40) + play.dump() + "q", quick=False)
    parts.append(block("Title screen", fs[0][0], fs[0][1]))

    # -- new game: Oak's speech and the starter table ----------------------
    fs = run("starter", play.title_to_starter() + play.dump() + "q", quick=False)
    parts.append(block("Choose your first partner", fs[-1][0], fs[-1][1],
                       "Oak hands you a choice of three. The rival takes the "
                       "one that beats yours."))
    fs = run("starter2", play.title_to_starter() + play.starter_to_world()
             + play.wait(40) + play.dump() + "q", quick=False)
    parts.append(block("The journey starts", fs[-1][0], fs[-1][1]))

    # -- overworld ---------------------------------------------------------
    fs = run("ow", play.wait(10) + play.dump() + "q")
    parts.append(block("Overworld", fs[-1][0], fs[-1][1],
                       "40x8 tiles of the map, drawn as 2x2 character cells. "
                       "The panel under it is the lead POKeMON, the bag and "
                       "the party."))

    # -- menus -------------------------------------------------------------
    fs = run("menu", play.wait(10) + play.tap("s") + play.wait(6) + play.dump() + "q")
    parts.append(block("Pause menu", fs[-1][0], fs[-1][1]))
    fs = run("party", play.wait(10) + play.tap("s") + play.tap("d") + play.tap("a")
             + play.wait(8) + play.tap("a") + play.wait(8) + play.dump() + "q")
    parts.append(block("Party / summary", fs[-1][0], fs[-1][1]))
    fs = run("bag", play.wait(10) + play.tap("s") + play.step("d", 2) + play.tap("a")
             + play.wait(8) + play.dump() + "q")
    parts.append(block("Bag", fs[-1][0], fs[-1][1]))
    fs = run("dex", play.wait(10) + play.tap("s") + play.tap("a") + play.wait(8)
             + play.dump() + "q")
    parts.append(block("POKeDEX", fs[-1][0], fs[-1][1]))

    # -- tall grass and a wild battle --------------------------------------
    fs = run("grass", play.wait(10) + play.walk_to_grass() + play.wait(30)
             + play.dump() + "q")
    parts.append(block("Tall grass on ROUTE 1", fs[-1][0], fs[-1][1],
                       "Every step in the grass rolls the encounter table."))
    fs = run("battle", play.wait(10) + play.walk_to_grass() + play.wander(30)
             + play.wait(120) + play.dump() + play.intro_done() + play.wait(20)
             + play.dump() + "q", level=12)
    parts.append(block("A wild POKeMON!", fs[0][0], fs[0][1]))
    parts.append(block("Battle menu", fs[-1][0], fs[-1][1]))
    fs = run("win", play.wait(10) + play.walk_to_grass() + play.wander(30)
             + play.wait(120) + play.intro_done() + play.mash(6, 70)
             + play.wait(20) + play.dump() + "q", level=12)
    parts.append(block("... and it fainted", fs[-1][0], fs[-1][1]))

    # -- the POKeMON CENTER -------------------------------------------------
    fs = run("center", play.wait(10) + play.walk_to_center() + play.wait(40)
             + play.dump() + "q")
    parts.append(block("POKeMON CENTER", fs[-1][0], fs[-1][1],
                       "The nurse heals the whole party."))

    # -- save ---------------------------------------------------------------
    fs = run("save", play.wait(10) + play.tap("s") + play.step("d", 4)
             + play.tap("a") + play.wait(play.PAGE) + play.dump() + "q")
    parts.append(block("Saving", fs[-1][0], fs[-1][1]))

    out = ["# A tour of POKeMON FIRE RED - ASM EDITION\n",
           "Every screen below is a real dumped framebuffer from",
           "`./pokemon --headless ...`, captured by `tools/tour.py`.",
           "Regenerate with `python3 tools/tour.py`.\n"]
    open(os.path.join(ROOT, "docs", "TOUR.md") if os.path.isdir(
        os.path.join(ROOT, "docs")) else "/tmp/tour.md", "w")
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    with open(os.path.join(ROOT, "docs", "TOUR.md"), "w") as fh:
        fh.write("\n".join(out) + "\n" + "\n".join(parts))
    print("wrote docs/TOUR.md (%d screens)"
          % sum(1 for p in parts))


if __name__ == "__main__":
    main()
