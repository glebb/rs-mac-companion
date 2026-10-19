#!/usr/bin/env python3
"""Send one command to rsprobe (build/rsprobe <pid>), the reader attached to Rocksmith.

Usage: probe.py <command...>
  ping                          check the reader is up
  regions                       count readable+writable memory regions
  read <hexaddr> <len>          hex bytes (up to 2000 bytes per call; probe.read() chunks)
  findstr <text> [max]          addresses of a text (findhex with the text's bytes)
  findhex <hex> [max]           addresses of a byte pattern
  findptr <hexaddr> [max]       addresses of 8-byte words equal to a value (who points here?)
  findrange <lo> <hi>           8-byte words with values in [lo, hi) (who points into this range?)
  snapi <lo> <hi>               remember all int32s in [lo, hi] ...
  filteri e|c|s|d <n>           ... keep those now == n / changed / same / changed by n
  icands [max]                  list them
  snapt <group> / ratet <lo> <hi> / tlist / tfree
                                timer search (see findtimer.py)
Only writable data is scanned; the game's code is never read.
"""
import socket
import sys

SOCK = "/tmp/rsprobe.sock"


def send(line, timeout=300):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(line.encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    data = b""
    while True:
        part = s.recv(65536)
        if not part:
            break
        data += part
    s.close()
    return data.decode(errors="replace")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "findstr":
        args = ["findhex", args[1].encode().hex()] + args[2:]
    print(send(" ".join(args)), end="")


def read(addr, n):
    """Read n bytes in chunks small enough for one reply line. Returns None on error."""
    out = b""
    while len(out) < n:
        k = min(2000, n - len(out))
        h = send(f"read {addr + len(out):x} {k}").strip()
        if h == "err":
            return None
        out += bytes.fromhex(h)
    return out
