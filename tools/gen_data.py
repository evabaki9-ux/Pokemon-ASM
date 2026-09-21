#!/usr/bin/env python3
"""
gen_data.py -- generates src/data.s for POKEMON ASM EDITION.

Validates sprite widths and map rows, then emits: UTF-8 sprite art, species
stats, the Gen-3 type chart, move table, maps (tiles + entities + warps) and
all dialogue.  Run:  python3 tools/gen_data.py > src/data.s
"""
import sys, re

SPR_W, SPR_H = 10, 5
ITEMS = [("POTION","Heals 20 HP."),("POKe BALL","Catches wild POKeMON.")]
ITEM_ID = {n: i for i, (n, d) in enumerate(ITEMS)}

def die(msg):
    sys.exit("FATAL: " + msg)

# ============================================================== SPRITES =====
# (colour, [SPR_H lines of exactly SPR_W glyphs])
SPRITES = {
 "charmander": ("C_BRED", [
    "   ___   ^",
    "  / o \\ /|",
    " <  w  > |",
    "  \\___/ \\|",
    "  /| |\\  v"]),
 "bulbasaur": ("C_BGREEN", [
    "  _#_",
    " / o \\",
    "<  w  >",
    " \\___/",
    " /| |\\"]),
 "squirtle": ("C_BCYAN", [
    "   ___",
    "  / o \\",
    " <  w  >",
    "  \\___/",
    "   '''"]),
 "pidgey": ("C_BWHITE", [
    "   __",
    "  /  \\",
    " < o o >",
    "  \\__/",
    "   /\\"]),
 "rattata": ("C_BMAGENTA", [
    "  /\\_/\\",
    " < o o >",
    "  \\_w_/",
    "   | |",
    "  ^   ^"]),
 "oddish": ("C_BGREEN", [
    "   @@@",
    "  @ o @",
    "  @@@@",
    "   | |",
    "  ^^ ^^"]),
 "meowth": ("C_BYELLOW", [
    "  /\\_/\\",
    " ( o o )",
    "  \\ w /",
    "  /| |\\",
    "  ^   ^"]),
 "pikachu": ("C_BYELLOW", [
    "  /\\_/\\",
    " < ^ ^ >",
    "  \\ w /",
    "  /| |\\",
    "  ^   ^"]),
 "magikarp": ("C_BRED", [
    "  __",
    " / o \\",
    "<  w  >",
    " \\__/",
    " /  \\"]),
 "geodude": ("C_GRAY", [
    "  ,---,",
    " ( o o )",
    "  \\___/",
    " /|   |\\",
    "  ^   ^"]),
}

def check_sprite(name, lines):
    out = []
    for i, ln in enumerate(lines):
        if len(ln) > SPR_W:
            die(f"sprite {name} line {i} is {len(ln)} glyphs wide: {ln!r}")
        out.append(ln + " " * (SPR_W - len(ln)))
    while len(out) < SPR_H:
        out.append(" " * SPR_W)
    return out

# ============================================================== SPECIES =====
# name, sprite, hp, atk, def, spd, t1, t2, catch, yield, moves
# name, sprite, hp, atk, def, spd, type1, type2, catch, xp yield, moves,
# evolves into (index into SPECIES or None), evolves at level
SPECIES = [
 ("CHARMANDER","charmander",39,52,43,65,"T_FIRE","T_FIRE",   45,62,["SCRATCH","GROWL","EMBER","QUICK_ATTACK"],"CHARMELEON",16),
 ("BULBASAUR", "bulbasaur", 45,49,49,45,"T_GRASS","T_POISON",45,64,["TACKLE","GROWL","VINE_WHIP","POISON_STING"],"IVYSAUR",16),
 ("SQUIRTLE",  "squirtle",  44,48,65,43,"T_WATER","T_WATER", 45,63,["TACKLE","TAIL_WHIP","WATER_GUN","BITE"],"WARTORTLE",16),
 ("PIDGEY",    "pidgey",    40,45,40,56,"T_NORMAL","T_FLYING",255,50,["GUST","QUICK_ATTACK","TACKLE","GROWL"],"PIDGEOTTO",18),
 ("RATTATA",   "rattata",   30,56,35,72,"T_NORMAL","T_NORMAL",255,51,["TACKLE","TAIL_WHIP","QUICK_ATTACK","BITE"],None,0),
 ("ODDISH",    "oddish",    45,50,55,30,"T_GRASS","T_POISON",255,52,["POISON_STING","VINE_WHIP","GROWL","TACKLE"],None,0),
 ("MEOWTH",    "meowth",    40,45,35,90,"T_NORMAL","T_NORMAL",255,58,["SCRATCH","GROWL","BITE","QUICK_ATTACK"],None,0),
 ("PIKACHU",   "pikachu",   35,55,40,90,"T_ELECTR","T_ELECTR",190,82,["THUNDERSHOCK","QUICK_ATTACK","TAIL_WHIP","TACKLE"],None,0),
 ("MAGIKARP",  "magikarp",  20,10,55,80,"T_WATER","T_WATER", 255,40,["TACKLE"],None,0),
 ("GEODUDE",   "geodude",   40,80,100,20,"T_ROCK","T_GROUND",255,60,["ROCK_THROW","TACKLE","TAIL_WHIP","BITE"],None,0),
 # ---- evolved forms: reached by levelling up, not found in the tall grass --
 ("CHARMELEON","charmander",58,64,58,80,"T_FIRE","T_FIRE",   45,142,["EMBER","SCRATCH","GROWL","BITE"],None,0),
 ("IVYSAUR",   "bulbasaur", 60,62,63,60,"T_GRASS","T_POISON",45,141,["VINE_WHIP","TACKLE","POISON_STING","GROWL"],None,0),
 ("WARTORTLE", "squirtle",  59,63,80,58,"T_WATER","T_WATER", 45,143,["WATER_GUN","TACKLE","BITE","TAIL_WHIP"],None,0),
 ("PIDGEOTTO", "pidgey",    63,60,55,71,"T_NORMAL","T_FLYING",120,113,["GUST","QUICK_ATTACK","TACKLE","GROWL"],None,0),
]
SPEC_ID = {s[0]: i for i, s in enumerate(SPECIES)}

# move: name, power(0=status), type, effect, pp
# effect: 0 none 1 atk-down 2 def-down 3 heal 4 recoil 5 priority 6 poison
MOVES = [
 ("TACKLE",       35,"T_NORMAL",0,35),
 ("SCRATCH",      40,"T_NORMAL",0,35),
 ("EMBER",        40,"T_FIRE",  0,25),
 ("VINE_WHIP",    45,"T_GRASS", 0,25),
 ("WATER_GUN",    40,"T_WATER", 0,25),
 ("THUNDERSHOCK", 40,"T_ELECTR",6,30),
 ("GUST",         40,"T_FLYING",0,35),
 ("BITE",         55,"T_NORMAL",0,25),
 ("QUICK_ATTACK", 35,"T_NORMAL",5,30),
 ("GROWL",         0,"T_NORMAL",1,40),
 ("TAIL_WHIP",     0,"T_NORMAL",2,30),
 ("RECOVER",       0,"T_NORMAL",3,20),
 ("ROCK_THROW",   50,"T_ROCK",  0,15),
 ("POISON_STING", 30,"T_POISON",6,35),
]
MOVE_ID = {m[0]: i for i, m in enumerate(MOVES)}

# ============================================================ TYPE CHART ====
TYPES = ["T_NORMAL","T_FIRE","T_WATER","T_GRASS","T_ELECTR",
         "T_POISON","T_FLYING","T_BUG","T_ROCK","T_GROUND"]
def M(x):  # nibble = mult*4
    return {0.0:0, 0.5:2, 1.0:4, 2.0:8}[x]
#              NOR FIR WAT GRA ELE POI FLY BUG ROC GRO
CHART = [
 [M(1),M(1),  M(1),  M(1),  M(1),  M(1),  M(1),  M(1),  M(.5),M(1)],   # NORMAL
 [M(1),M(.5), M(.5), M(2),  M(1),  M(1),  M(1),  M(2),  M(.5),M(1)],   # FIRE
 [M(1),M(2),  M(.5), M(.5), M(1),  M(1),  M(1),  M(1),  M(2), M(2)],   # WATER
 [M(1),M(.5), M(2),  M(.5), M(1),  M(.5), M(.5), M(.5), M(2), M(2)],   # GRASS
 [M(1),M(1),  M(2),  M(.5), M(.5), M(1),  M(2),  M(1),  M(1), M(0)],   # ELECTR
 [M(1),M(1),  M(1),  M(2),  M(1),  M(.5), M(1),  M(1),  M(.5),M(.5)],  # POISON
 [M(1),M(1),  M(1),  M(2),  M(.5), M(1),  M(1),  M(2),  M(.5),M(1)],   # FLYING
 [M(1),M(.5), M(1),  M(2),  M(1),  M(.5), M(.5), M(1),  M(.5),M(1)],   # BUG
 [M(1),M(2),  M(1),  M(1),  M(1),  M(1),  M(2),  M(2),  M(1), M(.5)],  # ROCK
 [M(1),M(2),  M(1),  M(.5), M(2),  M(2),  M(0),  M(.5), M(2), M(1)],   # GROUND
]
TYPE_COL = {"T_NORMAL":"C_GRAY","T_FIRE":"C_RED","T_WATER":"C_CYAN","T_GRASS":"C_GREEN",
            "T_ELECTR":"C_BYELLOW","T_POISON":"C_MAGENTA","T_FLYING":"C_BWHITE",
            "T_BUG":"C_GREEN","T_ROCK":"C_YELLOW","T_GROUND":"C_YELLOW"}

# ================================================================= MAPS =====
# Maps are built programmatically: a grid of tile characters.  Every map is
# 40+ tiles wide (2 chars each -> the viewport is 40x8 tiles).
#
#   .  grass      ,  tall grass   #  tree       W  wall        L  floor
#   ~  water      R  roof         D  door       C  counter     $  sign
#   *  item ball  F  flower       :  dirt path  P  player spawn

KEEPX = 0xFE        # link: keep the player's x    (vertical transitions)
KEEPY = 0xFE        # link: keep the player's y    (horizontal transitions)


def M(w, h, ch="."):
    return [[ch] * w for _ in range(h)]


def rect(m, x0, y0, x1, y1, ch):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            m[y][x] = ch


def put(m, x, y, ch):
    m[y][x] = ch


def house(m, x, y, w=8, dch="D"):
    """4-row house: three roof rows then a wall row with one door."""
    for yy in range(y, y + 3):
        for xx in range(x, x + w):
            m[yy][xx] = "R"
    for xx in range(x, x + w):
        m[y + 3][xx] = "R"
    m[y + 3][x + w // 2] = dch
    return (x + w // 2, y + 3)


def rows_of(m):
    return ["".join(r) for r in m]


# ----------------------------------------------------------- PALLET TOWN ----
def build_pallet():
    m = M(40, 24)
    rect(m, 0, 0, 39, 0, "#")
    rect(m, 0, 1, 39, 1, "#")
    rect(m, 0, 23, 39, 23, "#")
    rect(m, 0, 0, 0, 23, "#")
    rect(m, 39, 0, 39, 23, "#")
    rect(m, 18, 0, 21, 1, ".")                 # north gate to ROUTE 1
    house(m, 6, 4)                             # RED's house   (door 10,7)
    house(m, 26, 4)                            # friend's house (door 30,7)
    rect(m, 19, 2, 20, 22, ":")                # main street (N-S)
    rect(m, 10, 11, 30, 12, ":")               # cross street (E-W)
    rect(m, 2, 15, 9, 20, ",")                 # tall grass west
    rect(m, 30, 15, 37, 20, ",")               # tall grass east
    rect(m, 14, 20, 25, 22, "~")               # pond
    for (x, y) in [(13, 14), (26, 14), (5, 9), (34, 9), (16, 5), (23, 5)]:
        put(m, x, y, "F")
    put(m, 8, 13, "*")                         # POTION on the grass
    put(m, 21, 2, "$")                         # town sign by the north gate
    put(m, 14, 9, "$")                         # house sign
    put(m, 17, 10, "N")                        # PROF. OAK

    put(m, 24, 16, "N")                        # KID
    put(m, 19, 10, "P")                        # spawn
    return m


# -------------------------------------------------------------- ROUTE 1 -----
def build_route1():
    m = M(40, 40)
    rect(m, 0, 0, 39, 0, "#")
    rect(m, 0, 39, 39, 39, "#")
    rect(m, 0, 0, 0, 39, "#")
    rect(m, 39, 0, 39, 39, "#")
    rect(m, 18, 0, 21, 0, ".")                 # north gate -> VIRIDIAN
    rect(m, 18, 39, 21, 39, ".")               # south gate -> PALLET
    rect(m, 39, 20, 39, 21, ".")               # east gate -> ROUTE 2 (the lake)
    rect(m, 19, 1, 20, 38, ":")                # the route itself
    rect(m, 8, 20, 31, 21, ":")                # jog in the middle
    rect(m, 3, 6, 10, 12, ",")
    rect(m, 29, 6, 36, 12, ",")
    rect(m, 6, 25, 13, 31, ",")
    rect(m, 26, 25, 33, 31, ",")
    rect(m, 2, 34, 14, 37, "~")                # lake
    rect(m, 13, 15, 16, 18, "#")               # clumps
    rect(m, 24, 15, 27, 18, "#")
    for (x, y) in [(5, 3), (34, 3), (17, 24), (22, 33), (11, 18), (28, 18)]:
        put(m, x, y, "F")
    put(m, 34, 4, "*")                         # POKe BALL
    put(m, 18, 34, "$")                        # route sign
    put(m, 22, 20, "n")                        # YOUNGSTER JOEY (on the path)
    put(m, 16, 28, "N")                        # BUG CATCHER
    return m


# --------------------------------------------------------- VIRIDIAN CITY ----
def build_viridian():
    m = M(48, 32)
    rect(m, 0, 0, 47, 0, "#")
    rect(m, 0, 31, 47, 31, "#")
    rect(m, 0, 0, 0, 31, "#")
    rect(m, 47, 0, 47, 31, "#")
    rect(m, 18, 31, 21, 31, ".")               # south gate -> ROUTE 1
    rect(m, 19, 1, 20, 30, ":")                # main street
    rect(m, 6, 16, 41, 17, ":")                # cross street
    house(m, 8, 5)                             # GUIDE's house   (door 12,8)
    house(m, 34, 5)                            # house           (door 38,8)
    house(m, 22, 9)                            # POKeMON CENTER  (door 26,12)
    house(m, 30, 21)                           # mart            (door 34,24)
    rect(m, 30, 3, 40, 6, "~")                 # pond
    rect(m, 2, 26, 10, 30, ",")
    rect(m, 38, 26, 45, 30, ",")
    for (x, y) in [(4, 12), (31, 12), (44, 12), (4, 20), (44, 20)]:
        put(m, x, y, "F")
    put(m, 8, 14, "*")                         # POTION
    put(m, 22, 28, "$")                        # city sign
    put(m, 17, 12, "N")                        # CENTER GUIDE
    put(m, 24, 17, "n")                        # RIVAL on the cross street
    put(m, 32, 20, "N")                        # girl
    return m


# ------------------------------------------------------- POKeMON CENTER -----
def build_center():
    m = M(12, 9, "L")
    rect(m, 0, 0, 11, 0, "W")
    rect(m, 0, 8, 11, 8, "W")
    rect(m, 0, 0, 0, 8, "W")
    rect(m, 11, 0, 11, 8, "W")
    rect(m, 1, 2, 4, 2, "C")                   # counter
    put(m, 2, 1, "M")                          # healing machine
    put(m, 3, 1, "M")
    rect(m, 5, 8, 6, 8, "D")                   # door back outside
    put(m, 3, 4, "N")                          # NURSE
    put(m, 5, 7, "P")                          # arrival tile
    return m


PALLET = rows_of(build_pallet())
ROUTE1 = rows_of(build_route1())
VIRIDIAN = rows_of(build_viridian())
CENTER = rows_of(build_center())

# ------------------------------------------------------------ ROUTE 2 -------
# The lake route east of ROUTE 1: a sand shore, a pier out over the water, a
# fenced look-out, and the GRANITE CAVE mouth in the rocky ridge to the north.
# Water is surfable, so the player walks out onto it and MAGIKARP shows up.
def build_route2():
    m = M(40, 28)
    rect(m, 0, 0, 39, 0, "#")
    rect(m, 0, 27, 39, 27, "#")
    rect(m, 0, 0, 0, 27, "#")
    rect(m, 39, 0, 39, 27, "#")
    rect(m, 0, 20, 0, 21, ".")                  # west gate -> ROUTE 1
    rect(m, 1, 20, 13, 21, ":")                 # road in from the west
    rect(m, 12, 3, 13, 20, ":")                 # north along the shore
    rect(m, 6, 3, 12, 3, ":")                   # ... to the cave mouth
    rect(m, 1, 1, 5, 1, "b")                    # the ridge
    rect(m, 7, 1, 11, 1, "b")
    rect(m, 1, 2, 1, 7, "b")
    rect(m, 2, 5, 5, 7, "r")                    # scree under the ridge
    put(m, 6, 1, "D")                           # GRANITE CAVE
    rect(m, 16, 6, 38, 25, "s")                 # the beach
    rect(m, 19, 9, 36, 23, "~")                 # the lake
    rect(m, 27, 7, 27, 13, ":")                 # a pier out over the water
    rect(m, 16, 6, 16, 12, "f")                 # fence round the look-out
    rect(m, 16, 12, 20, 12, "f")
    rect(m, 2, 12, 7, 17, "f")                  # a fenced flower bed
    for (x, y) in [(3, 14), (3, 16), (5, 14), (5, 16)]:
        put(m, x, y, "F")
    rect(m, 2, 22, 11, 25, ",")                 # tall grass below the road
    rect(m, 24, 3, 35, 5, ",")                  # and above the beach
    put(m, 36, 24, "x")                         # a chest half-buried in sand
    put(m, 18, 7, "*")                          # POKe BALL on the sand
    put(m, 1, 19, "$")                          # route sign
    put(m, 7, 2, "$")                           # cave sign
    put(m, 17, 8, "$")                          # lake sign
    put(m, 21, 25, "N")                         # FISHER
    put(m, 34, 8, "N")                          # LASS
    put(m, 10, 4, "N")                          # HIKER, on the road
    return m


# --------------------------------------------------------- GRANITE CAVE -----
# An indoor room: the rock floor holds GEODUDE, boulders are the walls, and a
# hiker has made a camp in the corner (PC, shelf, bedroll, rug, chest).
def build_cave():
    m = M(16, 12, "r")
    rect(m, 0, 0, 15, 0, "b")
    rect(m, 0, 11, 15, 11, "b")
    rect(m, 0, 0, 0, 11, "b")
    rect(m, 15, 0, 15, 11, "b")
    put(m, 4, 11, "D")                          # back out to ROUTE 2
    rect(m, 7, 3, 9, 4, "b")                    # boulder cluster
    rect(m, 11, 2, 13, 3, "b")
    rect(m, 6, 8, 10, 8, "s")                   # a sandy patch on the floor
    put(m, 13, 7, "x")                          # a chest in the dark
    put(m, 7, 9, "g")                           # the camp's rug
    put(m, 1, 2, "p")                           # PC terminal
    put(m, 2, 2, "k")                           # shelf
    put(m, 1, 9, "E")                           # bedroll
    put(m, 7, 6, "N")                           # HIKER
    put(m, 4, 10, "P")                          # arrival tile, by the door
    return m


# ---------------------------------------------------------- RED's HOUSE -----
# The player's own house in PALLET TOWN: PC, bookshelf, TV, bed, rug and the
# kitchen table -- the interior set's furniture, on an indoor map.
def build_house():
    m = M(12, 9, "L")
    rect(m, 0, 0, 11, 0, "W")
    rect(m, 0, 8, 11, 8, "W")
    rect(m, 0, 0, 0, 8, "W")
    rect(m, 11, 0, 11, 8, "W")
    rect(m, 5, 8, 6, 8, "D")                    # back out to PALLET TOWN
    put(m, 1, 1, "p")                           # PC
    rect(m, 2, 1, 3, 1, "k")                    # bookshelf
    rect(m, 9, 1, 10, 1, "M")                   # TV
    rect(m, 8, 4, 9, 6, "E")                    # bed
    rect(m, 3, 4, 5, 5, "g")                    # rug
    rect(m, 1, 5, 2, 5, "C")                    # table
    put(m, 3, 6, "N")                           # MOM
    put(m, 6, 7, "P")                           # arrival tile
    return m


ROUTE2 = rows_of(build_route2())
CAVE = rows_of(build_cave())
HOUSE = rows_of(build_house())

# indoor maps draw with the interior tileset (map_tilesets in src/data.s).
# The cave is *not* one of them: its rock and boulders come off the outdoor
# sheet, so it keeps the outdoor set and the room art stays for rooms.
INDOOR_MAPS = {"POKeMON CENTER", "RED's HOUSE"}

# What lives in a *tile*, the way the real games do it: a tile's encounter
# group (tile_defs +37) picks the table, so the same tall grass on any map
# holds the same crowd, the water holds MAGIKARP, and the cave holds GEODUDE.
ENCOUNTERS = [
    (),              # 0: nothing -- grass, sand, road: safe ground
    (3, 4, 4, 5, 6, 7),   # 1 tall grass: PIDGEY RATTATA ODDISH MEOWTH PIKACHU
    (8, 8, 8),       # 2 water:      MAGIKARP, if you dare walk out on it
    (9, 9, 9, 5),    # 3 cave floor: GEODUDE, and one ODDISH that got lost
]
# level band per group, low then high
LEVELS = [(0, 0), (3, 6), (5, 12), (6, 14)]

MAPS = [
    dict(name="PALLET TOWN", rows=PALLET,
         npcs=[(17, 10, 0, 5, "PROF. OAK\fPOKeMON are my\ntrue love!\fWild ones live in\nthe tall grass.\fPress M for the\nmenu, Z to talk."),
               (24, 16, 0, 1, "KID\fTall grass hides\nwild POKeMON.\fWalk in it and\nwatch out!")],
         signs=[(21, 2, "PALLET TOWN\fShades of your\njourney await!"),
                (14, 9, "RED's house\fMOM lives here.")],
         items=[(8, 13, "POTION", "\fYou found a\nPOTION!\fIt went into\nyour BAG.")],
         links=dict(N=(1, KEEPX, 38)),
         warps=[(10, 7, 6, 6, 7), (30, 7, 3, 6, 7)]),

    dict(name="ROUTE 1", rows=ROUTE1,
         npcs=[(22, 20, 0, 1, "YOUNGSTER JOEY\fI like shorts!\nThey're comfy\nand easy to wear!\f...My RATTATA is\nin the top\npercentage!"),
               (16, 28, 0, 2, "BUG CATCHER\fTall grass rustles\nwhen you walk\nthrough it.\fSomething always\njumps out!")],
         signs=[(18, 34, "ROUTE 1\fPALLET TOWN -\nVIRIDIAN CITY")],
         items=[(34, 4, "POKe BALL", "\fYou found a\nPOKe BALL!\fIt went into\nyour BAG.")],
         links=dict(N=(2, KEEPX, 30), S=(0, KEEPX, 2),
                    E=(4, 1, KEEPY)),
         warps=[]),

    dict(name="VIRIDIAN CITY", rows=VIRIDIAN,
         npcs=[(17, 12, 0, 3, "CENTER GUIDE\fThe house with\nthe red roof is\nthe POKeMON\nCENTER.\fStep inside and\nthe nurse will\nheal your team."),
               (24, 17, 2, 4, "RIVAL\fHey! You got a\nPOKeMON too?\fThen let's see\nhow good you\nreally are!"),
               (32, 20, 0, 2, "GIRL\fThe road north is\nblocked by a\nsleepy man.\fYou could train\nin the grass to\nthe south!")],
         signs=[(22, 28, "VIRIDIAN CITY\fThe ETERNAL\nCITY OF\nDREAMING.")],
         items=[(8, 14, "POTION", "\fYou found a\nPOTION!\fIt went into\nyour BAG.")],
         links=dict(S=(1, KEEPX, 1)),
         warps=[(12, 8, 3, 5, 7), (38, 8, 3, 6, 7), (26, 12, 3, 5, 7), (34, 24, 3, 6, 7)]),

    dict(name="POKeMON CENTER", rows=CENTER, floor="L",
         npcs=[(3, 4, 1, 3, "NURSE\fWelcome to the\nPOKeMON CENTER!\fShall I heal\nyour POKeMON?"),
               ],
         signs=[], items=[], links=dict(),
         warps=[(5, 8, 0xFE, 0, 0), (6, 8, 0xFE, 0, 0)]),

    dict(name="ROUTE 2", rows=ROUTE2,
         npcs=[(21, 25, 0, 1, "FISHER\fMAGIKARP live in\nthe lake.\fHopeless things,\nnormally.\fBut you can walk\nright out onto the\nwater and find\nout for yourself!"),
               (34, 8, 0, 2, "LASS\fThis sand is warm.\fNothing ever\njumps out of it.\fThe water, mind\nyou, is another\nstory."),
               (10, 4, 0, 5, "HIKER\fGRANITE CAVE is\nbehind me.\fGEODUDE sleep on\nthe cave floor --\nstep on it and one\nwakes up angry!")],
         signs=[(1, 19, "ROUTE 2\fWEST: ROUTE 1\fEAST: THE LAKE"),
                (7, 2, "GRANITE CAVE\fA hiker's camp\nis just inside."),
                (17, 8, "THE LAKE\fDEEP AND COLD"),
                (36, 24, "A CHEST\fHalf-buried in\nthe sand.\fThe lock is rusty\nand shut.")],
         items=[(18, 7, "POKe BALL", "\fYou found a\nPOKe BALL!\fIt went into\nyour BAG.")],
         links=dict(W=(1, 38, KEEPY)),
         warps=[(6, 1, 5, 4, 10)]),

    dict(name="GRANITE CAVE", rows=CAVE, floor="r",
         npcs=[(7, 6, 0, 1, "HIKER\fThis is my camp.\fI dig down here\nfor GEODUDE.\fCareful where you\nstep -- the whole\nfloor is theirs!")],
         signs=[(13, 7, "A CHEST\fFull of POKe BALLs\nthat belong to\nthe hiker.\fBetter leave it\nalone.")],
         items=[], links=dict(),
         warps=[(4, 11, 4, 6, 2)]),

    dict(name="RED's HOUSE", rows=HOUSE, floor="L",
         npcs=[(3, 6, 0, 2, "MOM\fAll boys leave\nhome some day.\fIt said so on TV!\fTake care of that\nPOKeMON of yours!")],
         signs=[(9, 1, "A movie is on\nTV: two POKeMON\nin a battle!")],
         items=[], links=dict(),
         warps=[(5, 8, 0xFE, 0, 0), (6, 8, 0xFE, 0, 0)]),
]


# ================================================================ EMIT ======
o = []
def w(s=""): o.append(s)
def s_(s):
    r = (s.replace("\\", "\\\\")
          .replace('"', '\\"')
          .replace("\n", "\\n")
          .replace("\f", "\\f"))
    return '"' + r + '"'

w("#" + "=" * 76)
w("#  data.s - GENERATED by tools/gen_data.py -- DO NOT EDIT BY HAND")
w("#  sprite art, species stats, type chart, moves, maps, dialogue.")
w("#" + "=" * 76)
w(".intel_syntax noprefix")
w('.include "defs.inc"')
w("")
w(".section .rodata")
w("")
w("# ----------------------------------------------------------- sprites -----")
for name, (col, lines) in SPRITES.items():
    lines = check_sprite(name, lines)
    body = "\\n".join(ln.replace("\\", "\\\\").replace('"', '\\"') for ln in lines)
    w(f"spr_{name}:")
    w(f'    .ascii "{body}\\n\\0"')
w("")

w("# -------------------------------------------------------- type chart -----")
w(".globl type_chart")
w("type_chart:")
for row in CHART:
    w("    .byte " + ",".join(str(v) for v in row))
w("")
w("type_names:")
for t in TYPES:
    w(f"    .quad str_ty_{t[2:]}")
w("type_colours:")
w("    .byte " + ",".join(TYPE_COL[t] for t in TYPES))
for t in TYPES:
    w(f'str_ty_{t[2:]}: .asciz "{t[2:].capitalize()}"')
w("")

w("# ------------------------------------------------------------- moves -----")
w(".globl move_table")
w("move_table:")
for name, power, ty, eff, pp in MOVES:
    w(f"    .quad str_mv_{name}                 # +0  name")
    w(f"    .byte {power},{ty},{eff},{pp}       # +8  power,type,effect,pp")
    w("    .zero 4                            # entries are V_SZ (16) bytes")
for name, *_ in MOVES:
    w(f'str_mv_{name}: .asciz "{name.replace("_", " ")}"')
w("")

w("# ----------------------------------------------------------- species -----")
w(".globl species_table")
w("species_table:")
# A species record is S_SZ = 40 bytes and every field offset in defs.inc is
# measured from its start, so the byte count is checked here: getting it wrong
# (39 bytes, say) misaligns the whole table and the game segfaults in battle.
SPEC_SZ = 40
for (name, spr, hp, atk, df, spd, t1, t2, cr, yl, mv, evo, evo_lv) in SPECIES:
    mvs = [MOVE_ID[m] for m in mv] + [0] * (4 - len(mv))
    evo_id = SPEC_ID[evo] if evo else 0xFF
    head = [hp, atk, df, spd, t1, t2, cr, yl]
    mid = mvs + [SPR_W, SPR_H, SPRITES[spr][0]]
    tail = [evo_id, evo_lv]
    # fields that exist: name, sprite, stats(8), moves+shape(7), evolve(2)
    base = 8 + 8 + len(head) + len(mid) + len(tail)
    # S_EVO is at +31 and S_EVO_LV at +32, so the real fields must land at
    # exactly 33 bytes; the rest is padding up to S_SZ.
    if base != 33:
        die("species %s record needs 33 real bytes before padding, the "
            "emitter produced %d -- check S_EVO/S_EVO_LV in src/defs.inc"
            % (name, base))
    pad = SPEC_SZ - base
    if pad < 0:
        die("species %s record is %d bytes, S_SZ is only %d"
            % (name, base, SPEC_SZ))
    w(f"    .quad str_sp_{name}, spr_{spr}")
    w(f"    .byte " + ",".join(str(x) for x in head) +
      "        # base stats, types, catch rate, exp yield")
    w(f"    .byte " + ",".join(str(x) for x in mid) +
      "        # moves, sprite w/h, sprite colour")
    w(f"    .byte " + ",".join(str(x) for x in tail) + "," +
      ",".join("0" for _ in range(pad)) +
      "     # +31 evolves into (0xFF = never), +32 at level")
for (name, *_r) in SPECIES:
    w(f'str_sp_{name}: .asciz "{name}"')
w("")
w(".globl n_species")
w(f"n_species: .byte {len(SPECIES)}")
w(".globl n_moves")
w(f"n_moves: .byte {len(MOVES)}")
w("")

w("# ------------------------------------------------------------- items -----")
w(".globl item_names")
w("item_names:")
for n, d in ITEMS:
    w(f"    .quad str_it_{n.replace(' ', '_')}")
for n, d in ITEMS:
    w(f'str_it_{n.replace(" ", "_")}: .asciz "{n}"')
w(".globl n_items")
w(f"n_items: .byte {len(ITEMS)}")
w("")


# ====================================================== TILE GRAPHICS =======
# Every map tile is 2x2 terminal characters.  An entry is 40 bytes:
#    +0  four pointers to single-character glyph strings (row0 l,r; row1 l,r)
#    +32 attr byte per cell : (bg<<4)|fg   -- the background paints the tile
#    +36 walkable, encounter, 0, 0
C_BLACK, C_RED, C_GREEN, C_YELLOW, C_BLUE, C_MAGENTA, C_CYAN, C_GRAY = range(8)
C_BRED, C_BGREEN, C_BYELLOW, C_BBLUE, C_BMAGENTA, C_BCYAN, C_BWHITE = range(9, 16)


def A(bg, fg):
    return (bg << 4) | fg


# name, map char, 4 chars, 4 attrs, walk, enc
TILES = [
    ("grass",   ".", ".  .", [A(C_GREEN, C_BGREEN)] * 4, 1, 0),
    ("tall",    ",", '""""', [A(C_BGREEN, C_GREEN)] * 4, 1, 1),
    ("tree",    "#", "####", [A(C_GREEN, C_BGREEN)] * 4, 0, 0),
    ("wall",    "W", "####", [A(C_GRAY, C_BWHITE)] * 4, 0, 0),
    ("floor",   "L", ".  .", [A(C_BLACK, C_GRAY)] * 4, 1, 0),
    ("water",   "~", "~~~~", [A(C_BLUE, C_BCYAN)] * 4, 1, 2),   # surfable
    ("roof",    "R", "__||", [A(C_RED, C_BRED)] * 4, 0, 0),
    ("door",    "D", "[]||", [A(C_GRAY, C_BWHITE)] * 4, 1, 0),
    ("counter", "C", "====", [A(C_YELLOW, C_BYELLOW)] * 4, 0, 0),
    ("sign",    "$", "__/|", [A(C_GREEN, C_BYELLOW)] * 4, 0, 0),
    ("item",    "*", "o  o", [A(C_GREEN, C_BYELLOW)] * 4, 0, 0),
    ("flower",  "F", "*  *", [A(C_GREEN, C_BMAGENTA)] * 4, 1, 0),
    ("path",    ":", "    ", [A(C_YELLOW, C_BYELLOW)] * 4, 1, 0),
    ("machine", "M", "####", [A(C_RED, C_BWHITE)] * 4, 0, 0),
    ("sand",    "s", "....", [A(C_YELLOW, C_BYELLOW)] * 4, 1, 0),
    ("rock",    "r", "    ", [A(C_GRAY, C_BWHITE)] * 4, 1, 3),
    ("boulder", "b", "####", [A(C_GRAY, C_BWHITE)] * 4, 0, 0),
    ("fence",   "f", "||||", [A(C_GRAY, C_BWHITE)] * 4, 0, 0),
    ("chest",   "x", "####", [A(C_YELLOW, C_BYELLOW)] * 4, 0, 0),
    ("pc",      "p", "####", [A(C_GRAY, C_BCYAN)] * 4, 0, 0),
    ("shelf",   "k", "####", [A(C_YELLOW, C_YELLOW)] * 4, 0, 0),
    ("bed",     "E", "####", [A(C_GRAY, C_BCYAN)] * 4, 0, 0),
    ("rug",     "g", "    ", [A(C_MAGENTA, C_BMAGENTA)] * 4, 1, 0),
    ("out",     "", "    ", [A(C_BLACK, C_BLACK)] * 4, 0, 0),
]
CHAR2TILE = {t[1]: i for i, t in enumerate(TILES) if t[1]}
for (name, ch, chars, attrs, walk, enc) in TILES:
    if len(chars) != 4:
        die("tile %s has %d characters, every tile is 2x2" % (name, len(chars)))
    if len(attrs) != 4:
        die("tile %s has %d attributes" % (name, len(attrs)))

# map entity sprites: 4 characters + 4 foreground colours.  The background of
# each cell is left alone, so sprites look transparent on any terrain.
SPR = {
    "player": ("@@||", [C_BRED, C_BRED, C_BWHITE, C_BWHITE]),
    "boy":    ("oo||", [C_BCYAN, C_BCYAN, C_BWHITE, C_BWHITE]),
    "girl":   ("oo||", [C_BMAGENTA, C_BMAGENTA, C_BWHITE, C_BWHITE]),
    "nurse":  ("oo##", [C_BWHITE, C_BWHITE, C_BMAGENTA, C_BMAGENTA]),
    "rival":  ("@@||", [C_BBLUE, C_BBLUE, C_BWHITE, C_BWHITE]),
    "prof":   ("oo##", [C_BWHITE, C_BWHITE, C_GRAY, C_GRAY]),
}
for _n, (_c, _a) in SPR.items():
    if len(_c) != 4 or len(_a) != 4:
        die("sprite %s must be 4 characters with 4 colours" % _n)
SPR_ID = {n: i for i, n in enumerate(SPR)}

GLYPH_LABEL = {}
GLYPH_ORDER = []


def gname(ch):
    """label name for a one-character glyph (defined later, in one block)"""
    if ch not in GLYPH_LABEL:
        GLYPH_LABEL[ch] = "g_c%d" % ord(ch)
        GLYPH_ORDER.append(ch)
    return GLYPH_LABEL[ch]


def emit_glyphs():
    w("# every glyph used by the tile/sprite tables, in one block so the")
    w("# fixed-size entry records stay contiguous")
    for ch in GLYPH_ORDER:
        lit = ch.replace("\\", "\\\\").replace('"', '\\"')
        w('%s: .asciz "%s"' % (GLYPH_LABEL[ch], lit))
    w("")


w("# ------------------------------------------------------- tile graphics ---")
w(".globl tile_defs")
w("tile_defs:")
for (name, ch, chars, attrs, walk, enc) in TILES:
    for c in chars:
        w("    .quad " + gname(c))
    w("    .byte " + ",".join(str(a) for a in attrs) + ",%d,%d,0,0" % (walk, enc))
w("")
w(".globl n_tiles")
w("n_tiles: .byte %d" % len(TILES))
w("")
w(".globl char_to_tile")
w("char_to_tile:")
row = [str(CHAR2TILE.get(chr(i), len(TILES) - 1)) for i in range(128)]
w("    .byte " + ",".join(row[:64]))
w("    .byte " + ",".join(row[64:]))
w("")
w("# ----------------------------------------------------- entity sprites ---")
w(".globl ent_sprite_defs")
w("ent_sprite_defs:")
for name, (chars, attrs) in SPR.items():
    for c in chars:
        w("    .quad " + gname(c))
    w("    .byte " + ",".join(str(a) for a in attrs) + ",0,0,0,0")
w("")
w(".globl n_ent_sprites")
w("n_ent_sprites: .byte %d" % len(SPR))
w("")
emit_glyphs()

# -------------------------------------------------------------- maps -----
def tile_lines(rows, floor="."):
    """entity marks sit on plain floor for the tile layer"""
    return ["".join(floor if c in "NHP"
                     else (":" if c == "n" else c) for c in r)
            for r in rows]


def emit_entities(label, ents, kind):
    w("%s:" % label)
    for e in ents:
        if kind == "sign":
            x, y, txt = e
            w("    .byte %d,%d,0,0" % (x, y))
        elif kind == "item":
            x, y, it, txt = e
            w("    .byte %d,%d,%d,0" % (x, y, ITEM_ID[it]))
        else:
            x, y, k, spr, txt = e
            w("    .byte %d,%d,%d,%d" % (x, y, k, spr))
        # a record is 16 bytes: 4 coordinate bytes, 4 of padding, then the
        # text pointer -- world.s reads that pointer at +8, so the padding
        # comes first.  (It used to sit after the quad, which moved the
        # pointer to +4 and turned every NPC, sign and item line into
        # "?? MESSAGE ERROR ??".)
        w("    .zero 4                      # padding: the pointer lives at +8")
        w("    .quad str_%s_%s_%d_%d" % (kind, label, x, y))
    w("    .byte 0xff")
    w("    .zero 15")


for i, mp in enumerate(MAPS):
    rows = mp["rows"]
    w0 = len(rows[0])
    for j, r in enumerate(rows):
        if len(r) != w0:
            die("map %s row %d is %d wide, expected %d: %r" % (mp["name"], j, len(r), w0, r))
        for c in r:
            if c not in CHAR2TILE and c not in "NHPn":
                die("map %s row %d: unknown tile char %r" % (mp["name"], j, c))
    h = len(rows)
    spawn = None
    for y, r in enumerate(rows):
        for x, c in enumerate(r):
            if c == "P":
                spawn = (x, y)
            if c in "NHn" and not any((e[0], e[1]) == (x, y) for e in mp["npcs"]):
                die("map %s: npc glyph at %d,%d has no npc entry" % (mp["name"], x, y))
            if c == "$" and not any((e[0], e[1]) == (x, y) for e in mp["signs"]):
                die("map %s: sign glyph at %d,%d has no sign entry" % (mp["name"], x, y))
            if c == "*" and not any((e[0], e[1]) == (x, y) for e in mp["items"]):
                die("map %s: item glyph at %d,%d has no item entry" % (mp["name"], x, y))
    if spawn is None:
        if i == 0:
            die("start map %s has no P spawn" % mp["name"])
        spawn = (0, 0)
    w("# ----- map %d: %s (%dx%d) spawn %s -----" % (i, mp["name"], w0, h, spawn))
    w('map%d_name: .asciz "%s"' % (i, mp["name"]))
    w("map%d_tiles:" % i)
    for r in tile_lines(rows, mp.get("floor", ".")):
        w('    .ascii "%s"' % r)
    w("    .byte 0")
    emit_entities("map%d_npcs" % i, mp["npcs"], "npc")
    emit_entities("map%d_signs" % i, mp["signs"], "sign")
    emit_entities("map%d_items" % i, mp["items"], "item")
    w("map%d_links:" % i)
    # order matters: world.s indexes the table by direction (0=up 1=down
    # 2=left 3=right), i.e. N,S,W,E -- three bytes per entry
    for e in "NSWE":
        v = mp["links"].get(e)
        if v is None:
            w("    .byte 0xff,0,0")
        else:
            w("    .byte %d,%d,%d" % v)
    w("map%d_warps:" % i)
    for (x, y, tm, dx, dy) in mp["warps"]:
        w("    .byte %d,%d,%d,%d,%d" % (x, y, tm, dx, dy))
    w("    .byte 0xff")
    w("map%d_spawn: .byte %d,%d,%d,%d" % (i, spawn[0], spawn[1], w0, h))
    w("")
    for label, ents, kind in (("map%d_npcs" % i, mp["npcs"], "npc"),
                              ("map%d_signs" % i, mp["signs"], "sign"),
                              ("map%d_items" % i, mp["items"], "item")):
        for e in ents:
            if kind == "sign":
                x, y, txt = e
            elif kind == "item":
                x, y, it, txt = e
            else:
                x, y, k, spr, txt = e
            w("str_%s_%s_%d_%d: .asciz %s" % (kind, label, x, y, s_(txt)))
    w("")

w("# -------------------------------------------------------- map table -----")
w(".globl enc_tables, enc_counts, enc_levels")
w("enc_tables:")
for tbl in ENCOUNTERS:
    if tbl:                 # an empty group owns no bytes, so the rows stay
        w("    .byte " + ",".join(str(x) for x in tbl))   # exactly counts long
w("enc_counts:")
w("    .byte " + ",".join(str(len(t)) for t in ENCOUNTERS))
w("enc_levels:")
for lo, hi in LEVELS:
    w("    .byte %d,%d" % (lo, hi))
w("")
w(".globl map_tilesets")
w("map_tilesets:")
w("    .byte " + ",".join("1" if mp["name"] in INDOOR_MAPS else "0"
                         for mp in MAPS))
w("")
w(".globl map_table")
w("map_table:")
for i, mp in enumerate(MAPS):
    w("    .quad map%d_name, map%d_tiles, map%d_npcs, map%d_signs" % (i, i, i, i))
    w("    .quad map%d_items, map%d_links, map%d_warps, map%d_spawn" % (i, i, i, i))
w(".globl n_maps")
w("n_maps: .byte %d" % len(MAPS))
w("")

w("# ----------------------------------------------------------- strings -----")
STRS = {
 "str_title":    "POKeMON",
 "str_title2":   "FIRE RED",
 "str_title3":   "ASM EDITION",
 "str_start":    "PRESS  START",
 "str_credit":   "x86-64 asm . raw syscalls . no libc",
 "str_intro1":   "PROF. OAK\fHello there!\nWelcome to the\nworld of\nPOKeMON!",
 "str_intro2":   "PROF. OAK\fThis world is\ninhabited by\ncreatures\ncalled POKeMON!\fSome people\nraise them.\nSome battle\nwith them.\fMyself...\nI study them.",
 "str_intro3":   "PROF. OAK\fChoose your\nfirst partner!",
 "str_starter_a":"This is\nCHARMANDER.\fA FIRE type.\nTake it?",
 "str_starter_b":"This is\nBULBASAUR.\fA GRASS type.\nTake it?",
 "str_starter_c":"This is\nSQUIRTLE.\fA WATER type.\nTake it?",
 "str_yes":      "YES",
 "str_no":       "NO",
 "str_nickname": "\fDo you want to\ngive it a\nnickname?\f...too bad, this\nis assembly.\nIt is ",
 "str_rival_pick":"\fRIVAL: Then\nI'll take this\none!",
 "str_what_evo": "What? ",
 "str_is_evolving": " is\nevolving!",
 "str_congrats": "Congratulations!\nYour ",
 "str_evolved_into": "\nevolved into ",
 "str_wild":     "A wild ",
 "str_appeared": " appeared!",
 "str_go":       "I choose you!",
 "str_what":     "What will ",
 "str_do":       " do?",
 "str_run_ok":   "Got away\nsafely!",
 "str_run_fail": "Can't escape!",
 "str_caught":   "Gotcha! ",
 "str_caught2":  " was caught!",
 "str_catchfail":"Oh no! The\nPOKeMON broke\nfree!",
 "str_fainted":  " fainted!",
 "str_gain_xp":  " gained ",
 "str_xp_points":" EXP. Points!",
 "str_level_up": " grew to\nLv",
 "str_win":      "You won the\nbattle!",
 "str_lv":       "Lv",
 "str_hp":       "HP",
 "str_notpp":    "No PP left for\nthis move!",
 "str_super":    "It's super\neffective!",
 "str_weak":     "It's not very\neffective...",
 "str_noeff":    "It doesn't\naffect...",
 "str_atkdown":  "'s ATTACK\nfell!",
 "str_defdown":  "'s DEFENSE\nfell!",
 "str_healmove": " recovered\nhealth!",
 "str_poison":   " was poisoned!",
 "str_poisondmg":" is hurt by\npoison!",
 "str_recoil":   " is hit by\nrecoil!",
 "str_crit":     "A critical\nhit!",
 "str_rivalbattle":"RIVAL wants\nto fight!",
 "str_whiteout": "You have no\nPOKeMON left!\fYou whited out!\f...You scurried\nto the POKeMON\nCENTER.",
 "str_partyfull":"Your party is\nfull!",
 "str_sentout":  " sent out ",
 "str_potion":   "POTION",
 "str_poke_ball":"POKe BALL",
 "str_usedpotion":" used a\nPOTION!",
 "str_healed20": " recovered\n20 HP!",
 "str_threwball":" threw a\nPOKe BALL!",
 "str_bagempty": "The BAG is\nempty.",
 "str_menu_hdr": "MENU",
 "str_pokedex":  "POKeDEX",
 "str_pokemon_m":"POKeMON",
 "str_bag_m":    "BAG",
 "str_player_m": "PLAYER",
 "str_save_m":   "SAVE",
 "str_option_m": "OPTION",
 "str_exit_m":   "EXIT",
 "str_saved":    "Your progress\nhas been saved.",
 "str_savefail": "Saving failed\n(file I/O).",
 "str_nosave":   "No saved data\nfound.",
 "str_pkdx_none":"No data yet.\fCatch POKeMON to\nfill the DEX!",
 "str_noenc":    "No encounters\nin ROUTE 1 yet.",
 "str_overwrite":"Would you like\nto overwrite the\nprevious save?",
 "str_playerinfo":"PLAYER: RED\fBADGES: 0\nMONEY: 3000\fPOKeDEX: ",
 "str_battle":   "BATTLE",
 "str_fight":    "FIGHT",
 "str_bagb":     "BAG",
 "str_pokemonb": "POKeMON",
 "str_runb":     "RUN",
 "str_ballused": " used a\nPOKe BALL!",
 "str_dialog_ok":"...",
 "str_escaping": "...",
}
for k, v in STRS.items():
    w(f"{k}: .asciz {s_(v)}")
w("")
w("# battle menu labels")
w("battle_labels: .quad str_fight, str_bagb, str_pokemonb, str_runb")
# ---- make every generated label global (cross-module references) ----------
out = []
for line in o:
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
    if m:
        out.append(".globl " + m.group(1))
    out.append(line)
print("\n".join(out))
