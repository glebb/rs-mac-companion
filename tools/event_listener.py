#!/usr/bin/env python3
"""Print the events the in-game dylib (native/rscompanion.c) sends, one JSON line each.

Binds the dylib's Unix datagram socket (DATA_DIR/events.sock), as the companion app will.
Only one listener can own the socket at a time.

Usage: event_listener.py [--socket PATH] [--out FILE] [--no-state]
  --no-state   skip the once-a-second "state" heartbeats
"""
import argparse
import json
import os
import socket
import sys
import time

import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("paths", os.path.join(HERE, "..", "paths.py"))
paths = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paths)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default=os.path.join(paths.DATA_DIR, "events.sock"))
    ap.add_argument("--out", help="also append each event to this file")
    ap.add_argument("--no-state", action="store_true", help="do not print state heartbeats")
    args = ap.parse_args()

    if os.path.exists(args.socket):
        os.unlink(args.socket)  # left over from a listener that did not shut down
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 18)
    s.bind(args.socket)
    out = open(args.out, "a") if args.out else None
    print(f"listening on {args.socket}", file=sys.stderr, flush=True)
    try:
        while True:
            data = s.recv(65536)
            text = data.decode(errors="replace")
            try:
                event = json.loads(text)
            except ValueError:
                print(f"not JSON: {text!r}", file=sys.stderr, flush=True)
                continue
            line = json.dumps(dict(event, received=round(time.time(), 3)))
            if out:
                out.write(line + "\n")
                out.flush()
            if not (args.no_state and event.get("event") == "state"):
                print(line, flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        os.unlink(args.socket)


if __name__ == "__main__":
    main()
