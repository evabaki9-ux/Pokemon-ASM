#!/usr/bin/env python3
"""
tools/ptyplay.py -- run the game in a REAL pty and capture what a terminal
would show.

This is the "provably running" test: the game is started on a pseudo terminal
(exactly like a user's terminal), keys are typed into it, and every byte the
game writes is captured.  tools/vt.py then emulates the ANSI stream into 80x24
screens, which are printed (and can be saved as PNG-free text screenshots).

Usage:
  python3 tools/ptyplay.py [scenario] [--keep raw.txt] [--shots only]

scenario: any tests/play.py scenario name (default: ow)
The script chars are typed with a delay so the game sees them as real input.
"""
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
import fcntl

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TYPECHAR_DELAY = 0.020      # 20 ms between keystrokes (game runs at 50 fps)

# test-script charset -> real terminal keys.  The game reads the keyboard
# itself, so the pty harness has to translate: the script letter "s" means
# "press START", which on a keyboard is Enter or M.
KEYMAP = {
    "u": "w", "d": "s", "l": "a", "r": "d",
    "a": "z", "b": "x", "s": "\r", "q": "q",
    ".": "", "D": "",
}


def script_for(name):
    sys.path.insert(0, os.path.join(ROOT, "tests"))
    import play
    return play.scenario(name)


def run(binary, chars, cols=80, rows=24, timeout=60.0, extra=None):
    pid, fd = pty.fork()
    if pid == 0:                                    # child: the game
        os.chdir(ROOT)
        try:
            os.execv(binary, [binary] + list(extra or []))
        except Exception as e:
            os.write(2, ("exec failed: %s\n" % e).encode())
            os._exit(1)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    out = bytearray()
    i = 0
    t0 = time.time()
    while True:
        if time.time() - t0 > timeout:
            os.kill(pid, signal.SIGKILL)
            break
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        if i < len(chars):
            k = KEYMAP.get(chars[i], chars[i])
            if k:
                os.write(fd, k.encode())
            i += 1
            time.sleep(TYPECHAR_DELAY)
        else:
            break
    # drain whatever is left
    deadline = time.time() + 1.5
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    os.close(fd)
    return bytes(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    name = args[0] if args else "ow"
    chars = script_for(name)
    extra = [] if name in ("title", "starter", "load") else ["--quickstart"]
    raw = run(os.path.join(ROOT, "pokemon"), chars, extra=extra)
    if "--keep" in sys.argv:
        p = sys.argv[sys.argv.index("--keep") + 1]
        open(p, "wb").write(raw)
        print("raw capture: %s (%d bytes)" % (p, len(raw)))
    sc = vt.Screen()
    vt.apply_stream(sc, raw)
    print("=== %s: final terminal state ===" % name)
    for r, line in enumerate(sc.text()):
        print("%2d|%s|" % (r, line.rstrip()))


if __name__ == "__main__":
    main()
