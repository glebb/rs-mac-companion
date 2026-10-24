#!/usr/bin/env python3
"""Experimental: ask an OpenAI model what each song in the index is (its style: Soft, Classic rock,
Metal, ...) and whether its distorted tones should be Crunch or Heavy. RS Companion (which can ask
about each new song itself, AIClassifier.swift) and presets.py use the answers between the rules
and your own entries in presets.json, which stays as it is.

The model gets what the rules already know (tuning, tempo, heaviness, the style and categories the
rules pick, the amps) plus the artist and title, and corrects the rules from what the records
sound like: Rocksmith tones often have more gain than the song, so a Bon Jovi song comes out Heavy
where Crunch fits.

Writes to the data folder (see paths.py):
  ai_classified.json   the model's answer per song key (shared with RS Companion), so later runs
                       only ask about new songs; each song's own answer is used for it
  ai_suggestions.json  "song_styles" and "artists" entries in presets.json's format where the
                       model disagrees with the rules, used for songs without an answer (e.g. a
                       new song by a band it knows), plus "_songs": one row per disagreement with
                       the model's reason, for review. Your own song_styles and artists in
                       presets.json win over both.
The rules are compared without the current suggestions, so a run never mistakes them for the rules.

Sends artist names, song titles and the numbers above to the OpenAI API. Needs the openai
package (pip install openai) and an API key in OPENAI_API_KEY.

Usage: classify_songs.py [--model ID] [--batch N] [--limit N] [--redo]
"""
import argparse
import collections
import json
import os
import sys
import time

import paths
import rig
from presets import Presets

CLASSIFIED = paths.AI_CLASSIFIED
DEFAULT_STYLES = [{"name": "Soft"}, {"name": "Classic rock", "from": 0.3}, {"name": "Metal", "from": 0.75}]
SLOTS = ["Base", "A", "B", "C", "D"]

SYSTEM = """You classify songs for a guitar practice tool that switches the player's amp presets \
while they play Rocksmith. For each song you get its artist, title and what the tool's rules \
measured from the Rocksmith tones. The rules only see amp gain knobs, and Rocksmith tone designers \
often turn the gain up past what the record sounds like, so judge from how the original recording \
sounds, using the measurements as a hint.

For each song answer:
- style: the one of the given styles that fits the recording best.
- distortion: how the song's distorted guitar parts sound on the record. "crunch" is edge-of- \
breakup to classic rock overdrive (AC/DC, Bon Jovi, Led Zeppelin, most 60s-80s rock); "heavy" is \
high-gain distortion (metal, hard rock with saturated rhythm tones, grunge with fuzz). Use "none" \
only when the song has no distorted guitar at all.
- confidence: "high" when you know the recording, "medium" when you know the artist's sound but \
not this song, "low" when you are guessing from the measurements.
- reason: at most 12 words.

Answer for every song key you are given, using the key exactly as written."""


def styles(presets):
    """presets.json's "styles" (or what they were called before), as the app reads them."""
    d = presets.data
    return d.get("styles") or d.get("banks") or d.get("rigs") or DEFAULT_STYLES


def rule_style(presets, heaviness, artist, song_key):
    """The style the app gives a song today (Presets.swift style()): song_styles by song key or
    artist, else the last style whose "from" the heaviness reaches."""
    named = {k.strip().lower(): v for k, v in presets.data.get("song_styles", {}).items() if isinstance(v, str)}
    hit = named.get(song_key.lower()) or named.get(artist.strip().lower())
    if hit:
        return hit
    h = heaviness or 0
    picked = styles(presets)[0]["name"]
    for s in styles(presets):
        if h >= s.get("from", 0):
            picked = s["name"]
    return picked


def songs_from_index(presets):
    """One summary per song: what the model is told, and the rules' answers to compare with."""
    arrangements = [a for a in map(json.loads, open(paths.INDEX)) if a["path"] != "Vocals"]
    by_song = collections.defaultdict(list)
    for a in arrangements:
        by_song[a["songKey"].lower()].append(a)
    songs = {}
    for key, arrs in by_song.items():
        first = arrs[0]
        heaviness = rig.song_heaviness(arrs)
        cats, amps = collections.Counter(), collections.Counter()
        tuning = None
        for a in arrs:
            if a["path"] not in rig.GUITAR_PATHS:
                continue
            tuning = tuning or rig.tuning_name(a.get("tuning"))
            for i, tone_key in enumerate(a["slots"]):
                t = tone_key and rig.tone_def(a, tone_key)
                if not t:
                    continue
                d = rig.drive(t["rig"], t.get("gain")) if t.get("rig") else None
                preset, _ = presets.get(a["arrangement"], SLOTS[i], tone_key, t["descriptors"],
                                        artist=a["artist"], amp=t.get("amp", ""), gain=t.get("gain"), drive=d)
                cats[presets.category(preset)] += 1
                if t.get("amp"):
                    amps[t["amp"].removeprefix("Amp_")] += 1
        songs[key] = {
            "song_key": first["songKey"], "artist": first["artist"].strip(), "song": first["song"].strip(),
            "tuning": tuning, "tempo": first.get("tempo"), "heaviness": heaviness,
            "rule_style": rule_style(presets, heaviness, first["artist"], first["songKey"]),
            "rule_categories": dict(cats), "amps": [a for a, _ in amps.most_common(3)],
        }
    return songs


def describe(s):
    """One line per song for the prompt."""
    h = "?" if s["heaviness"] is None else f"{s['heaviness']:.2f}"
    tempo = f"{s['tempo']:g} bpm" if s["tempo"] else "tempo ?"
    cats = ", ".join(f"{n} {c}" for c, n in sorted(s["rule_categories"].items())) or "no guitar tones"
    return (f"{s['song_key']} | {s['artist']} - {s['song']} | {s['tuning'] or 'tuning ?'}, {tempo} | "
            f"heaviness {h}, rules say {s['rule_style']} | tones: {cats} | amps: {', '.join(s['amps']) or '?'}")


def schema(style_names):
    item = {
        "type": "object",
        "properties": {
            "song_key": {"type": "string"},
            "style": {"type": "string", "enum": style_names},
            "distortion": {"type": "string", "enum": ["crunch", "heavy", "none"]},
            "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
            "reason": {"type": "string"},
        },
        "required": ["song_key", "style", "distortion", "confidence", "reason"],
        "additionalProperties": False,
    }
    return {"type": "object", "properties": {"songs": {"type": "array", "items": item}},
            "required": ["songs"], "additionalProperties": False}


def classify(client, model, batch, style_names):
    """The model's answers for a batch of song summaries, by lowercased song key."""
    import openai
    prompt = (f"Styles: {', '.join(style_names)}\n\nSongs (key | artist - title | tuning, tempo | "
              f"rules' heaviness 0-1 and style | categories the rules give its tones | main amps):\n"
              + "\n".join(describe(s) for s in batch))
    for attempt in range(3):
        try:
            response = client.responses.create(
                model=model, instructions=SYSTEM, input=prompt, reasoning={"effort": "low"},
                text={"format": {"type": "json_schema", "name": "songs", "strict": True,
                                 "schema": schema(style_names)}},
            )
            break
        except (openai.RateLimitError, openai.APIConnectionError, openai.InternalServerError) as e:
            if attempt == 2:
                raise
            print(f"  {type(e).__name__}, retrying", file=sys.stderr, flush=True)
            time.sleep(10 * (attempt + 1))
    if response.status != "completed" or not response.output_text:
        why = getattr(response.incomplete_details, "reason", None) or response.status
        print(f"  no answer ({why}); this batch is asked again next run", file=sys.stderr, flush=True)
        return {}
    text = response.output_text
    wanted = {s["song_key"].lower() for s in batch}
    return {r["song_key"].lower(): r for r in json.loads(text)["songs"] if r["song_key"].lower() in wanted}


def suggest(songs, answers):
    """presets.json entries where the model disagrees with the rules.

    Styles: an artist entry when all of the artist's answered songs agree on one style that differs
    from the rules for at least one of them; otherwise one entry per song that differs.
    Distortion: the artists section remaps a category for the whole band, so Heavy -> Crunch when
    the model says crunch for every song of the artist whose tones the rules put in Heavy (and
    Crunch -> Heavy the other way round). Low-confidence answers are left out of both."""
    by_artist = collections.defaultdict(list)
    for key, s in songs.items():
        a = answers.get(key)
        if a and a["confidence"] != "low":
            by_artist[s["artist"]].append((s, a))
    song_styles, artists, rows = {}, {}, []
    for artist, pairs in sorted(by_artist.items(), key=lambda kv: kv[0].lower()):
        differs = [(s, a) for s, a in pairs if a["style"].lower() != s["rule_style"].lower()]
        voted = {a["style"] for _, a in pairs}
        if differs and len(voted) == 1:
            song_styles[artist] = voted.pop()
        else:
            for s, a in differs:
                song_styles[s["song_key"]] = a["style"]
        to_crunch = [(s, a) for s, a in pairs if s["rule_categories"].get("Heavy")]
        to_heavy = [(s, a) for s, a in pairs if s["rule_categories"].get("Crunch")]
        remap = {}
        if to_crunch and all(a["distortion"] == "crunch" for _, a in to_crunch):
            remap["Heavy"] = "Crunch"
        if to_heavy and all(a["distortion"] == "heavy" for _, a in to_heavy):
            remap["Crunch"] = "Heavy"
        if remap:
            artists[artist] = remap
        for s, a in pairs:
            style_change = a["style"].lower() != s["rule_style"].lower()
            drive_change = any(s["rule_categories"].get(c) for c in remap)
            if style_change or drive_change:
                rows.append({"song_key": s["song_key"], "artist": artist, "song": s["song"],
                             "rule_style": s["rule_style"], "ai_style": a["style"],
                             "rule_categories": s["rule_categories"], "ai_distortion": a["distortion"],
                             "confidence": a["confidence"], "reason": a["reason"]})
    return song_styles, artists, rows


def read_json(path):
    """The JSON object in a file, or {} if there is none."""
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def write_json(path, data, **dump_args):
    """Writes a JSON file in one step (a temporary file renamed into place), so RS Companion, which
    reads these files while it runs, never sees half of one."""
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, **dump_args)
        f.write("\n")
    os.replace(tmp, path)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--model", default="gpt-6-luna")
    p.add_argument("--batch", type=int, default=100, help="songs per request")
    p.add_argument("--limit", type=int, help="ask about at most this many new songs (to try it out)")
    p.add_argument("--redo", action="store_true",
                   help="ask again about songs already answered (with --limit, only that many; other answers stay)")
    args = p.parse_args()

    paths.ensure_data_dir()
    presets = Presets(ai_path=None)  # the rules alone
    songs = songs_from_index(presets)
    answers = read_json(CLASSIFIED)
    todo = [s for k, s in sorted(songs.items()) if args.redo or k not in answers][:args.limit]

    if todo:
        try:
            import openai
        except ImportError:
            sys.exit("needs the openai package: pip install openai")
        if not os.environ.get("OPENAI_API_KEY"):
            sys.exit("set OPENAI_API_KEY first")
        client = openai.OpenAI()
        style_names = [s["name"] for s in styles(presets)]
        for i in range(0, len(todo), args.batch):
            batch = todo[i:i + args.batch]
            print(f"asking {args.model} about songs {i + 1}-{i + len(batch)} of {len(todo)}", flush=True)
            new = {key: dict(a, model=args.model) for key, a in classify(client, args.model, batch, style_names).items()}
            # After every batch, so an interrupted run keeps its answers; merged into the file as it is
            # now, so answers RS Companion saved meanwhile stay.
            answers = {**read_json(CLASSIFIED), **new}
            write_json(CLASSIFIED, answers, indent=1, sort_keys=True)

    song_styles, artists, rows = suggest(songs, answers)
    write_json(paths.AI_SUGGESTIONS,
               {"_help": ["Suggestions from classify_songs.py where the model disagrees with the rules.",
                          "song_styles and artists use presets.json's format and count after your own entries",
                          "there (reason 'AI'). _songs says why, per song. Delete this file to turn them off."],
                "song_styles": song_styles, "artists": artists, "_songs": rows}, indent=2)
    print(f"{sum(k in answers for k in songs)} of {len(songs)} songs answered; {len(song_styles)} style and {len(artists)} artist "
          f"suggestions in {paths.AI_SUGGESTIONS}")


if __name__ == "__main__":
    main()
