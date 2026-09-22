# The graphical build

`make gui` builds **`./pokemon-gui`**: the same hand-written assembly game, in a
real window, drawn with the real generated pictures.  There is no terminal
anywhere in the path -- not even a hidden one.

```
make gui                 # builds ./pokemon and ./pokemon-gui (needs SDL2)
./pokemon-gui            # a 1280x384 window, playable with the same keys
./pokemon-gui --scale 2  # twice the size
./pokemon-gui --help
```

Keys are the game's own: **arrows/WASD** move, **Z** is A, **X** is B, **M**
opens the menu, **Esc** quits.

## The game hands over its frames

The game and the window talk over a pipe, in a tiny binary protocol the game
itself writes.  `./pokemon --gfx` replaces the ANSI writer with a frame writer:

```
"PKF1"                    the magic
u8  map, x, y, direction  where the player is in the world
u8  screen col, row       where he was drawn (0xff = off screen)
u8  glyph, attr           3840 times: the glyph and (bg<<4)|fg for every cell
```

One `write(2)` per frame, 3850 bytes, and nothing has to be parsed out of
escape codes:

```
./pokemon --gfx        (the game, assembled)
   |   a frame, straight from the framebuffer in its data segment
   v
frontend/gui.c
   +--> tile match: every 2x2 block of cells is compared against the words of
   |    every packed tile; a full match is drawn as that tile's 32x32 art and
   |    the cells it covers are marked, so a person standing in the grass keeps
   |    the grass under him
   +--> people: the block of characters the game draws for a person
   |    (ent_sprite_defs in src/data.s) is recognised anywhere on the map and
   |    replaced with a sprite; the player's own direction comes from the
   |    frame header, so he is drawn from four pictures, one per way he faces
   +--> battle: a creature's name on an HP bar means the generated picture goes
   |    there, at 160x160, over the generated backdrop
   +--> screen changes get an effect: flash, then a wipe in tile columns
   +--> everything else: boxes, menus, HP bars and text in the game's own
        colours, with the packed bitmap font
   v
SDL2 texture -> window (or a .bmp, with --shot)
```

Half blocks are three bytes of UTF-8 in the game's framebuffer, because that is
what a terminal wants; `gfx_flip` folds them back down to the glyph number the
front-end matches tiles with.  The frame a `--gfx` build writes and the frame
the ANSI build produces are the *same picture*: with `--pty` to force the old
stream, both paths render pixel-for-pixel identical output (that is how the
protocol was tested).

Keys still go through a pseudo terminal, and only for input: the game sets its
own stdin to raw mode and reads it without blocking, so it gets a pty, while its
output goes to a plain pipe where no line discipline can touch the bytes.

The art comes from `frontend/assets.bin`, written by `tools/pack_assets.py`: the
generated PNGs quantised once, at build time, to the game's own 16 colours
(`art_src/*` -> palette indices, one byte per pixel), the tile words read back
out of `src/art.s` so the front-end matches tiles with exactly the same numbers
the game uses, and the people read out of `src/data.s` so they cannot drift from
the game either.  Nothing needs a PNG decoder at runtime: the pictures are
already pixels.

## Frame grabs without a display

```
make gui-shots      # docs/gui/title.png, route1.png, battle.png
make gui-tour       # docs/gui/tour.png: the three, captioned
```

Each one is a real frame: the front-end starts the real game, types a real
scenario from `tests/play.py` into it, and writes the frame it ended up with.
It runs on the dummy video driver, so it works over SSH and in CI.

The front-end has its own test hooks, all of them a real render to a bitmap:

```
--shot FILE.bmp      the frame at the end of the run
--settle MS          how long the game gets on screen before any key
--keys  STRING       scripted keys (u d l r a b s q, '.' waits)
--scenario NAME      a scenario from tests/play.py
--pty                draw a terminal instead of the native frame stream
POKEGUI_TESTWALKER=1 ./pokemon-gui    every person, facing every way
POKEGUI_TESTTRANS=1 ./pokemon-gui     the screen-change wipe, frame by frame
POKEGUI_DEBUG=1      what it decided (tile pictures, people, screen mode)
```

## What it does not do (yet)

* No sound.
* The camera is the game's own 80x24 view, so there is no scrolling beyond the
  screen edge; people are drawn one tile wide and a little taller, but the
  movement itself is still tile to tile.
* Half-block art inside the *menus* (bag icons, the party list) is still the
  game's own blocks: the map, the people, the title, the backdrops and the
  battle creatures are the replaced ones.
* The battle backdrop is scaled to cover the screen, so it loses the game's
  dimming.

The terminal build stays: `make` alone still builds the libc-free `./pokemon`,
`--pty` draws the window from its ANSI stream, and `make test` (22/22) still
drives the real binary through the text path.
