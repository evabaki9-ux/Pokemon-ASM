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

clean:
	rm -rf build pokemon src/data.s

size: pokemon
	@size pokemon
	@nm pokemon | sort | tail -20

.PHONY: all test demo tour art maps screens clean size
