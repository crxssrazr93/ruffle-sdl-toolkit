#!/usr/bin/env python3
"""keyd.py: a uinput virtual keyboard fed from a FIFO.

Runs on the machine whose input stack you want to drive: on the handheld, to bypass the
gamepad to keyboard mapper and find out whether the game or the mapping drops an input,
or on a PC to type into a real session. (For headless Xvfb or gamescope runs use the
RUFFLE_SDL_KEYS hook instead; uinput devices are global to the machine, so on a desktop they
would type into whatever has focus. Do not run this on your desktop during tests.)

Usage: keyd.py [--fifo PATH] [--name NAME]
  default FIFO: $KEYD_FIFO or /tmp/keyd/keys ; device name: $KEYD_NAME or keyd-test-keys
  a pid file is written next to the FIFO (keyd.pid): stop a running keyd with
  `kill $(cat /tmp/keyd/keyd.pid)` (never pkill -f, that also matches your own shell)

Lines written to the FIFO (one command per line):
  <KEY> <ms>       press the key, hold it that many milliseconds, release
  down <KEY>       press and keep holding
  up <KEY>         release
  sleep <ms>       wait
  quit             stop the daemon
KEY is a name without the KEY_ prefix, any case: up down left right space enter esc tab
shift ctrl alt backspace a..z 0..9 f1..f12 (esc and escape both work, there is no
KEY_ESCAPE in evdev). Unknown keys are reported on stderr and skipped.

Needs python-evdev and write access to /dev/uinput.
"""
import argparse
import os
import sys
import time

from evdev import UInput, ecodes as e

ALIASES = {"escape": "ESC", "return": "ENTER", "control": "LEFTCTRL", "ctrl": "LEFTCTRL",
           "shift": "LEFTSHIFT", "alt": "LEFTALT", "del": "DELETE"}


def key_code(name):
    n = ALIASES.get(name.lower(), name.upper())
    return getattr(e, "KEY_" + n, None)


def main():
    ap = argparse.ArgumentParser(description="uinput keyboard fed from a FIFO")
    ap.add_argument("--fifo", default=os.environ.get("KEYD_FIFO", "/tmp/keyd/keys"))
    ap.add_argument("--name", default=os.environ.get("KEYD_NAME", "keyd-test-keys"))
    args = ap.parse_args()

    names = (["up", "down", "left", "right", "space", "enter", "esc", "tab", "backspace",
              "leftshift", "leftctrl", "leftalt", "delete", "home", "end", "pageup", "pagedown"]
             + [chr(c) for c in range(ord("a"), ord("z") + 1)]
             + [str(d) for d in range(10)] + ["f%d" % i for i in range(1, 13)])
    codes = sorted({key_code(n) for n in names if key_code(n) is not None})
    ui = UInput({e.EV_KEY: codes}, name=args.name)

    fifo = args.fifo
    os.makedirs(os.path.dirname(fifo) or ".", exist_ok=True)
    with open(os.path.join(os.path.dirname(fifo) or ".", "keyd.pid"), "w") as f:
        f.write(str(os.getpid()))
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    print("keyd: device %r, fifo %s" % (args.name, fifo), flush=True)

    def send(code, value):
        ui.write(e.EV_KEY, code, value)
        ui.syn()

    while True:
        with open(fifo) as f:
            for line in f:
                p = line.split()
                if not p:
                    continue
                if p[0] == "quit":
                    ui.close()
                    return
                try:
                    if p[0] == "sleep" and len(p) == 2:
                        time.sleep(int(p[1]) / 1000)
                    elif p[0] in ("down", "up") and len(p) == 2:
                        code = key_code(p[1])
                        if code is None:
                            print("keyd: unknown key %r" % p[1], file=sys.stderr, flush=True)
                        else:
                            send(code, 1 if p[0] == "down" else 0)
                    elif len(p) == 2:
                        code = key_code(p[0])
                        if code is None:
                            print("keyd: unknown key %r" % p[0], file=sys.stderr, flush=True)
                            continue
                        send(code, 1)
                        time.sleep(int(p[1]) / 1000)
                        send(code, 0)
                    else:
                        print("keyd: bad line %r" % line.strip(), file=sys.stderr, flush=True)
                except ValueError:
                    print("keyd: bad number in %r" % line.strip(), file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
