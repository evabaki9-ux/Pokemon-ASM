# The graphical build

`make gui` builds **`./pokemon-gui`**: the same hand-written assembly game, in
a real window, drawn with the real generated pictures.

```
make gui                 # builds ./pokemon and ./pokemon-gui (needs SDL2)
./pokemon-gui            # a 1280x384 window, playable with the same keys
./pokemon-gui --scale 2  # twice the size
./pokemon-gui --help
```

Keys are the game's own: **arrows/WASD** move, **Z** is A, **X** is B, **M**
opens the menu, **Esc** quits.

## What it is

The assembly game is untouched.  It still runs headless-friendly on a pseudo
terminal and still writes its 80x24 frame as ANSI; the front-end reads that
stream and draws it at **16x16 pixels per cell** instead of one character.

| terminal build | graphical build |
| --- | --- |
| a map tile is 2x2 characters, 2x4 dots | a map tile is 32x32 pixels, from the generated tile art |
| a creature in battle is 12x5 half-block cells | the generated creature picture, 160x160, cut out and composited on the generated backdrop |
| the title screen is the generated art quantised to half blocks | the generated title picture at full screen |
| text is the terminal's font | a bitmap font packed from DejaVu Sans Mono at build time |
| 16 colours, one foreground and one background per cell | the same 16 colours, as many pixels as it takes |

So the pictures that were only a *source of colours* in the terminal build are
the actual image here — which is the whole point of the exercise.

## How it works

```
./pokemon  (the game)
   |   ANSI stream on a pty                    (forkpty, read, parse)
   v
frontend/main.c
   |   an 80x24 grid of {glyph, fg, bg}        (double buffered:
   |                                            a frame starts at ESC[1;1H)
   +--> tile match: every 2x2 block of cells is compared against the words of
   |    every packed tile; a full match is drawn as that tile's 32x32 art, and
   |    the cells it covers are marked, so an NPC standing in the grass keeps
   |    the grass under it
   +--> battle: if a creature's name is on the HP bar, the generated picture is
   |    drawn at that spot at full size
   +--> everything else: boxes, menus, HP bars and text in the game's own
        colours, with the packed bitmap font
   v
SDL2 texture -> window (or a .bmp, with --shot)
```

The art comes from `frontend/assets.bin`, written by `tools/pack_assets.py`:
the generated PNGs quantised once, at build time, to the game's own 16 colours
(`art_src/*` -> palette indices, one byte per pixel), plus the tile words read
back out of `src/art.s` so the front-end matches tiles with exactly the same
numbers the game uses.

Nothing needs a PNG decoder at runtime: the pictures are already pixels.

## Frame grabs without a display

```
make gui-shots      # docs/gui/title.png, route1.png, battle.png
```

Each one is a real frame: the front-end starts the real game on a pty, types a
real scenario from `tests/play.py`, and writes the frame it ended up with.  It
runs on the dummy video driver, so it works over SSH and in CI.

## What it does not do (yet)

* No sound.
* The map is drawn from the game's 80x24 view, so the camera matches the
  terminal build exactly -- there is no scrolling beyond the screen edge.
* Half-block art inside the *menus* (the small creature icons in the bag and
  the party screen) is still the game's own blocks: only the battle sprites and
  the map are replaced so far.
* The battle backdrop is scaled to cover the screen, so it loses the game's
  dimming; the terminal build's 34% dim is not reproduced.

The terminal build remains the default `make`, the tested one (`make test`,
22/22) and the one documented in `docs/TOUR.md`.
