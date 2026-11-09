#!/usr/bin/env python3
"""Makes the HX Stomp's presets per amp, and the profile that plays them, from hx-stomp-presets/amps.json.

    tools/make_stomp_presets.py [--first N]

Writes hx-stomp-presets/amps/*.hlx, one preset per Helix amp, named by its slot, and
profiles/hx-stomp-amps.json. --first N makes only the first N, to try them. A preset plays a tone as rs-tonehost
(rearmed-mods) plays it in Helix Native: the amp's input and Drive follow the game's gain knob, a Minotaur stands in
for a boost or overdrive pedal and a Swedish Chainsaw for a distortion, metal or fuzz pedal, the tone knobs are the
game's, and the level is set per tone, from calibration.json (tools/calibrate_stomp.py). The rest of the chain is
Classic Rock.hlx's, with Line 6's defaults read from the HX Edit install. What each CC does is in hx-stomp-presets/README.md.
"""
import argparse, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRESETS = os.path.join(ROOT, "hx-stomp-presets")
RES = "/Applications/Line6/HX Edit.app/Contents/Resources"
FIRST_PC = 3                # 01A-01C are the presets by style
BUDGET = 75.0               # the Stomp's DSP, inferred: see hx-stomp-presets/README.md
LOAD_WAIT_MS = 500          # CCs right after a preset change can be lost
LEAD_LIFT = 1.15            # Ch Vol at CC 20 = 127: about +1.2 dB, if Ch Vol is linear
LEAD_DELAY = {"beats": 0.75, "mix": 20, "feedback": 20}  # for a crunch or heavy lead with no delay: docs/device-profiles.md
PEDAL_GAIN = 0.98           # a pedal's gain knob at 100 onto its block's, as tonehost has it
GAIN = ["Drive", "Gain", "DriveNorm", "Ch1Drive", "Ch2Drive", "Norm Drive"]
GAIN_FIRST = {"AmpAguaSledge": "Gain"}  # its Drive is a second stage, at 0 by default
# The input stage: a compressor that never compresses (threshold at 0 dB, a guitar is far below) with its Level in dB
INPUT_STAGE = {"@model": "HD2_CompressorDeluxeComp", "Threshold": 0.0, "Ratio": 0, "Knee": 0.0, "Mix": 1.0}
# The chain, in order: block key, model, from the frame or not
INPUT, DISTORTION, OVERDRIVE, AMP, PHASER, CHORUS, DELAY, REVERB = ("block%d" % i for i in range(8))
CC = {"lead": 20, "chorus": 21, "phaser": 22, "delay": 24, "reverb": 25, "gain": 26, "bass": 27, "mid": 28, "treble": 29,
      "presence": 30, "delay_time": 31, "delay_feedback": 33, "delay_mix": 34, "reverb_mix": 35, "modulation_mix": 36,
      "level": 37, "input": 39, "overdrive": 40, "overdrive_gain": 41, "overdrive_tone": 42, "distortion": 43, "distortion_gain": 44}
# CC: (the tone's setting, block, parameter, value at CC 0, at CC 127)
KNOBS = [(CC["bass"], "bass", AMP, "Bass", 0, 1), (CC["mid"], "mid", AMP, "Mid", 0, 1), (CC["treble"], "treble", AMP, "Treble", 0, 1),
         (CC["presence"], "presence", AMP, "Presence", 0, 1),
         (CC["delay_time"], "delay_time", DELAY, "Time", 0, 2), (CC["delay_feedback"], "delay_feedback", DELAY, "Feedback", 0, 1),
         (CC["delay_mix"], "delay_mix", DELAY, "Mix", 0, 1), (CC["reverb_mix"], "reverb_mix", REVERB, "Mix", 0, 1),
         (CC["modulation_mix"], "modulation_mix", CHORUS, "Mix", 0, 1),
         (CC["overdrive_gain"], "overdrive_gain", OVERDRIVE, "Gain", 0, PEDAL_GAIN), (CC["overdrive_tone"], "overdrive_tone", OVERDRIVE, "Tone", 0, 1),
         (CC["distortion_gain"], "distortion_gain", DISTORTION, "Drive", 0, PEDAL_GAIN)]
SWITCHES = {CHORUS: CC["chorus"], PHASER: CC["phaser"], DELAY: CC["delay"], REVERB: CC["reverb"],
            OVERDRIVE: CC["overdrive"], DISTORTION: CC["distortion"]}


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


def input_scale(calibration):
    """The input's rise in dB from gain 0 to 1 at the controller's CC 127, and the gain at CC 127 (the knob's range)
    without a boost pedal: tonehost raises the input faster with one. On an amp that doesn't, the same either way."""
    plain, boosted = calibration["input_db"], calibration["input_overdrive_db"]
    assert plain[0] == boosted[0], (plain, boosted)
    return boosted[1], 100 * boosted[1] / plain[1]


def preset(amp, frame, M, calibration, cab_range):
    h = json.loads(json.dumps(frame))
    h["data"]["meta"]["name"] = amp[3:][:16]
    t = h["data"]["tone"]
    old = t["dsp0"]
    by_model = {b["@model"]: b for k, b in old.items() if k.startswith("block")}
    d = {k: v for k, v in old.items() if not k.startswith(("block", "cab"))}

    def block(key, model, extra=None, enabled=True, midi_switched=False, base=None):
        """A block at `key`: the frame's (base) as it is, flags included, or a new mono one at Line 6's defaults."""
        b = json.loads(json.dumps(base)) if base else {"@type": 0, "@stereo": False, **defaults(M[model])}
        b.update({"@model": model, "@position": int(key[5:]), "@path": 0, "@enabled": enabled,
                  "@no_snapshot_bypass": midi_switched})
        b.update(extra or {})
        d[key] = b
        return b

    block(INPUT, INPUT_STAGE["@model"], {k: v for k, v in INPUT_STAGE.items() if k != "@model"})
    block(DISTORTION, "HD2_DistSwedishChainsaw", enabled=False, midi_switched=True)
    block(OVERDRIVE, "HD2_DistMinotaur", enabled=False, midi_switched=True)
    for key, model in ((PHASER, "HD2_PhaserScriptModPhase"), (CHORUS, "HD2_Chorus"), (DELAY, "HD2_DelaySimpleDelay"),
                       (REVERB, "HD2_ReverbPlate")):
        block(key, model, enabled=False, midi_switched=True, base=by_model[model])
    m = M["HD2_" + amp]
    amp_block = {k: v for k, v in by_model[next(k for k in by_model if k.startswith("HD2_Amp"))].items() if k.startswith("@")}
    amp_block = block(AMP, m["symbolicID"], base=amp_block)
    amp_block.update(defaults(m))
    cab = M[m["ircablink"]]
    d["cab0"] = {"@model": cab["symbolicID"], "@enabled": True, **defaults(cab)}  # tonehost's cab: Line 6's defaults
    t["dsp0"] = d

    gain = GAIN_FIRST.get(amp) or next(p for p in GAIN if p in amp_block)
    volume = "ChVol" if "ChVol" in amp_block else "Ch Vol"
    amp_block[volume] = round(min(amp_block[volume], 1 / LEAD_LIFT), 3)     # room for the whole lift
    rise, _ = input_scale(calibration)
    low = calibration["input_db"][0]
    d[INPUT]["Level"] = low
    controls = {AMP: {gain: midi(0, calibration["drive"], CC["gain"]),
                      volume: midi(amp_block[volume], round(amp_block[volume] * LEAD_LIFT, 3), CC["lead"])},
                INPUT: {"Level": midi(low, round(low + rise, 2), CC["input"])},
                "cab0": {"Level": midi(cab_range[0], cab_range[1], CC["level"])}}
    for cc, _, where, param, lo, hi in KNOBS:
        if param in d[where]:
            controls.setdefault(where, {})[param] = midi(lo, hi, cc)
    t["controller"]["dsp0"] = controls
    t["footswitch"]["dsp0"] = {key: {"@cc": cc, "@fs_index": 19} for key, cc in SWITCHES.items()}
    d["outputA"]["gain"] = calibration["output_db"]
    d["cab0"]["Level"] = 0.0
    on = {key: key in (INPUT, AMP) for key in d if key.startswith("block")}
    for i in range(3):  # the categories' snapshots play alike: tonehost has no categories
        s = t["snapshot%d" % i]
        s.pop("controllers", None)
        s["blocks"] = {"dsp0": dict(on)}
    return h


def check(h, M):
    """What the Stomp would refuse or a typo would break, and the DSP. Returns the load."""
    t = h["data"]["tone"]
    d = t["dsp0"]
    blocks = [k for k in d if k.startswith("block")]
    assert len(blocks) == 8, blocks
    assert sorted(d[k]["@position"] for k in blocks) == list(range(8))
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


def compact(value):
    return json.dumps(value, separators=(", ", ": "))


def profile(slots, amps, calibration, cab_range):
    """A DI is what acoustic parts use: it says nothing of the song's amp, so it doesn't pick a preset."""
    pc = {amp: FIRST_PC + i for i, amp in enumerate(slots)}
    games = [(game, amp) for game, amp in sorted(amps.items()) if amp in pc and not game.startswith("DI_")]
    load = ",\n".join('    "%s": [{"pc": %d}, {"wait_ms": %d}]' % (game, pc[amp], LOAD_WAIT_MS) for game, amp in games)
    # The input knob: the same range on every amp that raises its input faster with a boost pedal, as most do
    usual = {round(input_scale(calibration[a])[1], 2) for a in slots if input_scale(calibration[a])[1] != 100}
    assert len(usual) == 1, usual
    usual = usual.pop()
    knobs = [{"cc": CC["gain"], "from": "gain"},
             {"cc": CC["input"], "from": "gain", "range": [0, usual], "with": {"overdrive": [0, 100]}}]
    knobs += [{"cc": cc, "from": source} for cc, source, *_ in KNOBS]
    amp_knobs = []
    for game, amp in games:
        own = [{"cc": CC["level"], "range": cab_range, "sum": calibration[amp]["cab_db"]}]
        if input_scale(calibration[amp])[1] == 100:  # this amp's input rises alike with a boost pedal or without
            own.append({"cc": CC["input"], "from": "gain", "range": [0, 100]})
        amp_knobs.append('    "%s": %s' % (game, compact(own)))
    return """{
  "name": "HX Stomp by amp",
  "comment": "A preset per Helix amp, made by tools/make_stomp_presets.py, playing a tone as rs-tonehost does; a style's preset for any other amp. Setup: hx-stomp-presets/README.md.",
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
    "Clean":      [{"cc": 69, "value": 0}, {"cc": 20, "value": 0}, {"cc": 38, "value": 0}],
    "Crunch":     [{"cc": 69, "value": 1}, {"cc": 20, "value": 0}, {"cc": 38, "value": 0}],
    "Heavy":      [{"cc": 69, "value": 2}, {"cc": 20, "value": 0}, {"cc": 38, "value": 0}],
    "Lead":       [{"cc": 69, "value": 2}, {"cc": 20, "value": 127}, {"cc": 38, "value": 127}],
    "Lead clean": [{"cc": 69, "value": 0}, {"cc": 20, "value": 127}, {"cc": 38, "value": 0}]
  },
  "effects": {
    "chorus": 21, "flanger": 21,
    "phaser": 22, "vibe": 22,
    "tremolo": 23,
    "delay": 24,
    "reverb": 25,
    "overdrive": 40,
    "distortion": 43
  },
  "knobs": [
    %s
  ],
  "amp_knobs": {
%s
  },
  "add_delay": {"Lead crunch": %s, "Lead heavy": %s}
}
""" % (load, ",\n    ".join(compact(k) for k in knobs), ",\n".join(amp_knobs), compact(LEAD_DELAY), compact(LEAD_DELAY))


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--first", type=int)
    args = a.parse_args()
    if not os.path.isdir(RES):
        sys.exit("HX Edit isn't at " + RES)
    M = models()
    spec = json.load(open(os.path.join(PRESETS, "amps.json")))
    frame = json.load(open(os.path.join(PRESETS, "Classic Rock.hlx")))
    measured = json.load(open(os.path.join(PRESETS, "calibration.json")))
    calibration, cab_range = measured["amps"], measured["cab_range"]  # the cab's Level by CC 37
    slots = spec["slots"][:args.first]
    missing = [a for a in slots if a not in calibration]
    if missing:
        sys.exit("not in calibration.json: %s; run tools/calibrate_stomp.py" % ", ".join(missing))
    out = os.path.join(PRESETS, "amps")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith(".hlx"):
            os.remove(os.path.join(out, f))
    worst = 0.0
    for i, amp in enumerate(slots):
        h = preset(amp, frame, M, calibration[amp], cab_range)
        load = check(h, M)
        if load > BUDGET:
            sys.exit("%s: %.2f is over the DSP budget" % (amp, load))
        worst = max(worst, load)
        name = "%s %s.hlx" % (slot_name(FIRST_PC + i), amp[3:])
        json.dump(h, open(os.path.join(out, name), "w"), indent=1, sort_keys=True)
        print("%s  %.2f DSP" % (name, load))
    open(os.path.join(ROOT, "profiles", "hx-stomp-amps.json"), "w").write(profile(slots, spec["amps"], calibration, cab_range))
    print("%d presets, heaviest %.2f of %.1f" % (len(slots), worst, BUDGET))


if __name__ == "__main__":
    main()
