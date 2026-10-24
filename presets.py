"""Tone -> preset mapping shared by rstone.py and make_catalog.py.

The rules live in presets.json in the data folder (seeded from presets.default.json). Where
presets.json's "artists" has nothing for a tone's category, an AI model may change it (reason "AI"):
the song's own answer in ai_classified.json ("crunch" turns Heavy into Crunch, "heavy" Crunch into
Heavy), or for a song without one, the artist-wide "artists" in ai_suggestions.json. Songs listed in
presets.json's "ai_rejected" get neither. As Presets.swift."""
import json
import os
import re

import paths
import rig

CATEGORIES = ["Clean", "Crunch", "Heavy", "Lead"]
# Preset names used before categories existed, for files without a "categories" section.
BUILTIN_CATEGORIES = {"distortion": "Heavy", "acoustic": "Clean", "bass": "Clean", "bass drive": "Crunch"}


def amp_name(amp):
    """'Amp_HG500' and 'HG500' both -> 'hg500'."""
    amp = (amp or "").lower()
    return amp[4:] if amp.startswith("amp_") else amp


class Presets:
    def __init__(self, path=paths.PRESETS, ai_path=paths.AI_SUGGESTIONS, answers_path=paths.AI_CLASSIFIED):
        """ai_path None leaves out the AI (suggestions and answers): what the rules alone pick."""
        self.path, self.mtime, self.data = path, 0, {}
        self.ai_path, self.ai_mtime, self.ai = ai_path, 0, {}
        self.answers_path = answers_path if ai_path else None
        self.answers_mtime, self.answers = 0, {}
        self.reload()

    @staticmethod
    def _read(path, mtime, current):
        """(data, mtime) of an optional JSON file: as before if unchanged, empty if gone."""
        try:
            m = os.path.getmtime(path)
            return (json.load(open(path)), m) if m != mtime else (current, mtime)
        except OSError:
            return {}, 0
        except ValueError:
            return current, mtime

    def reload(self):
        """Re-read presets.json and the AI suggestions if they changed, so mappings can be tuned
        while playing."""
        try:
            m = os.path.getmtime(self.path)
            if m != self.mtime:
                self.data, self.mtime = json.load(open(self.path)), m
        except (OSError, ValueError):
            pass
        if self.ai_path:
            self.ai, self.ai_mtime = self._read(self.ai_path, self.ai_mtime, self.ai)
        if self.answers_path:
            self.answers, self.answers_mtime = self._read(self.answers_path, self.answers_mtime, self.answers)

    def answer(self, song_key):
        """The AI model's answer for a song key ({"style", "distortion", ...}), unless a guess."""
        a = self.answers.get(song_key.lower())
        return a if isinstance(a, dict) and a.get("confidence") != "low" else None

    def rejected(self, song_key):
        return song_key.lower() in {k.lower() for k in self.data.get("ai_rejected", [])}

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

    def get(self, arrangement, slot, key, descriptors, artist="", amp="", gain=None, drive=None):
        """Returns (preset, reason). amp is the tone's amp key, gain its gain knob (0-100) and
        drive how distorted its rig is (0-1, rig.drive), each None if unknown."""
        self.reload()
        d = self.data
        song = d.get("songs", {}).get(arrangement, {})
        if slot in song:
            return song[slot], "song override"
        tones = {k.lower(): v for k, v in d.get("tones", {}).items()}
        if key.lower() in tones:
            return tones[key.lower()], "tone override"
        preset, why = self.rule(key, descriptors, amp, gain, drive)
        new = self._remap(d, artist, preset)
        if new:
            return new, f"{why}, artist {(artist or '').strip()}"
        song_key = arrangement.rsplit("_", 1)[0]
        if not self.ai_path or self.rejected(song_key):
            return preset, why
        answer = self.answer(song_key)
        if answer:
            c = self.category(preset)
            if answer.get("distortion") == "crunch" and c == "Heavy":
                return "Crunch", f"{why}, AI"
            if answer.get("distortion") == "heavy" and c == "Crunch":
                return "Heavy", f"{why}, AI"
            return preset, why
        new = self._remap(self.ai, artist, preset)
        return (new, f"{why}, AI") if new else (preset, why)

    def _remap(self, source, artist, preset):
        """What an "artists" section maps the preset (or its category) to for this artist, if anything."""
        artists = {k.strip().lower(): v for k, v in source.get("artists", {}).items()}
        remap = artists.get((artist or "").strip().lower())
        if isinstance(remap, dict):
            remap = {k.lower(): v for k, v in remap.items()}
            return remap.get(preset.lower()) or remap.get(self.category(preset).lower())
        return None

    def rule(self, key, descriptors, amp, gain, drive=None):
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
            if "drive" in r and rig.band(drive) not in {b.lower() for b in r["drive"]}:
                continue
            gear = ""
            if "amp" in r or "gain" in r:
                gear = f", amp {amp_name(amp) or '?'} gain " + ("?" if gain is None else f"{gain:g}")
            if "drive" in r:
                gear += f", drive {drive:.2f} {rig.band(drive)}"
            if "any" in r and tags & set(r["any"]):
                return r["preset"], "tags " + "+".join(sorted(tags)) + gear
            if "name" in r and any(w in words or (len(w) >= 4 and w in key.lower()) for w in r["name"]):
                return r["preset"], "name" + gear
            if "any" not in r and "name" not in r:
                return r["preset"], "tags " + "+".join(sorted(tags)) + gear
        return d.get("default"), "default"
