#!/usr/bin/env python3
"""Show printable context around every memory hit of a string.

Usage: ctx.py <text> [before] [after] [max]
"""
import re
import sys

from probe import send


def read(addr, n):
    h = send(f"read {addr:x} {n}").strip()
    return None if h == "err" else bytes.fromhex(h)


def show(b):
    return re.sub(rb"[^\x20-\x7e]", b".", b).decode()


if __name__ == "__main__":
    text = sys.argv[1]
    before = int(sys.argv[2]) if len(sys.argv) > 2 else 48
    after = int(sys.argv[3]) if len(sys.argv) > 3 else 80
    mx = sys.argv[4] if len(sys.argv) > 4 else "500"
    hits = [int(l, 16) for l in send(f"findhex {text.encode().hex()} {mx}").split() if l not in ("end",) and re.fullmatch(r"[0-9a-f]+", l) and len(l) > 6]
    for a in hits:
        b = read(a - before, before + after)
        if b:
            print(f"{a:x}  {show(b)}")
