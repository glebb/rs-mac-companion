"""Tone -> preset mapping shared by rstone.py and make_catalog.py.

The rules live in presets.json in the data folder (seeded from presets.default.json)."""
import json
import os
import re

import paths

CATEGORIES = ["Clean", "Crunch", "Heavy", "Lead"]
# Preset names used before categories existed, for files without a "categories" section.
BUILTIN_CATEGORIES = {"distortion": "Heavy", "acoustic": "Clean", "bass": "Clean", "bass drive": "Crunch"}


def amp_name(amp):
    """'Amp_HG500' and 'HG500' both -> 'hg500'."""
    amp = (amp or "").lower()
    return amp[4:] if amp.startswith("amp_") else amp


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

    def category(self, preset):
        """The category (Clean, Crunch, Heavy, Lead) a preset name means."""
        for c in CATEGORIES:
            if c.lower() == preset.lower():
                return c
        mapped = {k.lower(): v for k, v in self.data.get("categories", {}).items()}.get(preset.lower(), "")
        for c in CATEGORIES:
            if c.lower() == mapped.lower():
                return c
        return BUILTIN_CATEGORIES.get(preset.lower(), "Clean")

    def get(self, arrangement, slot, key, descriptors, artist="", amp="", gain=None):
        """Returns (preset, reason). amp is the tone's amp key and gain its gain knob (0-100, or
        None if unknown)."""
        self.reload()
        d = self.data
        song = d.get("songs", {}).get(arrangement, {})
        if slot in song:
            return song[slot], "song override"
        tones = {k.lower(): v for k, v in d.get("tones", {}).items()}
        if key.lower() in tones:
            return tones[key.lower()], "tone override"
        preset, why = self.rule(key, descriptors, amp, gain)
        artists = {k.strip().lower(): v for k, v in d.get("artists", {}).items()}
        remap = artists.get((artist or "").strip().lower())
        if isinstance(remap, dict):
            remap = {k.lower(): v for k, v in remap.items()}
            new = remap.get(preset.lower()) or remap.get(self.category(preset).lower())
            if new:
                return new, f"{why}, artist {artist.strip()}"
        return preset, why

    def rule(self, key, descriptors, amp, gain):
        """The rules and the default: (preset, reason)."""
        d = self.data
        tags = {x.upper() for x in descriptors}
        words = set(re.findall(r"[a-z]+", key.lower()))
        for r in d.get("rules", []):
            if "all" in r and not set(r["all"]) <= tags:
                continue
            if "amp" in r and amp_name(amp) not in {amp_name(a) for a in r["amp"]}:
                continue
            if "gain" in r and (gain is None or gain < r["gain"]):
                continue
            gear = ""
            if "amp" in r or "gain" in r:
                gear = f", amp {amp_name(amp) or '?'} gain " + ("?" if gain is None else f"{gain:g}")
            if "any" in r and tags & set(r["any"]):
                return r["preset"], "tags " + "+".join(sorted(tags)) + gear
            if "name" in r and any(w in words or (len(w) >= 4 and w in key.lower()) for w in r["name"]):
                return r["preset"], "name" + gear
            if "any" not in r and "name" not in r:
                return r["preset"], "tags " + "+".join(sorted(tags)) + gear
        return d.get("default"), "default"
