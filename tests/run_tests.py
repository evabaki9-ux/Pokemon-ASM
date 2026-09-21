#!/usr/bin/env python3
"""
tests/run_tests.py -- headless playthroughs of ./pokemon, checked frame by frame.

Every case runs the real binary with a scripted input string (see tests/play.py)
and a --dump file.  A case passes when

  * the process exits 0 and never hit the SIGSEGV reporter,
  * the dumped frames contain the expected state headers / screen text,
  * (optionally) a save file appeared or the party HP changed as expected.

usage:  python3 tests/run_tests.py [-v] [name ...]
"""
import os
import re
import subprocess
import sys
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "pokemon")
SAVE = os.path.join(ROOT, "pokemon.sav")
TMP = os.path.join(ROOT, "build", "test")
sys.path.insert(0, os.path.join(ROOT, "tests"))
import play  # noqa: E402


class Case:
    def __init__(self, name, args=(), quick=True, timeout=240,
                 want_frames=1, want=(), want_absent=(), want_save=None,
                 setup=None):
        self.name = name
        self.args = list(args)
        self.quick = quick
        self.timeout = timeout
        self.want_frames = want_frames
        self.want = list(want)              # regexes that must match the dump
        self.want_absent = list(want_absent)  # regexes that must not match
        self.want_save = want_save          # True: file must exist, False: must not
        self.setup = setup                 # callable run before the binary


def parse_frames(text):
    """['# header\\n screen...'] -> list of (header, screen)"""
    out = []
    for block in text.split("===== FRAME =====\n")[1:]:
        lines = block.split("\n")
        out.append((lines[0], "\n".join(lines[1:])))
    return out


DENSE = {"evolve"}          # cases that dump after every key


def run_case(case, verbose=False):
    if os.path.exists(SAVE):
        os.remove(SAVE)
    if case.setup:
        case.setup()
    script = (play.dense(case.name) if case.name in DENSE
              else play.scenario(case.name))
    dump = os.path.join(TMP, case.name + ".txt")
    err = os.path.join(TMP, case.name + ".err")
    args = [BIN, "--headless", "--fast", "--fixed-rng"]
    if case.quick:
        args.append("--quickstart")
    args += ["--script", script, "--dump", dump]
    args += case.args
    with open(err, "wb") as eh:
        try:
            rc = subprocess.call(args, cwd=ROOT, stdout=subprocess.DEVNULL,
                                 stderr=eh, timeout=case.timeout)
        except subprocess.TimeoutExpired:
            return False, ["timed out after %ds" % case.timeout]
    problems = []
    errtxt = open(err, "rb").read().decode("utf8", "replace")
    if "SEGV" in errtxt:
        i = errtxt.find("SEGV")
        problems.append("crashed: " + errtxt[i:i + 120].replace("\n", " "))
    if rc != 0:
        problems.append("exit code %d" % rc)
    if not os.path.exists(dump):
        problems.append("no dump written")
        return False, problems
    frames = parse_frames(open(dump, "rb").read().decode("utf8", "replace"))
    if len(frames) < case.want_frames:
        problems.append("only %d dumped frame(s), wanted %d"
                        % (len(frames), case.want_frames))
    alltxt = "\n".join(h + "\n" + s for h, s in frames)
    for pat in case.want:
        if not re.search(pat, alltxt, re.M):
            problems.append("missing /%s/" % pat)
    for pat in case.want_absent:
        if re.search(pat, alltxt, re.M):
            problems.append("unexpected /%s/" % pat)
    if case.want_save is True and not os.path.exists(SAVE):
        problems.append("no save file was written")
    if case.want_save is False and os.path.exists(SAVE):
        problems.append("a save file was written")
    if verbose and frames:
        print("    last frame: " + frames[-1][0])
    return not problems, problems


def make_save():
    """play a game and save, so the 'load' case has something to load"""
    script = (play.wait(10)
              + play.tap("s") + play.step("d", 4) + play.tap("a")
              + play.wait(play.PAGE) + play.wait(30))
    subprocess.call([BIN, "--headless", "--fast", "--quickstart",
                     "--script", script, "--dump", os.path.join(TMP, "mk.txt")],
                    cwd=ROOT, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=120)
    assert os.path.exists(SAVE), "make_save failed"


CASES = [
    # the wordmark is generated art now, so the title frame is checked for
    # the art itself (a solid block of '#' where the logo sits) rather than
    # for the words that used to be drawn as text
    Case("title", quick=False, want=[r"ASM EDITION", r"PRESS  START",
                                     r"hand-written", r"[\u2580\u2588]{8,}"]),
    Case("starter", quick=False, want_frames=1,
         want=[r"CHARMANDER", r"BULBASAUR", r"SQUIRTLE",
               r"Choose your first partner"]),
    Case("ow", want=[r"PALLET TOWN", r"CHARMANDER  Lv   5  HP  19/ 19",
                     r"^# m=0 x=19 y=10 .* s=3 n=1 hp=19/19 lv=5"]),
    Case("walk", want_frames=2,
         want=[r"^# m=0 x=19 y=5\b", r"^# m=1 x=19 y=38\b", r"ROUTE 1"]),
    Case("grass", want_frames=2,
         want=[r"^# m=1 x=12 y=\d+ .* s=3", r"^# m=1 .* s=9"]),
    Case("menu", want_frames=2, want=[r"MENU", r"POKeDEX", r"POKeMON", r"BAG",
                                      r"SAVE", r"^# m=0 x=19 y=10"]),
    Case("party", want_frames=1, want=[r"CHARMANDER", r"Z: summary"]),
    Case("bag", want_frames=1, want=[r"POTION", r"POKe BALL"]),
    Case("dex", want_frames=1, want=[r"POKeDEX", r"SEEN", r"CAUGHT"]),
    Case("save", want_frames=2, want_save=True,
         want=[r"Your progress", r"has been saved",
               r"^# m=0 x=19 y=10 .* s=3"]),
    Case("load", quick=False, want_frames=1, setup=make_save, want_save=True,
         want=[r"^# m=0 x=19 y=10 .* s=3 n=1 hp=19/19", r"PALLET TOWN"]),
    Case("battle", want_frames=1, want=[r"A wild \w+ appeared!", r"^# m=1 .* s=9"]),
    Case("win", want_frames=3,
         want=[r"^# m=1 .* s=9 n=1 hp=19/19",
               r"^# m=1 .* s=9 .*hp=18/19",     # took a hit while winning
               r"^# m=1 x=12 y=2[56] .* s=3",   # back in the overworld
               r"CHARMANDER  Lv   5  HP  18/ 19"]),
    Case("run", want_frames=3,
         want=[r"^# m=1 .* s=9", r"Got away", r"^# m=1 x=12 .* s=9"]),
    Case("catch", want_frames=2, want=[r"POKe BALL", r"^# m=1 .* s=9"]),
    Case("center", want_frames=7,
         want=[r"^# m=3 x=6 y=7 .* s=3", r"POKeMON CENTER",
               r"CHARMANDER  Lv   5  HP  19/ 19",
               r"Welcome to the", r"Shall I heal", r"We hope to see"]),
    Case("heal", want_frames=7,
         want=[r"^# m=1 .* s=3 .*hp=18/19",   # hurt in the wild battle
               r"^# m=3 x=3 y=5 .*hp=19/19",    # at the counter, healed
               r"Your POKeMON are", r"We hope to see"]),
    # evolution: a level-up that crosses the threshold in battle turns
    # CHARMANDER into CHARMELEON, with the two message beats in between
    # The dialogue types itself out a character at a time, so a dumped frame
    # can catch a line half-written: assert on the longest prefixes that are
    # reliably on screen.  The party panel is not typed, so it is exact.
    Case("evolve", want_frames=3, args=["--level", "15", "--xp", "590"],
         want=[r"CHARMANDER grew to", r"evolving!",
               r"Congratulations!", r"evolved into CHARMELEON",
               r"CHARMELEON  Lv  16"]),
    Case("rival", want_frames=5, args=["--level", "20"],
         want=[r"^# m=2 x=23 y=17 .* s=3", r"SQUIRTLE           Lv 9",
               r"^# m=2 x=23 y=17 .* s=3 .* hp=[0-9]+/"]),
    # the new ground: ROUTE 2 (the lake) and GRANITE CAVE.  Water and cave
    # floor are the encounter tables, so a wild MAGIKARP / GEODUDE is the
    # proof that the new art is on the map and reachable.
    Case("lake", want_frames=3,
         want=[r"^# m=4 x=1 y=21 .* s=3", r"ROUTE 2",
               r"^# m=4 x=27 y=14 .* s=3",        # standing on the water
               r"A wild MAGIKARP appeared!"]),
    Case("cave", want_frames=2,
         want=[r"^# m=5 x=4 y=10 .* s=3", r"GRANITE CAVE",
               r"A wild GEODUDE appeared!"]),
    # RED's HOUSE: the interior set's furniture, and MOM is in it
    Case("house", want_frames=2,
         want=[r"^# m=6 x=6 y=7 .* s=3", r"RED's HOUSE", r"MOM"]),
]


def main():
    os.makedirs(TMP, exist_ok=True)
    verbose = "-v" in sys.argv
    names = [a for a in sys.argv[1:] if not a.startswith("-")]
    cases = [c for c in CASES if not names or c.name in names]
    if not cases:
        print("no such case:", ", ".join(names))
        return 2
    print("pokemon test suite -- %d case(s)" % len(cases))
    bad = 0
    for c in cases:
        ok, problems = run_case(c, verbose)
        print("  %-8s %s%s" % (c.name, "PASS" if ok else "FAIL",
                               "" if ok else "  <- " + "; ".join(problems)))
        bad += 0 if ok else 1
        sys.stdout.flush()
    print("%d/%d passed" % (len(cases) - bad, len(cases)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
