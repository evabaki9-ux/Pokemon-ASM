#!/usr/bin/env python3
"""
tools/make_screens.py -- build docs/screens.html out of docs/shots/*.png.

Every picture is inlined as a data URI, so the page is one file that works
offline and from a plain checkout.  Regenerate it whenever the art or a screen
changes:

    python3 tools/ptyrender.py docs/shots/route2.png --scenario shot_route2 --quickstart
    python3 tools/make_screens.py
"""
import base64
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "docs", "shots")
DOCS = os.path.join(ROOT, "docs")
OUT = os.path.join(ROOT, "docs", "screens.html")

# (section title, [(shot file, caption)])
SECTIONS = [
    ("Screens", [
        ("title_hb.png", "The title screen: generated art drawn as pixels. The "
                         "wordmark is sampled the same way the creatures are."),
        ("starter_hb.png", "Prof. Oak's table: three starters, each from its own "
                           "generated picture at 12x8 cells (12x16 pixels)."),
        ("battle_hb.png", "A wild battle on ROUTE 1: the backdrop is generated "
                          "art dimmed to 34%, the combatants are pixel sprites."),
        ("intro.png", "Oak's introduction. Text still uses the character cell it "
                      "always did -- the pictures sit next to it."),
    ]),
    ("The world", [
        ("pallet.png", "PALLET TOWN: houses, the cross street, the ponds and the "
                       "tall grass on the west side."),
        ("route2.png", "ROUTE 2, the lake route: sand, a pier out over the water, "
                       "a fenced look-out and the ridge with GRANITE CAVE."),
        ("cave.png", "Inside GRANITE CAVE: boulders for walls, stone floor for the "
                     "encounters, and a hiker's camp (PC, shelf, bedroll, rug)."),
        ("house.png", "RED's HOUSE: the interior tileset from tiles_in.png -- "
                      "wall, floor, bookshelf, TV, bed, rug, and MOM."),
        ("center.png", "The POKeMON CENTER, the other indoor map: counter, healing "
                       "machines and the NURSE."),
    ]),
    ("The new ground is reachable", [
        ("battle_magikarp.png", "Step off the pier onto the lake and MAGIKARP is "
                                "what the water encounter table holds."),
        ("battle_geodude.png", "Walk onto the cave floor and it is GEODUDE. Both "
                               "are art that used to be unreachable."),
    ]),
    ("Where the pixels come from", [
        ("src_logo.png", "art_src/logo.png -- the generated wordmark."),
        ("src_tiles_out.png", "art_src/tiles_out.png -- the outdoor sheet the map "
                              "tiles are cut from."),
        ("src_tiles_in.png", "art_src/tiles_in.png -- the indoor sheet: furniture "
                             "and room blocks."),
        ("bg_field.png", "art_src/bg_field.png, dimmed, becomes the battle "
                         "backdrop."),
    ]),
]

HOW = """
<h2>How a picture becomes pixels</h2>
<ol>
<li>Every picture is AI-generated Game Boy Advance style pixel art in <code>art_src/</code>.</li>
<li><code>tools/art2cells.py</code> samples it onto the terminal's cell grid and quantises every sample to
the 16-colour ANSI palette, so nothing is averaged into mud.</li>
<li>A picture cell is drawn as a <i>half block</i>: one word per cell carries a foreground colour for the
top half of the cell and a background colour for the bottom half, so one cell is two square pixels.</li>
<li>Map tiles are the deliberate exception: a tile only gets 2x2 cells, which as pixels is a 2x4 picture,
and at that size every tile collapses into a flat colour field. The tiles keep the glyph ramp, which
carries texture that eight pixels cannot.</li>
<li>The tileset table is sparse. <code>art_tile_map</code> names the pooled picture each (set, tile) pair
uses, and only pictures that some map can actually draw are emitted at all -- nothing in
<code>src/art.s</code> is art the game never shows.</li>
</ol>
"""


def data_uri(name):
    for d in (SHOTS, DOCS, os.path.join(ROOT, "art_src")):
        path = os.path.join(d, name)
        if os.path.exists(path):
            break
    else:
        return None
    with open(path, "rb") as fh:
        return "data:image/png;base64," + base64.b64encode(fh.read()).decode()


def n_tests():
    path = os.path.join(ROOT, "tests", "run_tests.py")
    with open(path) as fh:
        return len([l for l in fh if l.strip().startswith("Case(")])


def main():
    out = ['<!doctype html>', '<meta charset="utf-8">',
           '<title>FIRE RED, ASM EDITION &mdash; pixel art in a terminal</title>',
           '<style>pre{background:#101019;border:1px solid #262636;border-radius:8px;'
           'padding:14px;overflow-x:auto;color:#9ee0a0;font-size:12px;line-height:1.25}</style>',
           '<div class="wrap">', '<h1>FIRE RED, ASM EDITION</h1>',
           '<p class="sub">A Pok&eacute;mon FireRed-like game written in x86-64 assembly: no libc, no '
           'engine, raw syscalls. Every picture is AI-generated Game Boy Advance style pixel art, drawn as '
           '<i>pixels</i> rather than characters &mdash; each cell carries two colours, foreground on top '
           'and background below, so a cell is two square pixels.</p>']
    missing, shown = [], 0
    for title, shots in SECTIONS:
        out.append("<h2>%s</h2>" % title)
        for name, cap in shots:
            uri = data_uri(name)
            if uri is None:
                missing.append(name)
                continue
            shown += 1
            out.append('<figure><img alt="%s" src="%s"><figcaption>%s</figcaption></figure>'
                       % (cap, uri, cap))
    out.append(HOW)
    out.append('<p class="sub"><code>make art</code> regenerates the tables, <code>make test</code> runs '
               'the %d headless playthroughs, <code>make tour</code> re-dumps the walkthrough. Every '
               'screenshot here is a real frame from the actual binary, rendered through the same ANSI '
               'palette the game emits.</p>' % n_tests())
    out.append("</div>")
    out.append("""<style>
 body{margin:0;background:#0b0b12;color:#e8e8f0;font:16px/1.55 -apple-system,Segoe UI,Roboto,sans-serif}
 .wrap{max-width:1100px;margin:0 auto;padding:32px 20px 60px}
 h1{font-size:30px;letter-spacing:.04em;margin:0 0 6px}
 h2{font-size:20px;margin:38px 0 10px;color:#ffd75e}
 p.sub{color:#a8a8be}
 figure{margin:0 0 26px;background:#15151f;border:1px solid #262636;border-radius:10px;padding:14px}
 img{width:100%;image-rendering:pixelated;display:block;border-radius:6px}
 figcaption{margin-top:10px;color:#c9c9dd;font-size:14px}
 code{background:#1d1d29;padding:1px 5px;border-radius:4px}
 ol{color:#c9c9dd}
</style>""")
    with open(OUT, "w") as fh:
        fh.write("\n".join(out) + "\n")
    print("wrote %s (%d shots%s)"
          % (os.path.relpath(OUT, ROOT), shown,
             "" if not missing else ", missing: " + ", ".join(missing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
