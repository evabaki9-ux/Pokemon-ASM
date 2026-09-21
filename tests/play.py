#!/usr/bin/env python3
"""
tests/play.py -- build headless/pty input scripts for scripted playthroughs.

The binary consumes exactly one character per frame:
    u d l r   walk            a  A button (Z)      b  B button (X)
    s         START (M)       .  do nothing        D  dump screen to --dump
    q         quit

Usage:  python3 tests/play.py <scenario>
Scenarios: title starter ow walk grass menu battle save load
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "tools"))
try:
    import pathfind
except ImportError:                      # tests still work without it
    pathfind = None

PAGE = 200          # frames to let one text page finish typing
TAP = 6             # frames between taps


def wait(n=1):
    return "." * n


def tap(k):
    return wait(TAP) + k


def page():
    """advance one dialogue page"""
    return wait(PAGE) + "a"


def pages(n):
    return page() * n


def dump():
    return wait(8) + "D"


def step(d, n=1):
    return "".join(wait(TAP) + d for _ in range(n))


def press(k, n=1, gap=30):
    return "".join(wait(gap) + k for _ in range(n))


def title_to_starter():
    """title -> new game -> Oak's speech -> the starter table"""
    s = wait(40) + "s"        # title: press START
    s += pages(3)             # NEW GAME / no saved data / begin? answer YES
    s += pages(8)             # Oak's introduction (8 pages)
    return s


def starter_to_world():
    """the starter screen: pick CHARMANDER, confirm, read the message"""
    s = tap("a")              # Z: choose the highlighted starter
    s += pages(3)             # "This is CHARMANDER..." / "A FIRE type. Take it?" / YES
    s += pages(1)             # "your partner is with you"
    s += pages(4)             # PROF. OAK's ready message (4 pages)
    return s


QUICK = ("ow", "walk", "grass", "menu", "battle", "save", "win", "run",
         "catch", "center", "heal", "party", "bag", "dex", "rival", "evolve")


def new_game(name):
    """scenarios that do not test the intro start with --quickstart"""
    if name in QUICK:
        return wait(10)          # the world is already up
    return title_to_starter() + starter_to_world()


def walk_to_grass():
    """PALLET town centre -> north gate -> ROUTE 1 -> west into the tall grass"""
    return step("u", 22) + step("l", 7)


def wander(n=40):
    """pace up and down inside the grass until something jumps out"""
    return "".join(step("u", 1) + step("d", 1) for _ in range(n))


def battle_intro():
    return walk_to_grass() + wander() + wait(120)


def intro_done():
    """dismiss the "A wild X appeared!" / "Go! ..." pages: the FIGHT menu is up"""
    return press("a", 2, 90) + wait(60)


def mash(n=16, gap=70):
    """spam A through FIGHT / move / message pages until the fight is over"""
    return press("a", n, gap)


def walk_to_center(start=(19, 10)):
    """PALLET: start -> the door tile of the house at (10,7) -> POKeMON CENTER"""
    if pathfind:
        return pathfind.script(0, start, (10, 7))
    return step("d", 12) + step("u", 10) + step("u", 4) + step("l", 9) + step("u", 1)


def walk_to_rival():
    """VIRIDIAN arrival tile (19,30) -> the tile west of the RIVAL at (24,17)"""
    if pathfind:
        s = pathfind.script(2, (19, 30), (22, 17))
    else:
        s = step("u", 13) + step("r", 3)
    return s + step("r", 1) + tap("a")


def leave_grass(from_tile=(12, 26)):
    """from the grass patch on ROUTE 1 back into PALLET town (19,2)"""
    if pathfind:
        return pathfind.script(1, from_tile, (19, 39))
    return step("r", 7) + step("d", 20)


def talk_to_nurse():
    """from the CENTER arrival tile (5,7): left, up to (3,5), talk north"""
    return step("l", 2) + step("u", 2) + tap("a")


def dense(name):
    """the scenario with a dump after every key: nothing can scroll past
    unobserved, which is what a test of a message sequence needs"""
    return "".join(c + ("D" if c in "a." else "") for c in scenario(name))


def scenario(name):
    s = ""
    if name == "title":
        s += wait(40) + dump()
    elif name == "starter":
        s += title_to_starter() + dump()
    elif name == "ow":
        s += new_game(name) + wait(30) + dump()
    elif name == "walk":
        s += new_game(name)
        s += step("u", 5) + dump()
        s += step("u", 5) + dump()
    elif name == "grass":
        s += new_game(name)
        s += walk_to_grass() + dump()
        s += wander(14) + wait(90) + dump()
    elif name == "menu":
        s += new_game(name)
        s += tap("s") + dump()          # START -> pause menu
        s += tap("b") + dump()          # X -> back to the world
    elif name == "party":
        s += new_game(name)
        s += tap("s") + tap("d") + tap("a") + dump()   # POKeMON -> party
        s += tap("a") + dump()                          # Z -> summary
        s += tap("b") + tap("b") + dump()
    elif name == "bag":
        s += new_game(name)
        s += tap("s") + step("d", 2) + tap("a") + dump()   # BAG
        s += tap("b") + dump()
    elif name == "dex":
        s += new_game(name)
        s += tap("s") + tap("a") + dump()                  # POKeDEX
        s += tap("b") + dump()
    elif name == "save":
        s += new_game(name)
        s += tap("s") + step("d", 4) + tap("a")     # START, SAVE, confirm
        s += wait(PAGE) + dump()                    # "Your progress has been saved!"
        s += tap("b") + tap("b") + dump()            # X: back to the world
    elif name == "load":
        s += wait(10) + "s" + pages(3)      # title: START -> "continue?" -> YES
        s += wait(240) + dump()
    elif name == "battle":
        s += new_game(name) + battle_intro() + wait(60) + dump()
    elif name == "win":
        s += new_game(name) + battle_intro() + intro_done() + dump()
        s += mash(10, 70) + wait(30) + dump()    # fight until "You won!"
        s += mash(20, 60) + wait(90) + dump()    # dismiss it, back to the world
    elif name == "evolve":
        # level the starter to 15 and leave it a hair short of 16, so winning
        # this battle is what tips it over and triggers the evolution
        s += new_game(name) + battle_intro() + intro_done() + dump()
        s += mash(10, 70) + wait(30) + dump()
        s += mash(20, 60) + wait(90) + dump()
    elif name == "run":
        s += new_game(name) + battle_intro() + intro_done() + dump()
        s += tap("b") + wait(150) + dump()       # X = RUN
        s += wait(120) + dump()
    elif name == "catch":
        s += new_game(name) + battle_intro() + intro_done() + dump()
        s += tap("r") + tap("a") + wait(60)      # right -> BAG, open it
        s += tap("d") + tap("a") + wait(200)     # down -> POKe BALL, throw it
        s += dump()
    elif name == "rival":
        s += new_game(name)
        # PALLET -> ROUTE 1 -> VIRIDIAN CITY, then talk to the rival
        s += step("u", 10) + step("u", 38)
        s += walk_to_rival()
        s += wait(80) + dump()                   # "RIVAL wants to fight!"
        s += intro_done() + wait(60) + dump()    # his first POKeMON is out
        s += mash(24, 80) + wait(60) + dump()    # fight it out
        s += mash(24, 80) + wait(90) + dump()    # ... and his second one
    elif name == "center":
        s += new_game(name)
        s += walk_to_center() + wait(40) + dump()   # inside the CENTER
        s += talk_to_nurse() + pages(3) + dump()    # NURSE heals the party
    elif name == "heal":
        s += new_game(name) + battle_intro() + intro_done()
        s += mash(10, 70) + wait(30)             # win the fight, take damage
        s += mash(20, 60) + wait(60) + dump()
        s += leave_grass()                       # back into PALLET at (19,2)
        s += walk_to_center((19, 2)) + wait(40)
        s += talk_to_nurse() + pages(3) + wait(60) + dump()
    else:
        raise SystemExit("unknown scenario " + name)
    s += wait(30) + "q"
    return s


if __name__ == "__main__":
    sys.stdout.write(scenario(sys.argv[1] if len(sys.argv) > 1 else "ow"))
