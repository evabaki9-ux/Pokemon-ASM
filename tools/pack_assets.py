#!/usr/bin/env python3
"""
tools/pack_assets.py -- pack the generated art into frontend/assets.bin.

The graphical front-end (frontend/main.c, built as ./pokemon-gui) draws the
real pictures instead of terminal characters, but it must not depend on a PNG
decoder or on any library beyond SDL2.  So every picture is quantised to the
game's own 16 colours here, at build time, and written as one byte per pixel:

    u32 magic "PKAR"      u32 version
    u32 tiles_per_set     u32 n_sets
    u32 n_species         u32 n_backdrops
    u32 font_w font_h     u32 cell_w cell_h
    u32 screen_w screen_h
    u8  palette[16][3]
    u8  font[95][font_w*font_h]            coverage, ASCII 32..126
    for each set:  for each tile:
        u8  present
        u32 words[4]                       the glyph/fg/bg signature per cell
        u8  px[32*32]                      palette index, 255 = transparent
    for each species:
        u8  name_len, char name[]
        u8  px[96*96]
    for each backdrop: u8 px[screen_w*screen_h]

Everything is little-endian and packed with no padding, so the C side can
walk it with a cursor.

    python3 tools/pack_assets.py            # writes frontend/assets.bin
"""
import os
import re
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import art2cells as A                                    # noqa: E402

OUT = os.path.join(ROOT, "frontend", "assets.bin")
CELL_W, CELL_H = 16, 16                                  # one terminal cell
TILE_PX = 2 * CELL_W                                     # a map tile is 2x2 cells
SPECIES_PX = 96
FONT_W, FONT_H = 8, 16
FONT_FILES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]


def die(msg):
    print("pack_assets: " + msg)
    sys.exit(1)


# --------------------------------------------------------------- art.s ------
def read_tile_table():
    """(set, tile) -> words, straight out of the generated assembly.

    The pooling in art.s means two tiles that draw the same picture share one
    blob; the comment on each blob says which (set, tile) it was made from, so
    the pool can be walked backwards."""
    src = open(os.path.join(ROOT, "src", "art.s"), encoding="utf-8").read()
    per_set = int(re.search(r"art_tiles_per_set: \.byte (\d+)", src).group(1))
    tbl = re.search(r"art_tile_map:\n((?:\s+\.byte[^\n]*\n)+)", src).group(1)
    pool_of = [int(x) for x in re.findall(r"\d+", tbl)]
    seg = src.split("art_tiles:")[1].split("art_tile_map:")[0]
    pool = {}
    for m in re.finditer(r"# blob (\d+): (set \d+ tile \d+)\n(.*?)(?=\n    # blob|\Z)",
                         seg, re.S):
        ws = [int(x, 16) for x in
              re.findall(r"0x([0-9a-fA-F]{1,8})", m.group(3))]
        if ws:
            pool[int(m.group(1))] = ws
    out = {}
    for setno in (0, 1):
        for t in range(per_set):
            p = pool_of[setno * per_set + t]
            out[(setno, t)] = None if p == 255 else pool.get(p)
    return per_set, out


# --------------------------------------------------------------- images -----
def tile_images(per_set):
    """(set, tile) -> 32x32 RGB image, built the way art2cells builds them."""
    cache = {}

    def sheet(name):
        if name not in cache:
            cache[name] = Image.open(os.path.join(A.SRC, name)).convert("RGB")
        return cache[name]

    def block_image(sheet_name, idx, base):
        im = sheet(sheet_name)
        if base:
            im = A.compose(sheet(base[0]), base[0], base[1], im, sheet_name, idx)
            return im.crop((0, 0, im.width, im.height))
        return im.crop(A.block_rect(im, sheet_name, idx))

    images = {}
    specs0 = {s[0]: s for s in A.TILE_SPECS}
    for t in range(per_set):
        s = specs0.get(t)
        if not s:
            continue
        _, sheet_name, block, base, _cap, _g = s
        images[(0, t)] = block_image(sheet_name, block, base)
    for t in range(per_set):
        images[(1, t)] = images.get((0, t))
    for s in A.TILE_SPECS_IN:
        idx, sheet_name, block, base, _cap, _g = s
        images[(1, idx)] = block_image(sheet_name, block, base)
    return images


def quantise(im, size, transparent=False):
    """-> bytes of palette indices, one per pixel."""
    im = im.convert("RGB").resize((size, size), Image.LANCZOS)
    px = im.load()
    out = bytearray()
    for y in range(size):
        for x in range(size):
            c = px[x, y]
            idx = A.nearest(c)[0]
            if transparent and sum(c) < 40:
                idx = 255
            out.append(idx)
    return bytes(out)


def species_cutout(path, size):
    """A creature picture, cut out and scaled to fill `size`.

    The generated PNGs are drawn on a flat background with a wide margin, so
    scaling the whole sheet down leaves the creature small in the middle of a
    big transparent field.  Take the border colour as the background, drop
    everything within tolerance of it, crop to what is left, then scale that to
    fill the canvas with a small margin."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    edge = {}
    for x in range(w):
        for y in (0, h - 1):
            edge[px[x, y]] = edge.get(px[x, y], 0) + 1
    for y in range(h):
        for x in (0, w - 1):
            edge[px[x, y]] = edge.get(px[x, y], 0) + 1
    bg = max(edge.items(), key=lambda kv: kv[1])[0]

    mask = Image.new("L", (w, h), 0)
    mp = mask.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) > 60:
                mp[x, y] = 255
    box = mask.getbbox()
    if not box:
        box = (0, 0, w, h)
    im = im.crop(box)

    room = size - 6
    r = min(room / float(im.width), room / float(im.height))
    im = im.resize((max(1, int(im.width * r)), max(1, int(im.height * r))),
                   Image.LANCZOS)
    canvas = Image.new("RGB", (size, size), bg)
    canvas.paste(im, ((size - im.width) // 2, (size - im.height) // 2))
    return quantise_cutout(canvas)


def quantise_cutout(im):
    """A creature picture on a transparent background.

    The generated PNGs are drawn on a flat light background.  In the terminal
    build that background was simply "nothing to draw"; here it becomes palette
    index 255 (transparent) so the battle backdrop shows through."""
    px = im.load()
    w, h = im.size
    corners = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    out = bytearray()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) < 70:
                out.append(255)
            else:
                out.append(A.nearest(c)[0])
    return bytes(out)


# Tiles that are *ground*: their texture should be a shade of their own
# colour (darker ground, lighter stone), not the contrasting colour the
# terminal build used -- at 16 pixels a cell that contrast reads as noise.
TERRAIN_TILES = {0, 1, 2, 3, 4, 5, 12, 14, 15, 16, 17, 22, 27, 28, 30, 31}

def shade_of(base):
    """a palette entry that reads as this colour, darker or lighter"""
    r, g, b = PALETTE[base]
    lum = (r * 0.3 + g * 0.59 + b * 0.11) / 255.0
    return 8 if lum > 0.35 else 7


def draw_tile(im, words, tile_no=None):
    """One map tile at 32x32: the generated block art, with the tile's texture
    drawn into it.

    In the terminal a tile's texture was a whole character in a 2x2 cell --
    fine at that size, but blown up to 16x16 pixels a character is a huge blob.
    So the base comes from the generated block (which is what the tile is made
    of) and the texture marks are redrawn small, in the tile's own feature
    colour, from the same glyphs the terminal build used."""
    base = quantise_tile(im, words)                   # 32*32 indices
    px = Image.frombytes("L", (TILE_PX, TILE_PX), base)
    rgbim = Image.new("RGB", (TILE_PX, TILE_PX))
    rgbim.putdata([PALETTE[v] if v < 255 else (0, 0, 0)
                   for v in px.getdata()])
    font_path = next((f for f in FONT_FILES if os.path.exists(f)), None)
    font = ImageFont.truetype(font_path, 11) if font_path else None
    tile_base = (words[0] >> 24) & 0x0f
    soft = tile_no in TERRAIN_TILES if tile_no is not None else False
    for cell in range(4):
        w = words[cell]
        glyph, feat = w & 0xff, (w >> 16) & 0x0f
        if glyph < 32 or glyph == 0:
            continue
        cx = (cell % 2) * CELL_W
        cy = (cell // 2) * CELL_H
        mask = Image.new("L", (CELL_W, CELL_H), 0)
        md = ImageDraw.Draw(mask)
        if font:
            bb = md.textbbox((0, 0), chr(glyph), font=font)
            md.text(((CELL_W - (bb[2] - bb[0])) // 2 - bb[0],
                     (CELL_H - (bb[3] - bb[1])) // 2 - bb[1]),
                    chr(glyph), fill=255, font=font)
        else:
            md.point((CELL_W // 2, CELL_H // 2), fill=255)
        if soft:
            feat = shade_of(tile_base)
        rgbim.paste(PALETTE[feat], (cx, cy), mask)
    out = bytearray()
    for c in rgbim.getdata():
        out.append(A.nearest(c)[0])
    return bytes(out)


def quantise_tile(im, words):
    """A tile picture, the way the terminal blitter draws it.

    The sheet blocks sit on a flat background colour.  In the terminal that
    background was never part of the picture: the cell's *base* colour came
    from the tile itself.  Do the same here -- a pixel that is the block's
    background becomes the tile's base palette entry, and only the subject
    keeps its own colour."""
    im = im.convert("RGB").resize((TILE_PX, TILE_PX), Image.LANCZOS)
    px = im.load()
    base = (words[0] >> 24) & 0x0f
    w, h = im.size
    corners = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    out = bytearray()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) < 60:
                out.append(base)
            else:
                out.append(A.nearest(c)[0])
    return bytes(out)


def fit(image_path, w, h, bg=(0, 0, 0), mode="contain"):
    """scale a picture to w x h.

    A full screen picture (the title scene, a battle backdrop) uses "cover":
    scale it up until it fills both dimensions, then centre-crop, so the screen
    is never letterboxed with black bars.  A creature uses "contain", so the
    whole creature is visible."""
    im = Image.open(image_path).convert("RGB")
    if mode == "cover":
        r = max(w / float(im.width), h / float(im.height))
        nw, nh = max(1, int(im.width * r)), max(1, int(im.height * r))
        im = im.resize((nw, nh), Image.LANCZOS)
        return im.crop(((nw - w) // 2, (nh - h) // 2,
                        (nw - w) // 2 + w, (nh - h) // 2 + h))
    r = min(w / float(im.width), h / float(im.height))
    nw, nh = max(1, int(im.width * r)), max(1, int(im.height * r))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (w, h), bg)
    canvas.paste(im, ((w - nw) // 2, (h - nh) // 2))
    return canvas


def font_bitmap():
    path = next((f for f in FONT_FILES if os.path.exists(f)), None)
    if not path:
        die("no monospace font found for the bitmap font")
    f = ImageFont.truetype(path, 13)
    out = bytearray()
    for code in range(32, 127):
        im = Image.new("L", (FONT_W, FONT_H), 0)
        d = ImageDraw.Draw(im)
        ch = chr(code)
        bb = d.textbbox((0, 0), ch, font=f)
        x = (FONT_W - (bb[2] - bb[0])) // 2 - bb[0]
        y = (FONT_H - (bb[3] - bb[1])) // 2 - bb[1]
        d.text((x, y), ch, fill=255, font=f)
        out.extend(im.tobytes())
    return bytes(out)


def species_list():
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import gen_data                                       # noqa: E402
    return [(s[0], s[1]) for s in gen_data.SPECIES]        # (name, sprite)


PALETTE = [(0, 0, 0), (0xaa, 0, 0), (0, 0xaa, 0), (0xaa, 0x55, 0),
           (0, 0, 0xaa), (0xaa, 0, 0xaa), (0, 0xaa, 0xaa), (0xaa, 0xaa, 0xaa),
           (0x55, 0x55, 0x55), (0xff, 0x55, 0x55), (0x55, 0xff, 0x55),
           (0xff, 0xff, 0x55), (0x55, 0x55, 0xff), (0xff, 0x55, 0xff),
           (0x55, 0xff, 0xff), (0xff, 0xff, 0xff)]


def main():
    per_set, table = read_tile_table()
    timgs = tile_images(per_set)
    species = species_list()

    body = bytearray()

    def u32(v):
        body.extend(struct.pack("<I", v))

    def u8(v):
        body.append(v & 0xff)

    # ---- header -----------------------------------------------------------
    for c in b"PKAR":
        u8(c)
    u32(1)
    u32(per_set)
    u32(2)
    u32(len(species))
    u32(3)                                   # full screen pictures
    u32(FONT_W)
    u32(FONT_H)
    u32(CELL_W)
    u32(CELL_H)
    u32(80 * CELL_W)
    u32(24 * CELL_H)

    for r, g, b in PALETTE:
        u8(r)
        u8(g)
        u8(b)

    body.extend(font_bitmap())

    # ---- map tiles --------------------------------------------------------
    n_pictures = 0
    for setno in (0, 1):
        for t in range(per_set):
            words = table.get((setno, t))
            img = timgs.get((setno, t))
            if not words or img is None:
                u8(0)
                body.extend(b"\0" * 16)
                body.extend(b"\xff" * (TILE_PX * TILE_PX))
                continue
            n_pictures += 1
            u8(1)
            for w in words[:4]:
                u32(w)
            body.extend(draw_tile(img, words, t))

    # ---- species ---------------------------------------------------------
    for name, sprite in species:
        nb = os.path.join(ROOT, "art_src", sprite + ".png")
        if not os.path.exists(nb):
            die("missing species art %s for %s" % (nb, name))
        nm = name.encode("ascii")
        u8(len(nm))
        body.extend(nm)
        body.extend(species_cutout(nb, SPECIES_PX))

    # ---- backdrops -------------------------------------------------------
    # a backdrop is the whole screen, not a square: scale to fit, then
    # quantise through a helper that takes width and height
    for name, src in (("title", "title.png"), ("field", "bg_field.png"),
                      ("city", "bg_city.png")):
        p = os.path.join(ROOT, "art_src", src)
        if not os.path.exists(p):
            p = os.path.join(ROOT, "docs", src)
        if not os.path.exists(p):
            die("missing backdrop %s" % src)
        w, h = 80 * CELL_W, 24 * CELL_H
        px = fit(p, w, h, mode="cover").load()
        for y in range(h):
            for x in range(w):
                u8(A.nearest(px[x, y])[0])

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as fh:
        fh.write(body)
    print("wrote %s: %d tile pictures, %d species, 3 full screen pictures, %d bytes"
          % (os.path.relpath(OUT, ROOT), n_pictures, len(species), len(body)))


if __name__ == "__main__":
    main()
