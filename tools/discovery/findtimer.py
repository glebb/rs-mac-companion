#!/usr/bin/env python3
"""Find values in the game's memory that advance at exactly 1 second per second, then print them
once a second. Use while a song is PLAYING (Rocksmith in front, not paused) to check the song timer
by hand, e.g. after a game update. Needs build/rsprobe attached:
    build/rsprobe $(pgrep -x Rocksmith2014) &

Usage: findtimer.py [group]
  group 2 (default): doubles in seconds - Rocksmith's song timer
  group 0: floats in seconds + ints in milliseconds
  group 1: floats/doubles in milliseconds

The song timer restarts near 0 when a song starts and stops while paused; menu clocks keep going.
rstone does this search by itself; this script is only for investigating.
"""
import struct
import sys
import time

from probe import read, send

FORMATS = {"f32": ("<f", 4, 1.0), "f64": ("<d", 8, 1.0), "i32ms": ("<i", 4, 0.001),
           "f32ms": ("<f", 4, 0.001), "f64ms": ("<d", 8, 0.001)}

group = sys.argv[1] if len(sys.argv) > 1 else "2"
while True:
    print(send(f"snapt {group}").strip(), flush=True)
    ok = True
    for _ in range(3):
        time.sleep(1.0)
        r = send("ratet 0.97 1.03").strip()
        print("  ", r, flush=True)
        if sum(int(x) for x in r.split()[1:]) == 0:
            ok = False
            break
    if ok:
        break
    print(time.strftime("%H:%M:%S"), "nothing advancing at 1 s/s yet (is a song playing?); retrying", flush=True)
    send("tfree")
    time.sleep(1)

cands = [l.split() for l in send("tlist").splitlines() if l and not l.startswith("end")]
send("tfree")
print(time.strftime("%H:%M:%S"), f"found {len(cands)} candidates; values once a second (Ctrl+C to stop):", flush=True)
while True:
    vals = []
    for kind, a, _ in cands:
        fmt, size, scale = FORMATS[kind]
        b = read(int(a, 16), size)
        vals.append(f"{kind}@{a}={struct.unpack(fmt, b)[0] * scale:.2f}" if b else f"{kind}@{a}=?")
    print(time.strftime("%H:%M:%S"), " ".join(vals), flush=True)
    time.sleep(1)
