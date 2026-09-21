# POKéMON — FIRE RED, ASM EDITION

A FireRed-flavoured Pokémon game for x86-64 Linux, written in hand-written
GNU assembler with **no libc, no runtime, no game engine** — the only things
it talks to are the raw Linux syscalls (`read`, `write`, `open`, `mmap`,
`rt_sigaction`, `clock_nanosleep`, …). It renders a 16-colour ANSI
framebuffer, reads the keyboard in raw mode, and saves to a file.

* static binary, ~130 KB, links against nothing
* seven maps: PALLET TOWN, ROUTE 1, VIRIDIAN CITY, POKéMON CENTER, ROUTE 2,
  GRANITE CAVE, RED's HOUSE
* fourteen species with generated GBA-style art, four of them evolutions
* Intel syntax (`as .intel_syntax noprefix`), one file per subsystem
* plays in any 80×24 terminal

## Running it

Needs nothing but Linux x86-64 and `make` — no libc, no runtime, no libraries
to install. Building wants binutils (`as` + `ld`); the optional art tools want
`python3` with Pillow.

```
make            # build ./pokemon  (~2 seconds)
./pokemon       # play it
```

Run it in a **real terminal**, at least 80×24, with 16-colour ANSI support.
It puts the terminal into raw mode, so it wants a tty — piping it into a file
will not work (that is what `--headless` is for). It writes `pokemon.sav` in
whatever directory you launch it from.

**Keys**

| key | does |
| --- | --- |
| arrows / `WASD` | walk |
| `z` or space | A — talk, confirm, advance text |
| `x` or `esc` | B — cancel, back out |
| `enter` or `m` | START — the pause menu |
| `q` | quit |

**Your first five minutes**

1. `PRESS START` → `BEGIN A NEW ADVENTURE?` → **YES**.
2. Listen to PROF. OAK, then pick a partner: CHARMANDER, BULBASAUR or
   SQUIRTLE (left/right, then `z`).
3. Walk north out of PALLET TOWN and west into the **tall grass** on ROUTE 1 —
   that is where wild POKéMON live. Fight with `z`, catch things from the BAG.
4. The house with the red roof in VIRIDIAN CITY heals your team (talk to the
   NURSE). The rival is standing in the city too.
5. The east gate of ROUTE 1 opens onto **ROUTE 2**: a beach, a pier you can
   walk off the end of (MAGIKARP live in the lake), and the ridge east of the
   sand — step through the cave mouth at its foot and **GRANITE CAVE** holds
   GEODUDE, a treasure chest and a hiker who will tell you about it.
6. `m` → `SAVE` writes your game; the title screen will offer to continue.

**Other commands**

```
make test       # 22 scripted headless playthroughs, checked frame by frame
make maps       # reachability audit of the generated maps
make tour       # walkthrough -> docs/TOUR.md (20 real dumped frames)
make art        # re-convert art_src/*.png -> src/art.s and rebuild
make screens    # docs/shots/*.png -> docs/screens.html
```

`tools/ptyrender.py OUT.png --scenario battle` renders a real screen to a PNG,
and `docs/screens.html` collects them.

**Command line** (all optional)

```
./pokemon                 # normal game
  --quickstart            # skip the title and the intro
  --headless              # no raw mode: drive it with --script instead
  --script "…"            # a file or an input string (u d l r a b s . D q)
  --dump FILE             # in headless mode, write frames for inspection
  --fixed-rng             # deterministic battles
  --level N   --xp N      # jump the starter's level / give it EXP
  --trace                 # debug output on stderr
```

## What is in the game

* **Overworld** — 7 maps on a scrolling 40×8-tile viewport: PALLET TOWN,
  ROUTE 1, VIRIDIAN CITY, the POKéMON CENTER, **ROUTE 2** (the lake: sand, a
  pier out over the water, fences, a treasure chest, the cave mouth),
  **GRANITE CAVE** (boulder walls, stone floor, a hiker's camp with a PC,
  shelf, bedroll and rug) and **RED's HOUSE** (the interior set). NPCs,
  signs, item balls, chests, warps and gates between maps.
* **Wild battles** — the *tile* you step on picks the encounter table, the
  way the real games do it: tall grass holds PIDGEY/RATTATA/ODDISH/MEOWTH/
  PIKACHU, the lake is surfable and holds MAGIKARP, and the cave floor holds
  GEODUDE. Sand, roads and grass are safe ground.
* **Gen-3 damage maths** — `((2·L/5+2)·pow·A/D)/50+2`, then type
  effectiveness (×0…×4), STAB ×1.5, critical ×2, and the 85–100 % random
  factor, floored at 1.
* **Full battle loop** — FIGHT / BAG / POKéMON / RUN, four moves with PP,
  stat stages (GROWL, TAIL WHIP), status (poison ticks, PSN tag), recoil,
  type-based AI move choice, trainer battles with two Pokémon, catch
  formula with Poké Ball wobbles, XP gain, level-up with stat recalculation
  and move learning, fainting, whiteout → wake up in the Pokémon Center.
* **Meta** — three starters (CHARMANDER / BULBASAUR / SQUIRTLE, the rival
  always takes the one that beats yours), party screen with a stats
  summary, bag (POTION, POKé BALL), Pokédex (SEEN/CAUGHT), save & continue.
* **Fourteen species** with real stats, types, catch rates, XP yields and
  16-colour sprite art: Charmander, Bulbasaur, Squirtle, Pidgey, Rattata,
  Oddish, Meowth, Pikachu, Magikarp, Geodude — plus the four evolutions
  Charmeleon, Ivysaur, Wartortle and Pidgeotto.

## Layout

```
Makefile              as + ld, no other tools needed
src/defs.inc          every constant: syscalls, key codes, struct layouts
src/core.s            _start, argument parsing, save file, map/species/mon helpers
src/gfx.s             terminal, framebuffer, glyphs, input queue, RNG, dump, SIGSEGV reporter
src/text.s            dialogue boxes, typewriter, \f paging, YES/NO, HP bars
src/world.s           overworld: rendering, camera, movement, warps, encounters
src/battle.s          the battle state machine, damage, AI, catching, XP
src/menu.s            pause menu, party, summary, bag, dex
src/main.s            title, intro, starter choice, main loop, state table
src/art.s             GENERATED by tools/art2cells.py (title + creature art as colour cells)
src/data.s            GENERATED by tools/gen_data.py (maps, text, moves, species)
tests/play.py         scripted input strings, one scenario per feature
tests/run_tests.py    the check: run the real binary, assert on the frames
tools/gen_data.py     map/sprite/text compiler with layout validation
tools/dumpframe.py    print a dumped frame as an 80×24 grid
tools/pathfind.py     route finding over the map data (avoiding NPCs and wild
                      ground) -> walking routes for the tests
tools/check_maps.py   reachability audit: every door, sign, item, NPC and
                      encounter ground, per map, plus which tiles get placed
tools/make_screens.py docs/shots/*.png -> docs/screens.html (data URIs, one file)
tools/tour.py         playthrough -> docs/TOUR.md (real frames, as text)
tools/ptyplay.py      drive the real terminal version from a pty
tools/vt.py           tiny ANSI/VT emulator (used by the pty harness)
tools/art2cells.py    art_src/*.png -> src/art.s (colour quantiser, cell fitter)
tools/ptyrender.py    run the real binary in a pty, render the screen to a PNG
docs/screens.html     the screenshots in this README's art section
art_src/              the generated source art (one PNG per creature, plus the title)
```

## How it is tested without a display

The game has a headless mode that is the same code path as the real game:
raw mode is skipped, but the framebuffer, input queue and main loop are the
ones the player uses.

```
./pokemon --headless --fast --quickstart --script "$(python3 tests/play.py win)" \
          --dump /tmp/frames.txt
python3 tools/dumpframe.py /tmp/frames.txt        # every dumped frame
```

* `--script S` — one input character per frame: `udlr` walk, `a`/`b`/`s`
  buttons, `.` wait a frame, `D` dump the screen, `q` quit (the argument may
  also be the name of a file containing the script).
* `--dump F` — append each `D`ed screen as plain text plus a state header
  (`# m= map x= y= d= dir s= state n= party hp= cur/max lv=`).
* `--quickstart` — skip the intro, spawn in PALLET TOWN with a starter,
  a POTION and Poké Balls.
* `--fixed-rng`, `--seed N` — deterministic battles for the tests.
* `--level N` — put the starter at level N (for testing late-game paths).
* `--trace` — dump the debug markers to stderr (crash bisection aid).

`make tour` captures the walkthrough the same way: 20 screens from title to
the lake, the cave, RED's house and an evolution, written to `docs/TOUR.md`.

`make test` runs 22 scenarios (title, intro, walking, grass encounters,
menus, party, bag, dex, save, load, wild battle, win, run, catch, Pokémon
Center, nurse healing, trainer battle, evolution, the lake, the cave and
RED's house) and checks the exit status, the absence of a crash report, and
the actual contents of the rendered frames.  `python3 tools/check_maps.py`
is the other half of that: it walks the generated maps and reports anything
a player could not reach — a door, a sign, an item, an NPC, the water, the
cave floor — before the tests are trusted with a new map.

There is also a crash reporter inside the binary: a SIGSEGV handler prints
the faulting address, RIP, seven registers and sixteen stack words, so a
failure in the sandbox is diagnosable without gdb.

## The art

Everything you look at is generated as Game Boy Advance style pixel art and
then converted into the game's own colour cells — the title scene, the logo,
the dialogue and menu frames, the terrain/object sheets, both battle
backdrops, and all fourteen species (three starters, Pidgey, Rattata, Oddish,
Meowth, Pikachu, Magikarp, Geodude and the four evolutions).

The pictures are drawn as **pixels, not characters**.  A terminal cell is two
square pixels stacked: one word per cell holds a foreground colour for the top
half and a background colour for the bottom half, and the blitter picks the
half block that matches what the source art had there.

```
art_src/title.png       -> src/art.s: art_title    80x24 cells (the whole screen)
art_src/logo.png        ->           art_logo      48x8  (the wordmark)
art_src/charmander.png  ->           art_big_0     12x8  (starter picker)
art_src/charmander.png  ->           art_sml_0     12x5  (in battle, on the status bar)
art_src/pidgeotto.png   ->           art_sml_13    12x5
art_src/bg_field.png    ->           art_bg_0      80x17 (wild battles)
art_src/bg_city.png     ->           art_bg_1      80x17 (trainer battles)
art_src/frame.png       ->           art_frame_border / art_frame_inner
art_src/tiles_out.png   ->           art_tiles     terrain sheet, spare pictures dropped
art_src/tiles_bld.png   ->           art_tiles     buildings and objects
art_src/tiles_in.png    ->           art_tiles     interior set (rooms, furniture)
```

The tileset is deliberately **sparse**: the map names a tileset, and for each
(tileset, tile) pair the game looks up which pooled picture to draw
(`art_tile_map`, 255 meaning "this set cannot place that tile").  Only
pictures that some map can actually reach are emitted at all, so `src/art.s`
holds no art the game never shows — `tools/check_maps.py` reports the
coverage and `tools/art2cells.py` drops and lists the rest.

One exception is deliberate: map tiles keep the glyph ramp rather than the
half-block pixels.  A tile gets 2x2 cells, which as pixels is a 2x4 picture,
and at that size every tile collapses into a flat colour field — the ramp
carries texture that eight pixels cannot.

`docs/screens.html` shows the real screens;
`python3 tools/make_screens.py` rebuilds that page from `docs/shots/`.

## Notes

* Everything is little-endian x86-64 System V; `src/defs.inc` owns all
  struct offsets so a layout change is a one-line edit.
* `src/data.s` is generated — edit `tools/gen_data.py`, then `make` (the
  generator refuses to emit a map or sprite whose cell count would corrupt
  the fixed-size records).
* The save file is `pokemon.sav` in the working directory (map, position,
  party, bag, flags, money, dex, picked-up items, rival's choice).
