#!/usr/bin/env python3
"""Build/refresh the tone index of all Rocksmith 2014 (Mac) song archives.

Only archives that are new or changed since the last run are read again, so new songs are
picked up by simply running this again (rstone runs it on startup).

Writes to the data folder (see paths.py):
  tones_index.jsonl   one JSON object per arrangement (song, artist, tone slots, tone timeline)
  index_cache.json    per-archive cache (size + mtime -> arrangements)
Archive paths are stored relative to the game folder.

Archives are read with build/rstool (native/rsfile.c).

Usage: index_songs.py [--game-dir DIR] [--rstool PATH]
"""
import argparse
import json
import os
import subprocess
import sys
import time

import paths

BATCH = 50
FORMAT = 4  # bump when rstool's output changes (2: tones have amp and gain; 3: rig, tuning, tempo; 4: length)


def archives(game_dir):
    """Song archives the Mac game reads: songs.psarc plus everything under dlc/ except PC (_p) files."""
    songs = os.path.join(game_dir, "songs.psarc")
    if os.path.exists(songs):
        yield songs
    for root, _, files in os.walk(os.path.join(game_dir, "dlc")):
        for f in sorted(files):
            if f.endswith(".psarc") and not f.endswith("_p.psarc"):
                yield os.path.join(root, f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", default=paths.GAME_DIR)
    ap.add_argument("--rstool", default=paths.RSTOOL)
    args = ap.parse_args()
    paths.ensure_data_dir()
    if not os.path.exists(args.rstool):
        sys.exit(f"{args.rstool} not found: run ./build.sh first")

    cache_path = paths.INDEX_CACHE
    try:
        cache = json.load(open(cache_path))
    except (OSError, ValueError):
        cache = {}
    if cache.get("_format") != FORMAT:  # written by an older rstool: read everything again
        cache = {}

    files = list(archives(args.game_dir))
    rel = {f: os.path.relpath(f, args.game_dir) for f in files}
    fresh, todo, failed = {}, [], []
    started = time.time()
    for p in files:
        st = os.stat(p)
        stamp = f"{st.st_size}:{int(st.st_mtime)}"
        if rel[p] in cache and cache[rel[p]]["stamp"] == stamp:
            fresh[rel[p]] = cache[rel[p]]
        else:
            fresh[rel[p]] = {"stamp": stamp, "arrangements": []}
            todo.append(p)

    # Several archives per rstool run (it reads one at a time, so memory stays small).
    for b in range(0, len(todo), BATCH):
        batch = todo[b:b + BATCH]
        r = subprocess.run([args.rstool, "tones", *batch], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            try:
                a = json.loads(line)
            except ValueError:
                continue
            src = os.path.relpath(a.get("source", ""), args.game_dir)
            if src in fresh:
                a["source"] = src
                fresh[src]["arrangements"].append(a)
        for line in r.stderr.splitlines():
            if line.startswith("FAILED "):
                path = line[7:]
                failed.append((os.path.relpath(path, args.game_dir), ["not a readable archive"]))
        print(f"  read {min(b + BATCH, len(todo))}/{len(todo)} archives", file=sys.stderr, flush=True)
    read_count = len(todo)

    json.dump({"_format": FORMAT, **fresh}, open(cache_path, "w"))
    with open(paths.INDEX, "w") as out:
        for p in files:
            for a in fresh[rel[p]]["arrangements"]:
                out.write(json.dumps(a) + "\n")
    total = sum(len(v["arrangements"]) for v in fresh.values())
    print(f"indexed {len(files)} archives ({read_count} read, {len(files) - read_count} cached), "
          f"{total} arrangements, {len(failed)} failed, {time.time() - started:.0f}s", file=sys.stderr)
    for p, err in failed:
        print(f"  FAILED {p}: {err[0]}", file=sys.stderr)


if __name__ == "__main__":
    main()
