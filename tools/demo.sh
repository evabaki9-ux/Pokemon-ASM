#!/bin/sh
# ============================================================================
#  tools/demo.sh -- show the game off.
#
#    ./tools/demo.sh            play it (needs a terminal, q quits)
#    ./tools/demo.sh --auto     a scripted playthrough, printed as screens
#    ./tools/demo.sh --battle   jump straight into a wild battle
# ============================================================================
set -e
cd "$(dirname "$0")/.."

BIN=./pokemon
SAVE=pokemon.sav
DEMO=build/demo

if [ ! -x "$BIN" ]; then
    echo "building..."
    make -s
fi

case "$1" in
--auto)
    # level 12 so the fight is over quickly; the scoring frames are the point
    rm -f "$SAVE"; mkdir -p "$DEMO"
    echo "== a scripted playthrough: title -> starter -> grass -> battle -> win =="
    python3 - "$DEMO" <<'PY'
import os, subprocess, sys
sys.path.insert(0, "tests")
sys.path.insert(0, "tools")
import play
out = sys.argv[1]
script = (play.title_to_starter() + play.starter_to_world() + play.wait(40)
          + play.dump()                                   # the overworld
          + play.step("u", 22) + play.step("l", 7) + play.dump()   # tall grass
          + play.wander(30) + play.wait(120) + play.dump()         # a wild one
          + play.intro_done() + play.mash(30, 70) + play.wait(60)
          + play.dump()                                   # after the fight
          + "q")
open(os.path.join(out, "demo.script"), "w").write(script)
PY
    "$BIN" --headless --fast --fixed-rng --level 12 \
        --script "$DEMO/demo.script" --dump "$DEMO/demo.txt" 2>/dev/null || true
    python3 tools/dumpframe.py "$DEMO/demo.txt"
    echo
    echo "(frames are also in $DEMO/demo.txt -- view any frame with"
    echo " python3 tools/dumpframe.py $DEMO/demo.txt N)"
    ;;
--battle)
    # straight to the tall grass with a starter already in hand
    rm -f "$SAVE"; mkdir -p "$DEMO"
    python3 - "$DEMO" <<'PY'
import os, sys
sys.path.insert(0, "tests")
import play
script = (play.wait(10) + play.step("u", 22) + play.step("l", 7)
          + play.wander(30) + play.wait(120) + play.dump()
          + play.intro_done() + play.dump() + "q")
open(os.path.join(sys.argv[1], "battle.script"), "w").write(script)
PY
    "$BIN" --headless --fast --fixed-rng --quickstart --level 12 \
        --script "$DEMO/battle.script" --dump "$DEMO/battle.txt" 2>/dev/null || true
    python3 tools/dumpframe.py "$DEMO/battle.txt"
    ;;
*)
    echo "POKeMON FIRE RED - ASM EDITION"
    echo "  arrows/WASD move    z/space A    x/esc B    m/enter START    q quit"
    echo
    exec "$BIN"
    ;;
esac
