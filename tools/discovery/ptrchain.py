#!/usr/bin/env python3
"""Breadth-first pointer-chain search from a target address back to the game's static data.

Usage: ptrchain.py <target-hex> <static-lo-hex> <static-hi-hex> [max-offset] [depth]
Prints chains as: static_addr +off -> ... -> target
"""
import sys

from probe import send

target = int(sys.argv[1], 16)
lo, hi = int(sys.argv[2], 16), int(sys.argv[3], 16)
max_off = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x400
depth = int(sys.argv[5]) if len(sys.argv) > 5 else 5

frontier = {target: []}  # address -> chain of (holder, offset) from it to target
seen = set()
for level in range(depth):
    nxt = {}
    for addr, chain in frontier.items():
        lines = send(f"findrange {addr - max_off:x} {addr + 1:x}").splitlines()
        for l in lines:
            if l.startswith("end"):
                continue
            holder, value = (int(x, 16) for x in l.split())
            off = addr - value
            if holder in seen:
                continue
            seen.add(holder)
            c = [(holder, off)] + chain
            if lo <= holder < hi:
                print("FOUND", " -> ".join(f"[{h:x}]+{o:x}" for h, o in c), flush=True)
            else:
                nxt[holder] = c
    print(f"level {level + 1}: {len(nxt)} holders", flush=True)
    if len(nxt) > 60:
        nxt = dict(sorted(nxt.items(), key=lambda kv: kv[1][0][1])[:60])  # keep smallest offsets
    frontier = nxt
