#!/usr/bin/env python3
"""Static check: make sure the argument register of a call is actually set
before the call.  Catches the 'movzx eax,... / call f(edi)' class of bug that
assembles fine and only blows up at runtime."""
import re, sys, glob

# function -> register the first argument travels in
ARG1 = {}
for f in ("spec_ptr spec_name spec_sprite spec_field spec_typecol party_mon mon_heal "
          "mon_recalc mon_name mon_sprite mon_typecol mon_give_xp lev_move_count "
          "starter_species_of rng_seed rng_range rng_next map_entry map_tiles map_spawn "
          "side_mon ally_mon enemy_mon ai_pick eff_of stab_of atk_of def_of spd_of "
          "draw_hpbar draw_mon_sprite bt_say bp_render msg_push msg_show tb_show "
          "kq_push fb_fill fb_box fb_puts fb_putu fb_putg fb_putc fb_putn map_byte").split():
    ARG1[f] = "edi"
for f in ("fb_putc_bg",):
    ARG1[f] = "edi"
# two-arg helpers: (reg1, reg2)
ARG2 = {
    "mon_init": ("edi", "esi"),
    "fb_putc": ("edi", "esi"),
    "draw_tile_entry": ("edi", "esi"),
}

WRITES = {
    "edi": re.compile(r"\b(edi|rdi|di)\b\s*[,)]|movzx\s+(edi|rdi)|\bxor\s+edi|\bpop\s+rdi|\binc\s+edi|\bdec\s+edi|\badd\s+edi|\bsub\s+edi|\blea\s+rdi"),
}

def check(path):
    lines = open(path).read().splitlines()
    bad = []
    for i, ln in enumerate(lines):
        m = re.search(r"\bcall\s+([a-zA-Z_][\w]*)", ln)
        if not m or m.group(1) not in ARG1:
            continue
        reg = ARG1[m.group(1)]
        ok = False
        for j in range(i - 1, max(-1, i - 5), -1):
            prev = lines[j].split("#")[0]
            if not prev.strip():
                continue
            if re.search(r"\b%s\b|\b%s\b" % ("e" + reg[1:], reg), prev) and \
               re.search(r"\b(mov|movzx|movsx|lea|xor|pop|inc|dec|add|sub|and|or|movsxd)\b", prev):
                ok = True
                break
        if not ok:
            bad.append((i + 1, lines[i].strip()))
    return bad

rc = 0
for path in sorted(glob.glob("src/*.s")):
    if path.endswith("data.s"):
        continue
    for ln, txt in check(path):
        print("%s:%d: %s  (arg register %s looks unset)" % (path, ln, txt, "edi"))
        rc = 1
sys.exit(rc)
