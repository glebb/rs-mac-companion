"""Tone -> preset mapping shared by rstone.py and make_catalog.py.

The rules live in presets.json in the data folder (seeded from presets.default.json)."""
import json
import os
import re

import paths


class Presets:
    def __init__(self, path=paths.PRESETS):
        self.path, self.mtime, self.data = path, 0, {}
        self.reload()

    def reload(self):
        """Re-read presets.json if it changed, so mappings can be tuned while playing."""
        try:
            m = os.path.getmtime(self.path)
            if m != self.mtime:
                self.data, self.mtime = json.load(open(self.path)), m
        except (OSError, ValueError):
            pass

    def get(self, arrangement, slot, key, descriptors):
        """Returns (preset, reason)."""
        self.reload()
        d = self.data
        song = d.get("songs", {}).get(arrangement, {})
        if slot in song:
            return song[slot], "song override"
        tones = {k.lower(): v for k, v in d.get("tones", {}).items()}
        if key.lower() in tones:
            return tones[key.lower()], "tone override"
        tags = {x.upper() for x in descriptors}
        words = set(re.findall(r"[a-z]+", key.lower()))
        for r in d.get("rules", []):
            if "all" in r and not set(r["all"]) <= tags:
                continue
            if "any" in r and tags & set(r["any"]):
                return r["preset"], "tags " + "+".join(sorted(tags))
            if "name" in r and any(w in words or (len(w) >= 4 and w in key.lower()) for w in r["name"]):
                return r["preset"], "name"
        return d.get("default"), "default"
