#!/usr/bin/env python3
"""Drive the real binary from a pty with an explicit key list and show the
final 80x24 screen.

usage:  python3 tools/ptykeys.py START [--] [keys...]
        python3 tools/ptykeys.py 'w w w w' --wait 0.2

Every key is one chunk written to the pty; "." means "wait one gap".  The
scenario name shortcuts (ow, walk, grass, battle, ...) are handled by
tools/ptyplay.py; this tool is the manual variant.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import vt  # noqa: E402

KEYMAP = {
    "u": "w", "d": "s", "l": "a", "r": "d",
    "a": "z", "b": "x", "s": "\r", "q": "q",
    "w": "w", "x": "x", "z": "z", ".": "",
}


def run(keys, gap=0.05, extra=(), cols=80, rows=24, settle=0.4):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execv(os.path.join(ROOT, "pokemon"),
                 ["pokemon"] + list(extra))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    time.sleep(0.3)
    for k in keys:
        s = KEYMAP.get(k, k)
        if s:
            os.write(fd, s.encode())
        time.sleep(gap)
    time.sleep(settle)
    out = bytearray()
    deadline = time.time() + 1.0
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            chunk = os.read(fd, 1 << 20)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except OSError:
        pass
    sc = vt.Screen(cols, rows)
    vt.apply_stream(sc, bytes(out))
    return sc.text()


def main():
    args = sys.argv[1:]
    gap = 0.05
    extra = [a for a in args if a.startswith("--") and not a.startswith("--wait")]
    if "--wait" in args:
        gap = float(args[args.index("--wait") + 1])
    keys = []
    for a in args:
        if a in ("--wait",) or a.startswith("--"):
            continue
        if a == "-":
            continue
        if len(a) == 1 and a in KEYMAP:
            keys.append(a)
        else:
            keys.extend(list(a))
    for line in run(keys, gap=gap, extra=extra):
        print(line.rstrip())


if __name__ == "__main__":
    main()
