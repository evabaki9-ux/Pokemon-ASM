#!/usr/bin/env python3
"""Minimal ANSI/VT emulator: turns a raw terminal byte stream into screens.

Handles the subset the game emits: CUP, EL/ED, SGR (colours+bold), CUU/CUD/CUF/CUB,
and plain text.  Wide glyphs (East Asian Wide) advance the cursor by 2 columns;
everything else (including Ambiguous) advances by 1.  Exposes screens() to get the
list of screens produced, each a list of 24 strings of 80 columns.
"""
import unicodedata

WIDE = ("W", "F")


def wcw(ch):
    return 2 if unicodedata.east_asian_width(ch) in WIDE else 1


class Screen:
    def __init__(self, w=80, h=24):
        self.w, self.h = w, h
        self.ch = [[" "] * w for _ in range(h)]
        self.at = [[(0, 0)] * w for _ in range(h)]   # (fg, bg)
        self.x = self.y = 0
        self.fg = 7
        self.bg = 0
        self.bold = 0
        self.cur_visible = True

    def put(self, ch):
        n = wcw(ch)
        if self.x >= self.w:
            self.x = 0
            self.y += 1
        if self.y >= self.h:
            return
        self.ch[self.y][self.x] = ch
        self.at[self.y][self.x] = (self.fg + (8 if self.bold else 0), self.bg)
        for k in range(1, n):
            if self.x + k < self.w:
                self.ch[self.y][self.x + k] = ""
                self.at[self.y][self.x + k] = (self.fg + (8 if self.bold else 0), self.bg)
        self.x += n

    def text(self, plain=False):
        out = []
        for r in range(self.h):
            out.append("".join(c if c else " " for c in self.ch[r]))
        return out


SGR_COLOURS = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7,
               8: 8, 9: 9, 10: 10, 11: 11, 12: 12, 13: 13, 14: 14, 15: 15}


def feed(sc, data):
    """Feed bytes into the screen; returns list of (screen_copy, cursor_visible)."""
    frames = []
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b == 0x1B:
            if i + 1 < n and data[i + 1] == 0x5B:      # CSI
                j = i + 2
                while j < n and not (0x40 <= data[j] <= 0x7E):
                    j += 1
                if j >= n:
                    break
                final = chr(data[j])
                params = data[i + 2:j].decode("ascii", "replace")
                apply_csi(sc, final, params)
                i = j + 1
                continue
            i += 2
            continue
        if b == 0x0A:
            sc.y += 1
            if sc.y >= sc.h:
                sc.y = sc.h - 1
            i += 1
            continue
        if b == 0x0D:
            sc.x = 0
            i += 1
            continue
        sz = 1 if b < 0x80 else (2 if b < 0xE0 else 3 if b < 0xF0 else 4)
        ch = data[i:i + sz].decode("utf8", "replace")
        sc.put(ch)
        i += sz
    return frames


def apply_csi(sc, final, params):
    nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else []
    if final == "H" or final == "f":
        row = nums[0] if len(nums) > 0 and nums[0] else 1
        col = nums[1] if len(nums) > 1 and nums[1] else 1
        sc.y = min(sc.h - 1, max(0, row - 1))
        sc.x = min(sc.w - 1, max(0, col - 1))
    elif final == "A":
        sc.y = max(0, sc.y - (nums[0] if nums else 1))
    elif final == "B":
        sc.y = min(sc.h - 1, sc.y + (nums[0] if nums else 1))
    elif final == "C":
        sc.x = min(sc.w - 1, sc.x + (nums[0] if nums else 1))
    elif final == "D":
        sc.x = max(0, sc.x - (nums[0] if nums else 1))
    elif final == "J":
        mode = nums[0] if nums else 0
        if mode == 2:
            for r in range(sc.h):
                for c in range(sc.w):
                    sc.ch[r][c] = " "
    elif final == "K":
        for c in range(sc.x, sc.w):
            sc.ch[sc.y][c] = " "
    elif final == "m":
        vals = nums if nums else [0]
        k = 0
        while k < len(vals):
            v = vals[k]
            if v == 0:
                sc.fg, sc.bg, sc.bold = 7, 0, 0
            elif v == 1:
                sc.bold = 1
            elif v == 22:
                sc.bold = 0
            elif 30 <= v <= 37:
                sc.fg = v - 30
            elif 90 <= v <= 97:
                sc.fg = v - 90 + 8
            elif v == 39:
                sc.fg = 7
            elif 40 <= v <= 47:
                sc.bg = v - 40
            elif 100 <= v <= 107:
                sc.bg = v - 100 + 8
            elif v == 49:
                sc.bg = 0
            elif v == 38 or v == 48:
                k += 4
            k += 1
    elif final == "h" or final == "l":
        if params.startswith("?"):
            if params == "?25h":
                sc.cur_visible = True
            elif params == "?25l":
                sc.cur_visible = False


def apply_stream(sc, data):
    """Feed a whole byte stream into an existing Screen."""
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b == 0x1B:
            if i + 1 < n and data[i + 1] == 0x5B:
                j = i + 2
                while j < n and not (0x40 <= data[j] <= 0x7E):
                    j += 1
                if j >= n:
                    break
                apply_csi(sc, chr(data[j]), data[i + 2:j].decode("ascii", "replace"))
                i = j + 1
                continue
            i += 2
            continue
        if b == 0x0A:
            sc.y = min(sc.h - 1, sc.y + 1)
            i += 1
            continue
        if b == 0x0D:
            sc.x = 0
            i += 1
            continue
        sz = 1 if b < 0x80 else (2 if b < 0xE0 else 3 if b < 0xF0 else 4)
        sc.put(data[i:i + sz].decode("utf8", "replace"))
        i += sz
    return sc


def screens(data, split_on=None):
    """Return the list of screens seen while feeding the whole stream."""
    sc = Screen()
    out = []
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b == 0x1B:
            if i + 1 < n and data[i + 1] == 0x5B:
                j = i + 2
                while j < n and not (0x40 <= data[j] <= 0x7E):
                    j += 1
                if j >= n:
                    break
                apply_csi(sc, chr(data[j]), data[i + 2:j].decode("ascii", "replace"))
                i = j + 1
                continue
            i += 2
            continue
        if b == 0x0A:
            sc.y = min(sc.h - 1, sc.y + 1)
            i += 1
            continue
        if b == 0x0D:
            sc.x = 0
            i += 1
            continue
        sz = 1 if b < 0x80 else (2 if b < 0xE0 else 3 if b < 0xF0 else 4)
        sc.put(data[i:i + sz].decode("utf8", "replace"))
        i += sz
    out.append(sc)
    return out
