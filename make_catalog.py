#!/usr/bin/env python3
"""Write songs.csv and tone_catalog.csv (in the data folder) from the song index, with each tone's
preset from presets.json and what its rig does (rig.py): drive 0-1 (clean / crunch / heavy) and its
delay, reverb and modulation; and each song's tuning, tempo and heaviness. Run after editing
presets.json to see the effect on all songs."""
import collections
import csv
import json
import os

import paths
import rig
from presets import Presets

SLOTS = ["Base", "A", "B", "C", "D"]

paths.ensure_data_dir()
presets = Presets()

def num(x):
    return "" if x is None else f"{x:.2f}" if isinstance(x, float) and x < 1 else f"{x:g}"


def effect_text(fx):
    """'delay 320ms mix 25', 'reverb mix 30', 'chorus mix 40'."""
    parts = []
    if "delay" in fx:
        d = fx["delay"]
        parts.append(f"delay {num(d['time'])}ms mix {num(d['mix'])}")
    if "reverb" in fx:
        parts.append(f"reverb mix {num(fx['reverb']['mix'])}")
    if "mod" in fx:
        parts.append(f"{fx['mod']['kind']} mix {num(fx['mod']['mix'])}")
    return "; ".join(parts)


arrangements = [a for a in map(json.loads, open(paths.INDEX)) if a["path"] != "Vocals"]
songs = collections.defaultdict(list)
for a in arrangements:
    songs[a["artist"].lower(), a["songKey"].lower()].append(a)
heaviness = {k: rig.song_heaviness(v) for k, v in songs.items()}

tones, uses = {}, collections.defaultdict(set)
with open(paths.SONGS_CSV, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["artist", "song", "song_key", "arrangement", "path", "tuning", "tempo", "song_heaviness",
                "tone_changes"] + [f"tone_{s}" for s in SLOTS] + [f"preset_{s}" for s in SLOTS] +
               [f"drive_{s}" for s in SLOTS] + ["source"])
    for a in arrangements:
        row_presets, row_drives = [], []
        for i, key in enumerate(a["slots"]):
            if not key:
                row_presets.append("")
                row_drives.append("")
                continue
            t = rig.tone_def(a, key) or {"key": key, "descriptors": [], "gear": []}
            tones.setdefault(key.lower(), t)
            uses[key.lower()].add(f"{a['artist']} - {a['song']} ({a['path']})")
            row_presets.append(presets.get(a["arrangement"], SLOTS[i], key, t["descriptors"], artist=a["artist"],
                                           amp=t.get("amp", ""), gain=t.get("gain"),
                                           drive=rig.drive(t.get("rig") or {}, t.get("gain")))[0])
            row_drives.append(num(rig.drive(t.get("rig") or {}, t.get("gain"))))
        tuning = rig.tuning_name(a.get("tuning"), bass=a["path"] == "Bass")
        w.writerow([a["artist"], a["song"], a["songKey"], a["arrangement"], a["path"], tuning or "",
                    num(a.get("tempo")), num(heaviness[a["artist"].lower(), a["songKey"].lower()]), len(a["changes"])] +
                   a["slots"] + row_presets + row_drives + [os.path.basename(a["source"])])

with open(paths.TONE_CATALOG_CSV, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["tone_key", "descriptors", "preset", "matched_by", "amp", "gain", "pedals", "drive", "band",
                "effects", "song_count", "example_songs"])
    for key, t in sorted(tones.items(), key=lambda kv: -len(uses[kv[0]])):
        preset, why = presets.get("", "", t["key"], t["descriptors"], amp=t.get("amp", ""), gain=t.get("gain"),
                                  drive=rig.drive(t.get("rig") or {}, t.get("gain")))
        gear = [g.split("=", 1) for g in t.get("gear", [])]
        amp = next((v for k, v in gear if k == "Amp"), "")
        pedals = " ".join(v for k, v in gear if "Pedal" in k)
        ex = sorted(uses[key])
        gain = "" if t.get("gain") is None else f"{t['gain']:g}"
        d = rig.drive(t.get("rig") or {}, t.get("gain"))
        w.writerow([t["key"], " ".join(t["descriptors"]), preset, why, amp, gain, pedals, num(d), rig.band(d),
                    effect_text(rig.effects(t.get("rig") or {})), len(ex), "; ".join(ex[:3])])
print(f"{paths.SONGS_CSV} and {paths.TONE_CATALOG_CSV} written: {len(tones)} tones")
