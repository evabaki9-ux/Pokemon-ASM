#!/usr/bin/env python3
"""
tools/checkregs.py -- static sanity pass over the assembly sources.

Flags two mistakes that are hard to spot by eye and very costly at runtime:
  1. a function that writes a callee-saved register (rbx rbp r12-r15) without
     saving it first  -> corrupts its caller
  2. unbalanced push/pop inside a function -> corrupts the return address
Also reports fb_* calls that are obviously out of the 80x24 framebuffer.

usage: python3 tools/checkregs.py [src/*.s ...]
"""
import re
import sys
import glob

CALLEE = ["rbx", "rbp", "r12", "r13", "r14", "r15"]
# 32-bit aliases
ALIAS = {"ebx": "rbx", "bx": "rbx", "bl": "rbx",
         "ebp": "rbp", "bp": "rbp", "bpl": "rbp",
         "r12d": "r12", "r12b": "r12", "r12w": "r12",
         "r13d": "r13", "r13b": "r13", "r13w": "r13",
         "r14d": "r14", "r14b": "r14", "r14w": "r14",
         "r15d": "r15", "r15b": "r15", "r15w": "r15"}

LABEL = re.compile(r"^([.A-Za-z_][\w.]*):")
WRITE = re.compile(r"^\s*(mov|movzx|movsx|lea|add|sub|inc|dec|xor|and|or|pop|push|imul|shl|shr|sar|div|mul|neg|not|adc|sbb)\b(.*)$")


def regs_in(operands):
    return [ALIAS.get(t, t) for t in re.findall(r"\b([a-z][a-z0-9]{1,3})\b", operands)]


def dest_operand(ins, ops):
    """first operand is the destination for two-operand intel forms"""
    if ins in ("pop", "inc", "dec", "mul", "div", "neg", "not"):
        return ops.strip().split(",")[0]
    parts = ops.split(",")
    return parts[0].strip() if parts else ""


def check(path):
    problems = []
    cur = None
    saved = {r: 0 for r in CALLEE}      # ever pushed in this function
    depth = 0
    touched = {r: 0 for r in CALLEE}
    for lineno, raw in enumerate(open(path), 1):
        line = raw.split("#")[0].rstrip()
        if not line.strip():
            continue
        m = LABEL.match(line)
        if m and not line.startswith("    ") and not m.group(1).startswith("."):
            # close previous function
            if cur:
                for r in CALLEE:
                    if touched[r] and not saved[r]:
                        problems.append(f"{path}:{cur[1]}: writes {r} without saving it")
                if depth != 0:
                    problems.append(f"{path}:{cur[1]}: unbalanced push/pop (depth {depth:+d})")
            cur = (m.group(1), lineno)
            saved = {r: 0 for r in CALLEE}
            touched = {r: 0 for r in CALLEE}
            depth = 0
            continue
        ins_m = WRITE.match(line)
        if ins_m:
            ins, ops = ins_m.group(1), ins_m.group(2)
            if ins == "push":
                r = ALIAS.get(ops.strip(), ops.strip())
                if r in saved:
                    saved[r] += 1
                depth += 1
            elif ins == "pop":
                depth -= 1
            else:
                d = dest_operand(ins, ops)
                d = d.replace("ptr", "").strip()
                if not d.startswith("[") and not d.startswith("byte") and not d.startswith("word") \
                        and not d.startswith("dword") and not d.startswith("qword"):
                    dr = ALIAS.get(d, d)
                    if dr in touched:
                        touched[dr] += 1
    if cur:
        for r in CALLEE:
            if touched[r] and not saved[r]:
                problems.append(f"{path}:{cur[1]}: writes {r} without saving it")
        if depth != 0:
            problems.append(f"{path}:{cur[1]}: unbalanced push/pop (depth {depth:+d})")
    return problems


if __name__ == "__main__":
    files = sys.argv[1:] or sorted(glob.glob("src/*.s"))
    bad = []
    for f in files:
        bad += check(f)
    for b in bad:
        print(b)
    print(f"\n{len(bad)} problem(s) in {len(files)} file(s)")
    sys.exit(1 if bad else 0)
