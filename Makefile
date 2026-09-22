# ============================================================================
#  POKeMON ASM EDITION - x86-64 Linux, raw syscalls, no libc, no engine.
#  Only needs: GNU as, GNU ld, GNU make (+ python3 to regenerate data.s).
#  make test   : 22 scripted headless playthroughs
#  make maps   : reachability audit of the generated maps
#  make tour   : docs/TOUR.md   -- real frames from a real playthrough
#  make art    : regenerate src/art.s (needs python3 + Pillow)
# ============================================================================
AS      := as
LD      := ld
ASFLAGS := -I src
LDFLAGS := -nostdlib -static -z noexecstack

OBJS := build/core.o build/gfx.o build/text.o build/main.o build/world.o \
        build/menu.o build/battle.o build/data.o build/art.o

all: pokemon

build:
	@mkdir -p build

# data.s is generated: sprite art widths and map rows get validated at
# generation time so the framebuffer layout can never be corrupted by a typo.
src/data.s: tools/gen_data.py
	python3 tools/gen_data.py > src/data.s

# src/art.s is generated too; it needs Pillow, so it is not rebuilt by 'all'.
art:
	python3 tools/art2cells.py
	python3 -c "import os; os.utime('src/art.s', None)"
	$(MAKE) pokemon

build/%.o: src/%.s src/defs.inc | build
	$(AS) $(ASFLAGS) -o $@ $<

pokemon: $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $(OBJS)
	@echo "built: $$(ls -lh pokemon | awk '{print $$5}') static binary"

# ------------------------------------------------------------------ testing --
# headless backend: scripted input, text mode, real game loop.
test: pokemon
	bash tests/run_tests.sh

demo: pokemon
	./tools/demo.sh

# regenerate docs/TOUR.md from real dumped frames
tour: pokemon
	python3 tools/tour.py

# reachability audit of the generated maps: every warp, sign, item, npc and
# encounter ground has to be walkable from the spawn, and every tile the art
# ships has to be placed by some map
maps:
	python3 tools/check_maps.py

# docs/shots/*.png -> docs/screens.html
screens:
	python3 tools/make_screens.py

# ------------------------------------------------------------- graphical ----
# The window front-end: same assembly game, drawn at 16x16 pixels per cell
# instead of one character.  Needs SDL2 (libsdl2-dev / sdl2-devel / SDL2).
SDL_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL_LIBS   := $(shell pkg-config --libs sdl2 2>/dev/null)

# the generated art, packed for the front-end (needs python3 + Pillow)
assets:
	python3 tools/pack_assets.py

gui: pokemon frontend/assets.bin
	@if [ -z "$(SDL_LIBS)" ]; then \
		echo "SDL2 is not installed: apt install libsdl2-dev"; exit 1; fi
	gcc -O2 -Wall -o pokemon-gui frontend/main.c $(SDL_CFLAGS) $(SDL_LIBS)
	@echo "built: ./pokemon-gui  (run it, or: ./pokemon-gui --scale 2)"

frontend/assets.bin: tools/pack_assets.py tools/art2cells.py
	python3 tools/pack_assets.py

# real graphical frames without a display, for the docs
gui-shots: gui
	SDL_VIDEODRIVER=dummy ./pokemon-gui --shot docs/gui/title.bmp --no-quickstart
	SDL_VIDEODRIVER=dummy ./pokemon-gui --shot docs/gui/route1.bmp --scenario shot_route1
	SDL_VIDEODRIVER=dummy ./pokemon-gui --shot docs/gui/battle.bmp --scenario battle
	python3 tools/bmp2png.py docs/gui

clean-gui:
	rm -f pokemon-gui frontend/assets.bin

clean:
	rm -rf build pokemon src/data.s

size: pokemon
	@size pokemon
	@nm pokemon | sort | tail -20

.PHONY: all test demo tour art maps screens clean size
