#!/usr/bin/env python3
"""Write songs.csv and tone_catalog.csv (in the data folder) from the song index, with each tone's
preset from presets.json. Run after editing presets.json to see the effect on all songs."""
import collections
import csv
import json
import os

import paths
from presets import Presets

SLOTS = ["Base", "A", "B", "C", "D"]

paths.ensure_data_dir()
presets = Presets()
tones, uses = {}, collections.defaultdict(set)
with open(paths.SONGS_CSV, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["artist", "song", "song_key", "arrangement", "path", "tone_changes"] +
               [f"tone_{s}" for s in SLOTS] + [f"preset_{s}" for s in SLOTS] + ["source"])
    for line in open(paths.INDEX):
        a = json.loads(line)
        if a["path"] == "Vocals":
            continue
        defs = {t["key"].lower(): t for t in a["tones"]}
        row_presets = []
        for i, key in enumerate(a["slots"]):
            if not key:
                row_presets.append("")
                continue
            t = defs.get(key.lower(), {"key": key, "descriptors": [], "gear": []})
            tones.setdefault(key.lower(), t)
            uses[key.lower()].add(f"{a['artist']} - {a['song']} ({a['path']})")
            row_presets.append(presets.get(a["arrangement"], SLOTS[i], key, t["descriptors"], artist=a["artist"],
                                           amp=t.get("amp", ""), gain=t.get("gain"))[0])
        w.writerow([a["artist"], a["song"], a["songKey"], a["arrangement"], a["path"], len(a["changes"])] +
                   a["slots"] + row_presets + [os.path.basename(a["source"])])

with open(paths.TONE_CATALOG_CSV, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["tone_key", "descriptors", "preset", "matched_by", "amp", "gain", "pedals", "song_count",
                "example_songs"])
    for key, t in sorted(tones.items(), key=lambda kv: -len(uses[kv[0]])):
        preset, why = presets.get("", "", t["key"], t["descriptors"], amp=t.get("amp", ""), gain=t.get("gain"))
        gear = [g.split("=", 1) for g in t.get("gear", [])]
        amp = next((v for k, v in gear if k == "Amp"), "")
        pedals = " ".join(v for k, v in gear if "Pedal" in k)
        ex = sorted(uses[key])
        gain = "" if t.get("gain") is None else f"{t['gain']:g}"
        w.writerow([t["key"], " ".join(t["descriptors"]), preset, why, amp, gain, pedals, len(ex), "; ".join(ex[:3])])
print(f"{paths.SONGS_CSV} and {paths.TONE_CATALOG_CSV} written: {len(tones)} tones")
