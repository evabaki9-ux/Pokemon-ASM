#!/usr/bin/env python3
"""
tools/art2cells.py -- turn generated pixel art into the game's own cell data.

The game draws an 80x24 grid of cells.  A cell holds up to two ASCII glyphs
plus one 16-colour attribute, and bigger pictures are made of *pairs* of
cells: one "word" covers 2x2 cells (2x2 glyphs).  That is the only way the
formats line up, so this tool:

  1. loads a generated PNG from art_src/,
  2. crops/scales it so one source sample maps to one glyph of the target,
  3. quantises every sample to the game's 15 colours + transparent,
  4. picks a glyph per sample out of a coverage ramp ('.' ':' '*' '#'),
  5. emits src/art.s: an array of 32-bit words (glyph0 | glyph1<<8 | attr<<16)
     plus preview_*.png so the result can be looked at before it ships.

usage:  python3 tools/art2cells.py [--preview-only]
"""
import os
import struct
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "art_src")
OUT = os.path.join(ROOT, "build", "art")
ASM = os.path.join(ROOT, "src", "art.s")

# ---- the game's palette: ANSI 1..15, index 0 is black == transparent --------
PALETTE = [
    (1, 0xAA, 0x00, 0x00),   # C_RED
    (2, 0x00, 0xAA, 0x00),   # C_GREEN
    (3, 0xAA, 0x55, 0x00),   # C_YELLOW (orange)
    (4, 0x00, 0x00, 0xAA),   # C_BLUE
    (5, 0xAA, 0x00, 0xAA),   # C_MAGENTA
    (6, 0x00, 0xAA, 0xAA),   # C_CYAN
    (7, 0xAA, 0xAA, 0xAA),   # C_WHITE  (light grey)
    (8, 0x55, 0x55, 0x55),   # C_GRAY
    (9, 0xFF, 0x55, 0x55),   # C_BRED
    (10, 0x55, 0xFF, 0x55),  # C_BGREEN
    (11, 0xFF, 0xFF, 0x55),  # C_BYELLOW
    (12, 0x55, 0x55, 0xFF),  # C_BBLUE
    (13, 0xFF, 0x55, 0xFF),  # C_BMAGENTA
    (14, 0x55, 0xFF, 0xFF),  # C_BCYAN
    (15, 0xFF, 0xFF, 0xFF),  # C_BWHITE
]

# glyph ramp, darkest -> brightest.  A cell with no ink stays empty so that
# sprites keep whatever was drawn under them.
# Cell luminance -> glyph.  What a terminal can vary inside one cell is only
# the glyph, so the ramp *is* the shading: dark cells stay black, bright cells
# get dense ink.  Backgrounds use SCENE, single subjects use SPRITE.
SCENE_RAMP = [(0.20, " "), (0.32, "."), (0.46, ":"), (0.62, "+"), (1.01, "#")]
SPRITE_RAMP = [(0.06, " "), (0.18, "."), (0.34, ":"), (0.55, "+"), (1.01, "#")]


def shade(v, ramp, max_glyph=None):
    out = ramp[-1][1]
    for thr, g in ramp:
        if v < thr:
            out = g
            break
    if max_glyph is not None:
        # density order, and it has to list every glyph a tile may cap to
        order = [" ", ".", ":", "+", "*", "#", "|", "=", "-"]
        if order.index(out) > order.index(max_glyph):
            out = max_glyph
    return out

# 4x4 ink masks so the preview looks like the real thing
GLYPH_BITS = {
    ".": ["0000", "0010", "0000", "0000"],
    ":": ["0000", "0010", "0000", "0100"],
    "+": ["0010", "0000", "0100", "0000"],
    "*": ["1001", "0010", "0100", "1001"],
    "#": ["1111", "1111", "1111", "1111"],
    " ": ["0000", "0000", "0000", "0000"],
}

# name -> (file, cells_w, cells_h, crop box or None, margin %, min luminance)
SPECS = [
    # name, file, cells_w, cells_h, crop, margin%, luminance floor, fit, solid
    ("title",      "title.png",      80, 24, None, 0, 0,  "contain", False, True),
    ("spr_big",    None,             12, 8,  None, 6, 20, "contain", True, False),
    ("spr_battle", None,             12, 5,  None, 6, 20, "contain", True, False),
]

# species order used by the game (see defs.inc / gen_data.py)
SPECIES = ["charmander", "bulbasaur", "squirtle", "pidgey", "rattata",
           "oddish", "meowth", "pikachu", "magikarp", "geodude",
           # evolved forms, in the same order as SPECIES in gen_data.py
           "charmeleon", "ivysaur", "wartortle", "pidgeotto"]


import colorsys
from collections import Counter

# A terminal has seven hues, all of them primary (0, 30, 60, 120, 180, 240,
# 300 degrees) and no orange or rose at all.  Measuring the source pixel in HSV
# and snapping its hue onto one of those, then choosing the dark or the bright
# member of the family by value, keeps gradients looking like gradients instead
# of collapsing into one flat red.
HUES = [(0, 1, 9), (20, 3, 11), (60, 11, 11), (120, 2, 10),
        (180, 6, 14), (240, 4, 12), (300, 5, 13)]


# index -> rgb, for code that needs a colour's actual value
PAL_RGB = {e[0]: e[1:] for e in PALETTE}


def nearest(rgb, _unused=None):
    r, g, b = [v / 255.0 for v in rgb]
    h, sat, val = colorsys.rgb_to_hsv(r, g, b)
    if val < 0.24:
        return 0, 0                          # keep the darks dark: less noise
    if sat < 0.25:                           # greys: sky haze, rocks, clouds
        if val < 0.35:
            return 8, 0                      # C_GRAY
        if val < 0.60:
            return 7, 0                      # C_WHITE (light grey)
        return 15, 0                         # C_BWHITE
    if val < 0.34 and sat < 0.90:
        return 8, 0                          # silhouettes read grey, not blue
    deg = h * 360.0
    best, hi, lo = None, None, None
    for hd, dark, bright in HUES:
        d = min(abs(deg - hd), 360 - abs(deg - hd))
        if best is None or d < best:
            best, hi = d, (bright if val >= 0.80 else dark)
    return hi, int(best)


ss = 2          # samples down each cell (across is always 2*ss)
BGTOL = 90      # sum-of-|RGB| distance from the corner colour = background
BG_W, BG_H = 80, 17                  # battle backdrop size in cells

# ---------------------------------------------------------------- tiles -----
# The overworld tiles are cut out of two generated 4x4 tileset sheets, one
# block per tile.  A map tile is 2x2 cells, so a whole block is scaled into a
# 2-cell box; the block is pre-cropped to a 2:1 band first (a cell is twice as
# tall as it is wide).  `base` composites the subject onto another block --
# a tree or a flower bed has to stand on grass, not on its white backdrop.
# Each sheet has its own block grid (the generators do not agree on one) and
# a thin dark separator line between blocks, hence the inset.
SHEET_GRID = {"tiles_out.png": (8, 4), "tiles_bld.png": (4, 4),
              "tiles_in.png": (4, 4)}
# some sheets do not start at their top-left pixel: tiles_in has a wide margin
SHEET_ORIGIN = {"tiles_in.png": (291, 0, 794, 768)}
TILE_INSET = 5                       # pixels dropped at every block edge
# tile, sheet, block, composite base, forced colour (None = quantise it).
# The forced colours are the tileset's design: without them a tree and a lawn
# quantise to the same green and the map turns into one flat texture.
TILE_SPECS = [
    (0,  "tiles_out.png", 5,  None, 10, "."),   # 0  grass: walkable, light
    (1,  "tiles_out.png", 2,  None, 2,  "*"),   # 1  tall grass: you can hide in it
    (2,  "tiles_out.png", 6,  None, 2,  "*"),   # 2  tree canopy: an obstacle
    (3,  "tiles_bld.png", 0,  None, 1,  "*"),   # 3  brick wall
    (4,  "tiles_out.png", 27, None, 7,  ":"),   # 4  stone floor
    (5,  "tiles_out.png", 12, None, 14, "*"),   # 5  water
    (6,  "tiles_bld.png", 1,  None, 9,  "*"),   # 6  roof tiles
    (7,  "tiles_bld.png", 2,  None, 3,  ":"),   # 7  wooden door
    (8,  "tiles_bld.png", 3,  ("tiles_out.png", 27), 3, ":"),  # 8 shop counter
    (9,  "tiles_bld.png", 4,  ("tiles_out.png", 5), 3, ":"),   # 9 signboard
    (10, "tiles_bld.png", 6,  ("tiles_out.png", 5), None, "+"), # 10 POKe BALL
    (11, "tiles_out.png", 14, ("tiles_out.png", 5), None, "+"), # 11 flower bed
    (12, "tiles_out.png", 10, None, 3,  ":"),   # 12 dirt path
    (13, "tiles_bld.png", 6,  ("tiles_out.png", 5), None, "+"), # 13 POKe BALL
    # 14+ : the beach, the cave and the scenery, so the rest of the generated
    # sheets actually appears in the world
    (14, "tiles_out.png", 8,  None, 3,  "."),   # sand (beach)
    (15, "tiles_out.png", 21, None, 7,  "*"),   # cave floor: grey stone
                                                # texture, dimmer than the walls
    (16, "tiles_out.png", 17, None, 7,  "*"),   # boulder (cave wall)
    # boulders cap high and the floor caps at '.': the wall has to be denser
    # than the ground it stands on or the cave reads as a black rectangle
    (17, "tiles_bld.png", 7,  None, 7,  "*"),   # white fence
    (18, "tiles_bld.png", 11, None, 3,  "+"),   # treasure chest
    # these four are interior furniture: set 0 carries a copy because both
    # sets must be the same length, but only set 1 is ever placed
    (19, "tiles_in.png", 5,  None, 7,  "+"),    # PC terminal
    (20, "tiles_in.png", 6,  None, 3,  "+"),    # bookshelf
    (21, "tiles_in.png", 11, None, 3,  "="),    # bed, with the pillow
    (22, "tiles_in.png", 9,  None, 5,  ":"),    # striped rug
    # the rest of the sheets: the window that goes on the house fronts, a
    # street lamp, bushes for the routes, cobbles for the town paving, the
    # shallow lake edge, and a potted plant for indoors
    (24, "tiles_bld.png", 8,  None, 3,  "#"),    # window
    (25, "tiles_bld.png", 12, None, 7,  "*"),    # street lamp
    (26, "tiles_out.png", 4,  None, 7,  "*"),    # bush
    (27, "tiles_out.png", 26, None, 3,  ":"),    # cobblestone
    (28, "tiles_out.png", 22, None, 3,  ":"),    # shallow water
    (29, "tiles_in.png", 10, None, 3,  "+"),     # potted plant
]
# The indoors set is the same 15 tiles with the room's own blocks swapped in.
# Interiors are a separate tileset in the real games and they are here too:
# the map itself says which set to use (map_tilesets in src/data.s).
TILE_SPECS_IN = [
    (14, "tiles_in.png", 0,  None, 3,  "."),    # sand won't appear indoors: planks
    (15, "tiles_in.png", 0,  None, 3,  "."),    # cave floor likewise
    (16, "tiles_in.png", 2,  None, 7,  "*"),    # boulder likewise: a wall
    (17, "tiles_in.png", 2,  None, 7,  "*"),
    (18, "tiles_in.png", 6,  None, 3,  "+"),    # a chest indoors: the shelf
    (3,  "tiles_in.png", 2,  None, 7,  "*"),    # wall: plaster + blue wainscot
    (4,  "tiles_in.png", 0,  None, 3,  ":"),    # floor: wooden planks
    (8,  "tiles_in.png", 4,  ("tiles_in.png", 0), 3, ":"),   # counter
    (11, "tiles_in.png", 10, None, 2,  "+"),    # potted plant
    (12, "tiles_in.png", 9,  None, 7,  ":"),    # striped rug
    (13, "tiles_in.png", 3,  None, None, "+"),  # healing machine
    (0,  "tiles_in.png", 1,  None, 7,  "."),    # spare: white tile floor
    (19, "tiles_in.png", 5,  None, 3,  "+"),    # PC: the blue terminal
    (20, "tiles_in.png", 6,  None, 3,  "#"),    # bookshelf: the books
    (21, "tiles_in.png", 11, None, 3,  "="),    # bed, in the interior set too
    (29, "tiles_in.png", 10, None, 3,  "+"),    # potted plant
    # 13 (TILE_OUT) is deliberately left empty: outside the map stays blank
]
# Map tiles: the glyph ramp, not half blocks.  A tile only gets 2x2 cells, so
# as pixels it is a 2x4 sprite, and at that size every tile collapses into a
# flat colour field (grass and tall grass both come out plain green).  The ramp
# carries texture the pixels cannot, so the world layer stays characters while
# every picture in the game is drawn with blit_art_hb.  --tiles-px switches it.
TILES_HB = False
N_TILES = 30      # 0..29; the 'out' tile (23) is not art
# tiles whose art is dark enough that the ramp would leave them blank: hold
# them at this minimum density so the cave floor shows up as stone, not as a
# hole in the screen
TILE_MIN = {15: ":"}


def tiles_used():
    """{(set, tile)} the game can actually reach, read off tools/gen_data.py.

    A tileset is not "every tile there is": it is the tiles the maps that use
    it place.  Deriving that here is what keeps art.s free of pictures no map
    can ever draw (the audit that started this: 10 of 30 tile blobs were
    unreachable)."""
    import contextlib
    import importlib.util
    import io
    path = os.path.join(ROOT, "tools", "gen_data.py")
    spec = importlib.util.spec_from_file_location("gen_data_for_art", path)
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(mod)     # importing it also prints data.s
    indoor = {i for i, mp in enumerate(mod.MAPS) if mp["name"] in mod.INDOOR_MAPS}
    used = set()
    for i, mp in enumerate(mod.MAPS):
        setno = 1 if i in indoor else 0
        floor = mp.get("floor", ".")
        for row in mp["rows"]:
            for ch in row:
                ch2 = floor if ch in "NHP" else (":" if ch == "n" else ch)
                t = mod.CHAR2TILE.get(ch2)
                if t is not None:
                    used.add((setno, t))
    return used


def content_box(im, tol=BGTOL):
    """bounding box of everything that is not the corner colour"""
    px = im.load()
    w, h = im.size
    cs = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    bg = tuple(sum(c[i] for c in cs) // 4 for i in range(3))
    x0, y0, x1, y1 = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > tol:
                x0, y0 = min(x0, x), min(y0, y)
                x1, y1 = max(x1, x), max(y1, y)
    return (x0, y0, x1, y1) if x1 >= 0 else (0, 0, w - 1, h - 1)


def pixelate_mode(im, sw, sh, dim=1.0):
    """Downsample to sw x sh the way pixel art wants it: each output pixel is
    the *dominant* colour of its own block, not an average of it.  Averaging
    (LANCZOS) turns a 2x4 tile into a flat rectangle -- at this size the eye
    needs the block's real colour, and a cave keeps its rock grey only if the
    sampling does not blend it with the shadow between the rocks."""
    px = im.load()
    w, h = im.size
    out = Image.new("RGB", (sw, sh))
    op = out.load()
    for oy in range(sh):
        y0 = oy * h // sh
        y1 = max(y0 + 1, (oy + 1) * h // sh)
        for ox in range(sw):
            x0 = ox * w // sw
            x1 = max(x0 + 1, (ox + 1) * w // sw)
            counts = {}
            for y in range(y0, y1):
                for x in range(x0, x1):
                    r, g, b = px[x, y]
                    if dim != 1.0:
                        r, g, b = int(r * dim), int(g * dim), int(b * dim)
                    idx = nearest((r, g, b))[0]
                    counts[idx] = counts.get(idx, 0) + 1
            best = max(counts.items(), key=lambda kv: (kv[1], -kv[0]))[0]
            op[ox, oy] = PAL_RGB[best] if best else (0, 0, 0)
    return out


def prepare_hb(path, cw, ch, crop=None, margin=0, minlum=0.20,
               fit="contain", img=None, dim=1.0, no_bg=False, mode=False):
    """-> [(idx, fg, bg)] one per cell, half-block style.

    One cell is two square pixels stacked (foreground on top, background
    below), so the sampling grid is `cw` pixels across and `ch*2` down --
    square pixels, which is what makes this look like an image instead of
    characters.  idx 0 = transparent, 1 = 'top half', 2 = 'full block'.
    """
    im = img if img is not None else Image.open(path).convert("RGB")
    if crop:
        im = im.crop(crop)
    px = im.load()
    w, h = im.size
    cs = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    bg = tuple(sum(c[i] for c in cs) // 4 for i in range(3))
    if sum(bg) <= minlum * 3:
        bg = (0, 0, 0)
    if no_bg:
        bg = None

    def subject(c):
        if bg is None:
            return True
        return abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) > BGTOL

    if bg is not None:                      # crop to the subject
        x0, y0, x1, y1 = w, h, -1, -1
        for y in range(h):
            for x in range(w):
                if subject(px[x, y]):
                    x0, y0 = min(x0, x), min(y0, y)
                    x1, y1 = max(x1, x), max(y1, y)
        if x1 >= 0:
            im = im.crop((x0, y0, x1 + 1, y1 + 1))
    sw, sh = cw, ch * 2                     # pixels: square, one per cell across
    aspect = im.width / float(im.height)
    room = 1 - margin / 100.0
    if fit == "cover":
        nw, nh = sw, max(1, int(sw / aspect))
    elif fit == "stretch":
        nw, nh = sw, sh
    else:
        nw = min(sw * room, sh * room * aspect)
        nh = max(1, int(nw / aspect))
        nw = max(1, int(nw))
    if mode:
        # exact size, one output pixel per source block: no black canvas, no
        # letterboxing, every pixel is real art
        im = pixelate_mode(im, sw, sh, dim)
        canvas = im
    else:
        im = im.resize((nw, nh), Image.LANCZOS)
        canvas = Image.new("RGB", (sw, sh), (0, 0, 0))
        ox, oy = (sw - nw) // 2, (sh - nh) // 2
        canvas.paste(im, (ox, oy))
    px = canvas.load()
    cells = []
    for cy in range(ch):
        for cx in range(cw):
            cols, drawn = [], False
            for half in (0, 1):
                y = cy * 2 + half
                if y >= sh:
                    cols.append(0)
                    continue
                c = px[cx, y]
                if subject(c):
                    drawn = True
                    if dim != 1.0:
                        c = tuple(int(v * dim) for v in c)
                    cols.append(nearest(c)[0])
                else:
                    cols.append(0)          # background reads as black
            top, bottom = cols
            if not drawn:
                cells.append((0, 0, 0))     # nothing here: leave the cell alone
            elif top == bottom:
                cells.append((2, top, bottom))
            else:
                cells.append((1, top, bottom))
    return cw, ch, cells


def hue_of(idx):
    r, g, b = [v / 255.0 for v in PAL_RGB[idx]]
    return colorsys.rgb_to_hsv(r, g, b)[0]


def tile_feature(counts, total, ground):
    """A tile is mostly its ground colour, which buries small features --
    pink flowers in grass, a yellow sign on green.  If a decent slice of the
    cell is a different hue, that is the thing worth showing, so report it."""
    best, bestn = ground, counts[ground]
    for idx, n in counts.items():
        if idx == ground or n < total * 0.18:
            continue
        r, g, b = [v / 255.0 for v in PAL_RGB[idx]]
        _, sat, val = colorsys.rgb_to_hsv(r, g, b)
        if sat < 0.3 or val < 0.3:           # pale haze or shadow, not a feature
            continue
        d = abs(hue_of(idx) - hue_of(ground))
        if min(d, 1.0 - d) > 1.0 / 6.0:       # a genuinely different hue
            # a feature beats the ground even when the ground is commoner --
            # that is the whole point: a flower bed has to look like flowers
            if best == ground or n > bestn:
                best, bestn = idx, n
    return best


def block_rect(im, sheet, idx):
    """the square block `idx` of `sheet`, grid lines trimmed off"""
    cols, rows = SHEET_GRID[sheet]
    ox, oy, ow, oh = SHEET_ORIGIN.get(sheet, (0, 0, im.width, im.height))
    cw, ch = ow // cols, oh // rows
    bcx, bcy = idx % cols, idx // cols
    x, y = ox + bcx * cw, oy + bcy * ch
    i = TILE_INSET
    return (x + i, y + i, x + cw - i, y + ch - i)


def compose(base_im, base_sheet, base_idx, over_im, over_sheet, over_idx):
    """paste the subject of one block over another block's background"""
    b = base_im.crop(block_rect(base_im, base_sheet, base_idx))
    o = over_im.crop(block_rect(over_im, over_sheet, over_idx)).resize(b.size)
    op, bp = o.load(), b.load()
    w, h = b.size
    cs = [op[2, 2], op[w - 3, 2], op[2, h - 3], op[w - 3, h - 3]]
    bg = tuple(sum(c[i] for c in cs) // 4 for i in range(3))
    for y in range(h):
        for x in range(w):
            c = op[x, y]
            if abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) > BGTOL:
                bp[x, y] = c
    return b
# Scenery sits behind sprites, so it is kept dark and sparse: few glyphs and
# a dim colour ramp, otherwise the battle boxes drown in texture.
BG_RAMP = [(0.28, " "), (0.50, "."), (0.72, ":"), (1.01, "+")]
# Terrain wants to read as a *texture*, not as sparse dots: a map tile that is
# mostly blank just looks like a hole in the map.
# The terrain sheets are flat colour blocks -- a GBA ground tile is a solid
# colour -- so a tile gets its material from a *pattern*: the art says which
# colour the ground is, the pattern says how it is textured.  density = how
# many of the tile's four cells show the bright colour, in a 2x2 Bayer order
# so the lighter cells are spread diagonally instead of piling up on one side.
BAYER = {(0, 0): 0, (1, 0): 2, (0, 1): 3, (1, 1): 1}
TILE_PATTERN = {
    0:  (2, "#"),     # grass: a sprinkle
    1:  (3, ":"),     # tall grass: you can hide in it
    2:  (4, "#"),     # tree: a canopy, and dark
    3:  (4, ":"),     # wall: brick courses
    4:  (2, ":"),     # floor
    5:  (2, ":"),     # water: waves
    6:  (3, "#"),     # roof tiles
    7:  (4, "|"),     # door: planks
    8:  (4, ":"),     # shop counter
    9:  (2, "|"),     # signboard: a post on grass
    10: (3, "."),     # item
    11: (3, "+"),     # flowers
    12: (3, ":"),     # dirt path
    13: (3, "."),     # ball
    14: (2, "."),     # sand
    15: (3, ":"),     # cave floor
    16: (4, "#"),     # boulder
    17: (3, "|"),     # fence
    18: (4, "#"),     # chest
    19: (4, "#"),     # PC
    20: (4, "#"),     # bookshelf
    21: (3, "="),     # bed
    22: (2, "-"),     # striped rug
    24: (3, "#"),     # window: panes
    25: (3, "|"),     # lamp: a post
    26: (4, ":"),     # bush: leaves, denser than grass
    27: (3, ":"),     # cobblestone
    28: (2, ":"),     # shallow water
    29: (3, "+"),     # potted plant
}
# a tile whose art reads dark wants its *dark* colour as the pattern, or the
# canopy comes out the same green as the grass it stands on
TILE_DARK = {2: True, 16: True, 17: True}
# tiles the sampler reads as black but which must not be a hole in the map:
# pin them to an explicit (base, feature) pair of palette entries instead
TILE_FORCE = {15: (8, 7),   # cave floor: dark stone under a lighter speckle
              16: (7, 8),   # boulder: pale rock, so walls read as rock
              # objects that stand on something: the base is the surface they
              # stand on and the feature is the object itself, otherwise every
              # one of them renders as a black hole in the floor or the grass
              19: (3, 7),   # PC: the pale terminal on floorboards
              20: (3, 11),  # bookshelf: gold spines on floorboards
              21: (3, 12),  # bed: the blue blanket on floorboards
              22: (3, 5),   # rug: magenta stripes on floorboards
              24: (1, 14),  # window: bright panes in the brick front
              25: (2, 7),   # lamp: iron post on grass
              26: (2, 10),  # bush: light leaves on grass
              9:  (2, 11),  # sign: a yellow board on a post in the grass
              7:  (8, 3),   # door: a door, in a dark frame
              27: (7, 8),   # cobblestone: pale stones, dark joins
              28: (6, 15),  # shallow water: white surf on cyan
              29: (3, 2),   # potted plant: green leaves on floorboards
              13: (7, 1)}   # machine/TV: the white console with red trim


def dim(idx):
    """the plain version of a palette entry: 8..15 are the bright half"""
    return idx - 8 if idx >= 8 else idx


def bright(idx):
    """the bright version of a palette entry (give it a dim one)"""
    idx = dim(idx)
    if idx == 7:
        return 15                          # grey -> white, not pink
    if idx == 0:
        return 8                           # black -> dark grey
    return idx + 8


TILE_RAMP = [(0.20, " "), (0.36, "."), (0.52, ":"), (0.66, "+"),
             (0.82, "*"), (1.01, "#")]
TILE_DIM = 0.85                      # keep the map a shade darker than sprites
BG_DIM = 0.34
BACKDROPS = [("bg_field.png", "FIELD"), ("bg_city.png", "TOWN")]


def prepare(path, tw, th, crop, margin, minlum, fit="contain", solid=False,
            absolute_ramp=False, ss=2, sprite_ramp=False, dim=1.0,
            bg_ramp=False, img=None, no_bg=False, tile_ramp=False,
            max_glyph=None, min_glyph=None, want_bg=False):
    """-> (cells_w, cells_h, [(colour index, glyph) ...]) one entry per cell.

    The source is sampled on an `ss`-times finer grid than the cell grid, then
    each cell looks at its own little block: the block's dominant non-black
    colour becomes the cell colour and the fraction of lit samples becomes the
    glyph density.  Quantising per sample (rather than averaging a dithered
    image first) is what keeps the sunset gradient from collapsing into red.
    """
    im = img if img is not None else Image.open(path).convert("RGB")
    if crop:
        im = im.crop(crop)
    # Background: not every generator draws the subject on black (pidgey and
    # rattata come on white), so take it from the corners instead of assuming.
    px = im.load()
    w, h = im.size
    cs = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    bg = tuple(sum(c[i] for c in cs) // 4 for i in range(3))
    if sum(bg) <= minlum * 3:
        bg = (0, 0, 0)                    # dark picture: keep the plain floor
    if no_bg:
        # a tile is all texture: there is nothing to key out, and every
        # sample has to count or the tile comes out empty
        bg = None

    def off_bg(c):
        if bg is None:
            return True
        return abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) > BGTOL

    # content box: whatever differs from the background (skipped for tiles,
    # whose crop is already exact)
    if bg is None:
        x0, y0, x1, y1 = 0, 0, w - 1, h - 1
    else:
        x0, y0, x1, y1 = w, h, -1, -1
    if bg is not None:
        for y in range(h):
            for x in range(w):
                if off_bg(px[x, y]):
                    x0, y0 = min(x0, x), min(y0, y)
                    x1, y1 = max(x1, x), max(y1, y)
    if x1 < 0:
        raise SystemExit("%s has no content above the luminance floor" % path)
    im = im.crop((x0, y0, x1 + 1, y1 + 1))

    cw, ch = tw, th                       # output size in cells
    # A terminal cell is about twice as tall as it is wide, so the sampling
    # grid is 2*ss samples across each cell but only ss down it.  Getting this
    # wrong squashes every sprite horizontally.
    sw, sh = cw * ss, ch * ss
    # A sample is one *glyph* wide and ss-th of a cell tall, and a glyph is
    # twice as tall as it is wide, so a picture that is A wide:high needs
    # nw = 2*A*nh samples.  Forgetting that factor is what squashed the
    # sprites into a couple of columns.
    aspect = im.width / float(im.height)
    room = 1 - margin / 100.0
    if fit == "stretch":
        # the caller already knows the shape it wants (a map tile is exactly
        # 2x2 cells); stretching is the point, so skip the aspect maths
        nw, nh = sw, sh
    elif fit == "cover":
        nw = sw
        nh = max(1, int(sw / (2 * aspect)))
    else:
        nw = min(sw * room, sh * room * 2 * aspect)
        nh = nw / (2 * aspect)
    nw, nh = max(1, int(nw)), max(1, int(nh))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (sw, sh), (0, 0, 0))
    # `cover` can overflow: keep the top of the picture when it does
    canvas.paste(im, ((sw - nw) // 2, max(0, (sh - nh) // 2) if nh < sh
                      else 0))
    px = canvas.load()

    cells = []
    for cy in range(ch):
        for cx in range(cw):
            counts = {}
            lums = 0.0
            n = 0
            for sy in range(ss):
                for sx in range(ss):
                    r, g, b = px[cx * ss + sx, cy * ss + sy]
                    n += 1
                    if not off_bg((r, g, b)):
                        continue          # background: leave the cell empty
                    if dim != 1.0:
                        r, g, b = int(r * dim), int(g * dim), int(b * dim)
                    idx, _ = nearest((r, g, b))
                    lums += max(r, g, b) / 255.0
                    if idx:
                        counts[idx] = counts.get(idx, 0) + 1
            if not counts:
                cells.append((0, " ", 0) if want_bg else (0, " "))
                continue
            fg = max(counts.items(), key=lambda kv: (kv[1], -kv[0]))[0]
            # a tile cell needs the ground colour it stands on as well as its
            # feature: one glyph on black leaves the map reading as empty
            # space, and the base colour is what turns a field of dots into
            # grass.  The feature is what the glyph then draws on it.
            base = fg
            if no_bg and len(counts) > 1:
                fg = tile_feature(counts, sum(counts.values()), fg)
            if solid:
                glyph = "#"                # subjects: the colour carries them
            else:
                if bg_ramp:
                    ramp = BG_RAMP
                elif tile_ramp:
                    ramp = TILE_RAMP
                elif sprite_ramp:
                    ramp = SPRITE_RAMP
                else:
                    ramp = SCENE_RAMP
                glyph = shade(lums / float(n), ramp, max_glyph)
                if min_glyph is not None:
                    # a floor may not be a hole: when the source art is dark
                    # the ramp picks ' ' and the tile would leave the screen
                    # black, so hold it at a visible density
                    ranks = [g for _, g in ramp]
                    if ranks.index(glyph) < ranks.index(min_glyph):
                        glyph = min_glyph
            cells.append((fg, glyph, base) if want_bg else (fg, glyph))
    return cw, ch, cells


def words(cells, cw):
    """one 32-bit word per screen cell: glyph | (attr << 16); 0 = transparent.
    This matches fb_cells (glyph bytes) + fb_attr (one byte per cell)."""
    out = []
    for col, glyph in cells:
        if col == 0 or glyph == " ":
            out.append(0)                      # leave whatever is underneath
            continue
        out.append(ord(glyph) | ((col & 0x0f) << 16))
    return out


def tile_words(cells):
    """glyph | (fg << 16) | (base << 24).  A map tile cell is a coloured
    square with a glyph on it, so unlike a sprite cell a blank one is not
    transparent -- the base colour is the point of it."""
    return [ord(g) | ((c & 0x0f) << 16) | ((b & 0x0f) << 24)
            for (c, g, b) in cells]


def preview_hb(cells, cw, ch, path, scale=6):
    """draw a half-block blob as it will appear: two pixels per cell"""
    im = Image.new("RGB", (cw * scale, ch * 2 * scale // 2 * 2), (0, 0, 0))
    px = im.load()
    for y in range(ch):
        for x in range(cw):
            idx, fg, bg = cells[y * cw + x]
            if not idx:
                continue
            top = PALETTE[fg - 1][1:] if fg else (0, 0, 0)
            bot = PALETTE[bg - 1][1:] if bg else (0, 0, 0)
            if idx == 2:
                bot = top
            for sy in range(scale):
                for sx in range(scale):
                    px[x * scale + sx, y * 2 * scale + sy] = top
                    px[x * scale + sx, y * 2 * scale + scale + sy] = bot
    im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
    im.save(path)
    return path


def text_preview_hb(cells, cw, ch):
    out = []
    for y in range(ch):
        row = []
        for x in range(cw):
            idx, fg, bg = cells[y * cw + x]
            if not idx:
                row.append("  ")
            else:
                row.append("%x%x" % (fg, bg))
        out.append("".join(row))
    return "\n".join(out)


def preview(cells, cw, ch, path, scale=4):
    """draw the glyph grid as it will appear on screen"""
    w, h = cw * scale, ch * scale
    im = Image.new("RGB", (w, h), (0, 0, 0))
    px = im.load()
    for y in range(ch):
        for x in range(cw):
            cell = cells[y * cw + x]
            col, glyph = cell[0], cell[1]
            base = cell[2] if len(cell) > 2 else 0
            if base:
                r, g, b = PAL_RGB.get(base, (0, 0, 0))
                for dy in range(scale):
                    for dx in range(scale):
                        px[x * scale + dx, y * scale + dy] = (r, g, b)
            if col == 0:
                continue
            r, g, b = PAL_RGB.get(col, (0, 0, 0))
            bits = GLYPH_BITS.get(glyph, GLYPH_BITS[" "])
            for by in range(4):
                for bx in range(4):
                    if bits[by][bx] == "1":
                        for dy in range(scale // 4):
                            for dx in range(scale // 4):
                                py, pxx = y * scale + by * (scale // 4) + dy, \
                                    x * scale + bx * (scale // 4) + dx
                                if 0 <= py < h and 0 <= pxx < w:
                                    px[pxx, py] = (r, g, b)
    im = im.resize((w * 2, h * 2), Image.NEAREST)
    im.save(path)
    return path


def text_preview(cells, cw, ch):
    out = []
    for y in range(ch):
        out.append("".join(cells[y * cw + x][1] for x in range(cw)))
    return "\n".join(out)


def patch_defs(border_idx):
    """keep the panel border constant in defs.inc in step with the art"""
    path = os.path.join(ROOT, "src", "defs.inc")
    if not os.path.exists(path):
        return
    src = open(path).read()
    out = []
    changed = False
    for line in src.split("\n"):
        if line.startswith(".set C_FRAME_BORDER"):
            new = ".set C_FRAME_BORDER, %d        # from art_src/frame.png" \
                % border_idx
            if line != new:
                changed = True
            out.append(new)
        else:
            out.append(line)
    if changed:
        open(path, "w").write("\n".join(out))
        print("  updated C_FRAME_BORDER in src/defs.inc")


def main():
    global ss
    global TILES_HB
    if "--tiles-px" in sys.argv:
        TILES_HB = True
    if "--ss" in sys.argv:
        ss = int(sys.argv[sys.argv.index("--ss") + 1])
    print("  sampling grid: %d samples up, %d across per cell" % (ss, 2 * ss))
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)

    defs = []
    blobs = []

    def add(label, path, tw, th, crop, margin, minlum, header,
            fit="contain", solid=False, absr=False, sprite_ramp=False, ss=2,
            dim=1.0, bg_ramp=False, img=None, no_bg=False, tile_ramp=False,
            max_glyph=None, min_glyph=None):
        if not os.path.exists(path):
            print("  ! missing %s -- skipped" % os.path.basename(path))
            return None
        cw, ch, cells = prepare(path, tw, th, crop, margin, minlum, fit, solid,
                                absr, ss=ss, sprite_ramp=sprite_ramp, dim=dim,
                                bg_ramp=bg_ramp, img=img, no_bg=no_bg,
                                tile_ramp=tile_ramp, max_glyph=max_glyph,
                                min_glyph=min_glyph)
        ws = words(cells, cw)
        blobs.append((label, ws, tw, th, header))
        prev = preview(cells, cw, ch, os.path.join(OUT, label + ".png"))
        print("  %-10s %2dx%-2d cells  %4d words   %s"
              % (label, tw, th, len(ws), os.path.basename(prev)))
        print(text_preview(cells, cw, ch))
        print()
        return ws

    def add_hb(label, fn, tw, th, crop, margin, minlum, header, fit="contain",
               dim=1.0, no_bg=False, img=None):
        """half-block blob: one word per cell, idx|(fg<<16)|(bg<<24)"""
        if img is None and not os.path.exists(fn):
            print("  ! missing %s -- skipped" % os.path.basename(fn))
            return None
        cw, ch, cells = prepare_hb(fn, tw, th, crop, margin, minlum, fit,
                                   img=img, dim=dim, no_bg=no_bg)
        ws = [i | (fg << 16) | (bg << 24) for (i, fg, bg) in cells]
        blobs.append((label, ws, tw, th, header))
        prev = preview_hb(cells, cw, ch, os.path.join(OUT, label + ".png"))
        print("  %-10s %2dx%-2d cells  %4d words   %s"
              % (label, tw, th, len(ws), os.path.basename(prev)))
        print(text_preview_hb(cells, cw, ch))
        print()
        return ws

    # ------------------------------------------------------------ title -----
    for name, fn, tw, th, crop, margin, minlum, fit, solid, absr in SPECS:
        if name == "title":
            add_hb("art_title", os.path.join(SRC, fn), tw, th, crop, margin,
                   minlum, "# generated title screen art: 80x24 cells,",
                   fit, no_bg=True)
        elif name == "spr_big":
            for i, sp in enumerate(SPECIES):
                fn2 = os.path.join(SRC, sp + ".png")
                add_hb("art_big_%d" % i, fn2, tw, th, None, margin, minlum,
                       "# %s, big (starter picker): 12x8 cells = 12x16 pixels"
                       % sp.upper(), fit)
        elif name == "spr_battle":
            for i, sp in enumerate(SPECIES):
                fn2 = os.path.join(SRC, sp + ".png")
                add_hb("art_sml_%d" % i, fn2, tw, th, None, margin, minlum,
                       "# %s, battle size: 12x5 cells = 12x10 pixels"
                       % sp.upper(), fit)

    # --------------------------------------------------------- backdrops ----
    # the battle scene behind the boxes: cover fit so the screen is filled
    scene = [s for s in SPECS if s[0] == "title"][0]
    for i, (fn, nm) in enumerate(BACKDROPS):
        add_hb("art_bg_%d" % i, os.path.join(SRC, fn), BG_W, BG_H, None,
               scene[5], scene[6], "# battle backdrop: %s, %dx%d cells"
               % (nm, BG_W, BG_H), "cover", dim=BG_DIM, no_bg=True)

    dropped = []                     # tiles no map can reach (reported below)
    # ------------------------------------------------------------- tiles ----
    # one blob per map tile: art_tiles + tile*16 bytes, 2x2 cells, row-major.
    # Set 0 is the overworld, set 1 the indoors set, and every tile is a blob
    # of its own -- no tile is shared between the sets.
    cache = {}
    tile_set = {0: [None] * N_TILES, 1: [None] * N_TILES}

    def tile_blob(idx, sheet, block, base, force, cap, setno):
        """one map tile: 2x2 cells, but every cell is a pair of square pixels.

        Half blocks here too: a cell is 'top pixel / bottom pixel', so a tile
        is a 2x4 pixel sprite instead of four characters of a shading ramp.
        `force` and `cap` were there to fight the glyph ramp (the sampler had
        to be dragged onto the tile's own colour and away from sparse dots);
        with real pixels the sampled colours stand on their own."""
        nonlocal cache
        if sheet not in cache:
            cache[sheet] = Image.open(os.path.join(SRC, sheet)).convert("RGB")
        im = cache[sheet]
        if base:
            if base[0] not in cache:
                cache[base[0]] = Image.open(os.path.join(SRC, base[0])).convert("RGB")
            im = compose(cache[base[0]], base[0], base[1], im, sheet, block)
            crop = None
        else:
            crop = block_rect(im, sheet, block)
        label = "art_tile_%d_%d" % (setno, idx)
        if TILES_HB:
            cw, ch, cells = prepare_hb(os.path.join(SRC, sheet), 2, 2, crop, 0,
                                       0.08, "stretch", img=im, dim=TILE_DIM,
                                       no_bg=True, mode=True)
            ws = [i | (fg << 16) | (bg << 24) for (i, fg, bg) in cells]
            blobs.append((label, ws, 2, 2, "# set %d tile %d" % (setno, idx)))
            prev = preview_hb(cells, cw, ch, os.path.join(OUT, label + ".png"))
            print("  %-10s %2dx%-2d cells  %4d words   %s"
                  % (label, 2, 2, len(ws), os.path.basename(prev)))
            print(text_preview_hb(cells, cw, ch))
            print()
        else:
            cw, ch, cells = prepare(os.path.join(SRC, sheet), 2, 2, crop, 0,
                                    0.08, "stretch", img=im, no_bg=True,
                                    tile_ramp=True, ss=3, dim=TILE_DIM,
                                    max_glyph=None if cap == "*" else cap,
                                    min_glyph=TILE_MIN.get(idx), want_bg=True)
            # the tile's own colour, from the sheet: the commonest of its
            # four cells wins, so a tile that is mostly grass is green
            tones = {}
            for c, g, b in cells:
                if b:
                    tones[b] = tones.get(b, 0) + 1
            main = max(tones.items(), key=lambda kv: kv[1])[0] if tones else 0
            # foliage and rock read as *mass*: their colour on black, rather
            # than a bright slab out of which the grass disappears
            dark = TILE_DARK.get(idx)
            base = 0 if dark else dim(main)
            feat = dim(main) if dark else bright(main)
            if idx in TILE_FORCE:
                base, feat = TILE_FORCE[idx]
            density, glyph = TILE_PATTERN.get(idx, (3, ":"))
            cells = [(feat, glyph, base) if BAYER[(cx, cy)] < density
                     else (base, " ", base)
                     for cy in range(2) for cx in range(2)]
            ws = tile_words(cells)
            if force is not None:
                # the generator can still pin a tile to one palette entry
                pass
            blob = (label, ws, 2, 2, "# set %d tile %d" % (setno, idx))
            blobs.append(blob)
            prev = preview(cells, cw, ch, os.path.join(OUT, label + ".png"))
            print("  %-10s %2dx%-2d cells  %4d words   %s"
                  % (label, cw, ch, len(ws), os.path.basename(prev)))
            print(text_preview(cells, cw, ch))
            print()
        tile_set[setno][idx] = ws

    for spec in TILE_SPECS:
        tile_blob(spec[0], spec[1], spec[2], spec[3], spec[4], spec[5], 0)
    tile_set[1] = list(tile_set[0])          # indoors starts as the outdoors set
    for spec in TILE_SPECS_IN:
        tile_blob(spec[0], spec[1], spec[2], spec[3], spec[4], spec[5], 1)

    # ---- what the maps can reach: pool the pictures, drop the rest --------
    # tile_set[s][t] is the words for that tile in that set (set 1 started as a
    # copy of set 0, so a tile the interior set never overrides is the *same*
    # picture -- it must not be emitted twice, and a tile no map in that set
    # places must not be emitted at all).
    used = tiles_used()
    tile_pool, tile_pool_src, tile_map = [], [], {0: [], 1: []}
    seen = {}
    for setno in (0, 1):
        for t in range(N_TILES):
            ws = tile_set[setno][t]
            if ws is None or (setno, t) not in used:
                tile_map[setno].append(255)
                if ws is not None:
                    dropped.append("set %d tile %d" % (setno, t))
                continue
            key = tuple(ws)
            if key not in seen:
                seen[key] = len(tile_pool)
                tile_pool.append(ws)
                tile_pool_src.append("set %d tile %d" % (setno, t))
            tile_map[setno].append(seen[key])
    # ... and take those blobs back out of the picture list
    blobs[:] = [b for b in blobs if not b[0].startswith("art_tile_")]

    # -------------------------------------------------------------- logo ----
    # stretched, not contained: at 48x8 cells a pixel-art wordmark has to use
    # every one of them or it is unreadable
    add_hb("art_logo", os.path.join(SRC, "logo.png"), 48, 8, None, 0, 0.20,
           "# generated title logo (POKeMON / FIRE RED wordmark)", "stretch",
           no_bg=True)

    # ------------------------------------------------------------- frame ----
    # The dialogue panel is too thin for the picture itself (a cell is a whole
    # character), so take the frame's *palette* off it and let fb_box draw the
    # panel in those colours.  The interior stays black so text drawn on top
    # with its own background does not come out spotty.
    frame_cols = None
    fp = os.path.join(SRC, "frame.png")
    if os.path.exists(fp):
        fi = Image.open(fp).convert("RGB")
        fx0, fy0, fx1, fy1 = content_box(fi)
        inner = (fx0 + (fx1 - fx0) // 8, fy0 + (fy1 - fy0) // 6,
                 fx1 - (fx1 - fx0) // 8, fy1 - (fy1 - fy0) // 6)
        ins = Counter()
        for y in range(inner[1], inner[3], 3):
            for x in range(inner[0], inner[2], 3):
                ins[fi.getpixel((x, y))] += 1
        inner_c = ins.most_common(1)[0][0]
        # the border is the frame's outer ring, so sample close to the edge
        # and insist on a saturated colour -- otherwise the anti-aliased
        # shadow rows win and the panel comes out grey
        ring = max(4, (fx1 - fx0) // 25)
        bor = Counter()
        for y in range(fy0 + 2, fy1 - 1):
            for x in range(fx0 + 2, fx1 - 1):
                if (fx0 + ring < x < fx1 - ring and
                        fy0 + ring < y < fy1 - ring):
                    continue
                c = fi.getpixel((x, y))
                r, g, b = [v / 255.0 for v in c]
                _, sat, val = colorsys.rgb_to_hsv(r, g, b)
                if sat > 0.35 and val > 0.35:
                    bor[c] += 1
        border_c = bor.most_common(1)[0][0] if bor else (255, 255, 255)
        bidx = nearest(border_c)[0]
        if bidx >= 9:
            bidx -= 8          # the bright twin of the same hue reads better dim
        frame_cols = (bidx, nearest(inner_c)[0])
        print("  frame.png: border %s -> colour %d, interior %s -> colour %d"
              % (border_c, frame_cols[0], inner_c, frame_cols[1]))

    # -------------------------------------------------------- emit asm -----
    n_art = sum(1 for l, _, _, _, _ in blobs if l.startswith("art_big_"))
    with open(ASM, "w") as fh:
        fh.write("# ============================================================ art ===\n")
        fh.write("#  GENERATED by tools/art2cells.py from art_src/*.png -- do not edit.\n")
        fh.write("#  One word = one cell.  Two kinds of blob live here:\n"
                 "#    half block (pictures): idx | (fg<<16) | (bg<<24),\n"
                 "#      idx 1 = top half, 2 = full block, 0 = transparent\n"
                 "#    glyph ramp (map tiles): glyph byte | (fg<<16), 0 = transparent\n")
        fh.write("#  Cells are laid out row-major, width x height words.\n")
        fh.write("# ===========================================================================\n")
        fh.write(".intel_syntax noprefix\n\n.section .rodata\n")
        for label, ws, tw, th, header in blobs:
            fh.write("\n%s\n.globl %s\n%s:\n" % (header, label, label))
            for i in range(0, len(ws), 10):
                fh.write("    .long " + ",".join("0x%06x" % w for w in ws[i:i + 10]) + "\n")
        fh.write("\n# ---- directory -------------------------------------------------\n")
        fh.write(".globl art_big_w, art_big_h, art_sml_w, art_sml_h\n")
        fh.write(".globl art_title_w, art_title_h, art_n_species\n")
        fh.write(".globl art_big_tbl, art_sml_tbl\n")
        fh.write(".globl art_bg_w, art_bg_h, art_bg_tbl\n")
        fh.write("art_title_w: .byte %d\n" % (80 if any(l == 'art_title' for l, *_ in blobs) else 0))
        fh.write("art_title_h: .byte %d\n" % (24 if any(l == 'art_title' for l, *_ in blobs) else 0))
        fh.write("art_big_w:   .byte 12\nart_big_h:   .byte 8\n")
        fh.write("art_sml_w:   .byte 12\nart_sml_h:   .byte 5\n")
        fh.write("art_n_species: .byte %d\n" % n_art)
        fh.write("\n.section .rodata\n")
        fh.write("art_big_tbl:\n")
        for i in range(n_art):
            fh.write("    .quad art_big_%d\n" % i)
        fh.write("art_sml_tbl:\n")
        for i in range(n_art):
            fh.write("    .quad art_sml_%d\n" % i)
        fh.write("\n# ---- map tiles -------------------------------------------------\n"
                 "# A tileset holds the tiles its maps place, not every tile\n"
                 "# that exists: art_tile_map says which picture set S tile T\n"
                 "# wants (255 = this set cannot place this tile), and the\n"
                 "# pictures themselves are pooled, so two sets that draw a\n"
                 "# tile the same way share one copy.  Everything below is\n"
                 "# reachable; nothing here is art the game never draws.\n")
        fh.write(".globl art_tiles, art_tiles_per_set, art_tile_map\n")
        fh.write("art_tiles_per_set: .byte %d\n" % N_TILES)
        fh.write("art_tiles:\n")
        for i, ws in enumerate(tile_pool):
            fh.write("    # blob %d: %s\n" % (i, tile_pool_src[i]))
            fh.write("    .long " + ",".join("0x%06x" % x for x in ws) + "\n")
        fh.write("art_tile_map:\n")
        for setno in (0, 1):
            row = tile_map[setno]
            fh.write("    .byte " + ",".join(str(v) for v in row) + "\n")
        n_bg = sum(1 for l, _, _, _, _ in blobs if l.startswith("art_bg_"))
        if n_bg:
            fh.write("art_bg_w: .byte %d\nart_bg_h: .byte %d\n" % (BG_W, BG_H))
            fh.write("art_bg_tbl:\n")
            for i in range(n_bg):
                fh.write("    .quad art_bg_%d\n" % i)
        if frame_cols:
            fh.write("\n# ---- panel colours lifted from art_src/frame.png -----\n")
            fh.write(".globl art_frame_border, art_frame_inner\n")
            fh.write("art_frame_border: .byte %d\n" % frame_cols[0])
            fh.write("art_frame_inner:  .byte %d\n" % frame_cols[1])
        fh.write("\n.section .text\n# vim: sw=4 ts=4\n")
    if frame_cols:
        patch_defs(frame_cols[0])
    print("wrote %s (%d words in %d pooled tile pictures, %d species with art)"
          % (ASM, sum(len(w) for w in tile_pool), len(tile_pool), n_art))
    if dropped:
        print("  dropped %d tile pictures no map can reach: %s"
              % (len(dropped), ", ".join(dropped)))


if __name__ == "__main__":
    main()
