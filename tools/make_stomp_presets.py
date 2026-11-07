#!/usr/bin/env python3
"""Makes the HX Stomp's presets per amp, and the profile that plays them, from hx-stomp-presets/amps.json.

    tools/make_stomp_presets.py [--first N]

Writes hx-stomp-presets/amps/*.hlx, one preset per Helix amp, named by its slot, and
profiles/hx-stomp-amps.json. --first N makes only the first N, to try them. Every preset is the
chain of Classic Rock.hlx with another amp and its default cab, Line 6's defaults read from the
HX Edit install. The tone's settings arrive by MIDI: what each CC does is in KNOBS and in
hx-stomp-presets/README.md. Snapshots keep the compressor, the drive block and a level trim.
"""
import argparse, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRESETS = os.path.join(ROOT, "hx-stomp-presets")
RES = "/Applications/Line6/HX Edit.app/Contents/Resources"
FIRST_PC = 3                # 01A-01C are the presets by style
BUDGET = 75.0               # the Stomp's DSP, inferred: see hx-stomp-presets/README.md
LOAD_WAIT_MS = 500          # CCs right after a preset change can be lost
LEAD_LIFT = 1.41            # Ch Vol at CC 20 = 127: about +3 dB
CAB_CUTS = {"LowCut": 80.0, "HighCut": 9000.0}
SNAPSHOT_LEVEL_DB = [3.0, 1.0, -1.0]    # Clean, Crunch, Heavy, until they are measured
GAIN = ["Drive", "Gain", "DriveNorm", "Ch1Drive", "Ch2Drive", "Norm Drive"]
GAIN_FIRST = {"AmpAguaSledge": "Gain"}  # its Drive is a second stage, at 0 by default
GAIN_RANGE, HIGH_GAIN_RANGE = (0.05, 0.85), (0.05, 0.6)     # the amp's gain at drive 0 and 1
# CC: (the tone's setting, its range if not the app's default, block, parameter, value at CC 0, at CC 127)
AMP, CHORUS, DELAY, REVERB = "block2", "block5", "block6", "block7"
KNOBS = [(27, "bass", None, AMP, "Bass", 0, 1), (28, "mid", None, AMP, "Mid", 0, 1), (29, "treble", None, AMP, "Treble", 0, 1),
         (30, "presence", None, AMP, "Presence", 0, 1),
         (31, "delay_time", None, DELAY, "Time", 0, 2), (33, "delay_feedback", None, DELAY, "Feedback", 0, 1),
         (34, "delay_mix", None, DELAY, "Mix", 0, 1), (35, "reverb_mix", None, REVERB, "Mix", 0, 1),
         (36, "modulation_mix", None, CHORUS, "Mix", 0, 1)]
GAIN_CC, LEAD_CC = 26, 20


def models():
    out = {}
    for f in os.listdir(RES):
        if f.endswith(".models"):
            data = json.load(open(os.path.join(RES, f)))
            for m in data if isinstance(data, list) else []:
                if isinstance(m, dict) and m.get("symbolicID"):
                    out[m["symbolicID"]] = m
    return out


def defaults(m):
    return {p["symbolicID"]: p["default"] for p in m["params"] if not p["symbolicID"].startswith("@") and "default" in p}


def midi(lo, hi, cc):
    return {"@min": lo, "@max": hi, "@controller": 8, "@cc": cc, "@snapshot_disable": False}


def slot_name(pc):
    return "%02d%s" % (pc // 3 + 1, "ABC"[pc % 3])


def preset(amp, frame, M, high_gain):
    h = json.loads(json.dumps(frame))
    h["data"]["meta"]["name"] = amp[3:][:16]
    t = h["data"]["tone"]
    d = t["dsp0"]
    m = M["HD2_" + amp]
    block = {k: v for k, v in d[AMP].items() if k.startswith("@")}
    block["@model"] = m["symbolicID"]
    block.update(defaults(m))
    d[AMP] = block
    cab = M[m["ircablink"]]
    d["cab0"] = {"@model": cab["symbolicID"], "@enabled": True, **defaults(cab), **CAB_CUTS}

    gain = GAIN_FIRST.get(amp) or next(p for p in GAIN if p in block)
    volume = "ChVol" if "ChVol" in block else "Ch Vol"
    lo, hi = HIGH_GAIN_RANGE if amp in high_gain else GAIN_RANGE
    amp_controls = {gain: midi(lo, hi, GAIN_CC)}
    block[volume] = round(min(block[volume], 1 / LEAD_LIFT), 3)     # room for the whole lift
    amp_controls[volume] = midi(block[volume], round(block[volume] * LEAD_LIFT, 3), LEAD_CC)
    controls = {AMP: amp_controls, "cab0": t["controller"]["dsp0"]["cab0"]}
    for cc, _, _, where, param, low, high in KNOBS:
        if param in d[where]:
            controls.setdefault(where, {})[param] = midi(low, high, cc)
    t["controller"]["dsp0"] = controls

    for i, level in enumerate(SNAPSHOT_LEVEL_DB):
        s = t["snapshot%d" % i]
        s["controllers"]["dsp0"] = {"cab0": {"Level": {"@fs_enabled": False, "@value": level}}}
    d["cab0"]["Level"] = SNAPSHOT_LEVEL_DB[0]
    return h


def check(h, M):
    """What the Stomp would refuse or a typo would break, and the DSP. Returns the load."""
    t = h["data"]["tone"]
    d = t["dsp0"]
    blocks = [k for k in d if k.startswith("block")]
    assert len(blocks) == 8, blocks
    load = 0.0
    for key in blocks + ["cab0"]:
        b = d[key]
        m = M[b["@model"]]
        load += m.get("load_stereo", m.get("load", 0)) if b.get("@stereo") or "load" not in m else m["load"]
        known = {p["symbolicID"]: p for p in m["params"]}
        for name, value in b.items():
            if name.startswith("@"):
                continue
            assert name in known, (b["@model"], name)
            p = known[name]
            if isinstance(value, (int, float)) and not isinstance(value, bool) and "min" in p:
                assert p["min"] <= value <= p["max"], (b["@model"], name, value)
    for key, params in t["controller"]["dsp0"].items():
        known = {p["symbolicID"]: p for p in M[d[key]["@model"]]["params"]}
        for name, c in params.items():
            assert name in d[key], (key, name)
            assert known[name]["min"] <= c["@min"] and c["@max"] <= known[name]["max"], (key, name, c)
    ccs = [c["@cc"] for params in t["controller"]["dsp0"].values() for c in params.values() if "@cc" in c]
    ccs += [f["@cc"] for f in t["footswitch"]["dsp0"].values()]
    assert len(ccs) == len(set(ccs)), ccs
    return load


def profile(slots, amps):
    """A DI is what acoustic parts use: it says nothing of the song's amp, so it doesn't pick a preset."""
    pc = {amp: FIRST_PC + i for i, amp in enumerate(slots)}
    load = ",\n".join('    "%s": [{"pc": %d}, {"wait_ms": %d}]' % (game, pc[amp], LOAD_WAIT_MS)
                      for game, amp in sorted(amps.items()) if amp in pc and not game.startswith("DI_"))
    knobs = ['{"cc": %d, "from": "drive"}' % GAIN_CC] + ['{"cc": %d, "from": "%s"}' % (k[0], k[1]) for k in KNOBS]
    return """{
  "name": "HX Stomp by amp",
  "comment": "A preset per Helix amp, made by tools/make_stomp_presets.py; a style's preset for any other amp. Setup: hx-stomp-presets/README.md.",
  "destination": "HX Stomp",
  "channel": 1,
  "song_load": {
    "Soft":         [{"pc": 0}, {"wait_ms": 500}],
    "Classic rock": [{"pc": 1}, {"wait_ms": 500}],
    "Metal":        [{"pc": 2}, {"wait_ms": 500}]
  },
  "amp_load": {
%s
  },
  "category": {
    "Clean":  [{"cc": 69, "value": 0}, {"cc": 20, "value": 0}],
    "Crunch": [{"cc": 69, "value": 1}, {"cc": 20, "value": 0}],
    "Heavy":  [{"cc": 69, "value": 2}, {"cc": 20, "value": 0}],
    "Lead":   [{"cc": 69, "value": 2}, {"cc": 20, "value": 127}]
  },
  "effects": {
    "chorus": 21, "flanger": 21,
    "phaser": 22, "vibe": 22,
    "tremolo": 23,
    "delay": 24,
    "reverb": 25
  },
  "knobs": [
    %s
  ]
}
""" % (load, ",\n    ".join(knobs))


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--first", type=int)
    args = a.parse_args()
    if not os.path.isdir(RES):
        sys.exit("HX Edit isn't at " + RES)
    M = models()
    spec = json.load(open(os.path.join(PRESETS, "amps.json")))
    frame = json.load(open(os.path.join(PRESETS, "Classic Rock.hlx")))
    slots = spec["slots"][:args.first]
    out = os.path.join(PRESETS, "amps")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith(".hlx"):
            os.remove(os.path.join(out, f))
    worst = 0.0
    for i, amp in enumerate(slots):
        h = preset(amp, frame, M, spec["high_gain"])
        load = check(h, M)
        if load > BUDGET:
            sys.exit("%s: %.2f is over the DSP budget" % (amp, load))
        worst = max(worst, load)
        name = "%s %s.hlx" % (slot_name(FIRST_PC + i), amp[3:])
        json.dump(h, open(os.path.join(out, name), "w"), indent=1, sort_keys=True)
        print("%s  %.2f DSP" % (name, load))
    open(os.path.join(ROOT, "profiles", "hx-stomp-amps.json"), "w").write(profile(slots, spec["amps"]))
    print("%d presets, heaviest %.2f of %.1f" % (len(slots), worst, BUDGET))


if __name__ == "__main__":
    main()
