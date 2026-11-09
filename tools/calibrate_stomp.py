#!/usr/bin/env python3
"""Measures, in Helix Native, how loud each preset per amp plays a tone, and writes hx-stomp-presets/calibration.json
for tools/make_stomp_presets.py.

    tools/calibrate_stomp.py [MEASUREMENTS]

The presets per amp play a tone as rs-tonehost (rearmed-mods) plays it in Helix Native: the amp's Drive and its input
follow the game's gain knob, a Minotaur stands in for a boost or overdrive pedal and a Swedish Chainsaw for a distortion,
metal or fuzz pedal, and the tone knobs are the game's. Its rules are read from tonehost's config.json. Then tonehost
measures each tone as it loads and sets its level. The Stomp can't, so RS Companion sets the level of each tone from a
formula per amp, a sum of terms of the tone's settings (profile knobs with "sum", docs/device-profiles.md). This measures
what the formula needs: tools/measure_helix.m plays tonehost's probe through tonehost's own saved states, set as the
Stomp would be, over a grid of gain, pedals and tone knobs. MEASUREMENTS is its output, to read it again without measuring.

What isn't on the Stomp is left out of the measurement too: tonehost's octaves, wah, compressor and acoustic emulator,
and the other effects, whose mix changes the level little.
"""
import json, math, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REARMED = os.path.expanduser("~/Library/Application Support/RS Re-ARMed")
TONEHOST = os.path.join(REARMED, "tonehost", "config.json")
RES = "/Applications/Line6/HX Edit.app/Contents/Resources"
TARGET_DB = -29.5       # where a guitar's pluck peaking at -18 dB comes out: Classic Rock's Crunch, less 3 dB
LEAD_LIFT = 1.15        # as in make_stomp_presets.py: Ch Vol is kept below 1 / this
GAINS = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
KNOB_GAINS = [0.2, 0.5, 0.8]
PEDAL_GAIN = 50         # the gain (and tone) of the stand-in pedals while measuring
KNOBS = {"bass": "_Bass", "mid": "_Mid", "treble": "_Treble", "presence": "_Pres"}
OVERDRIVE, DISTORTION = "Pedal_SuperDrive", "Pedal_MetalDistortion"  # one of each kind, to find tonehost's parameters
CAB_RANGE = (-60.0, 6.0)  # the cab's Level, by CC 37: what the formula sets
OUTPUT_MAX = 20.0         # the output block's Level: with the cab's, as far as the Stomp can raise a quiet tone
GUITAR_KEY = "Amp_X"


class Tonehost:
    """tonehost's config: its templates, and the parameters its rules set."""

    def __init__(self, path=TONEHOST):
        self.config = json.load(open(path))
        self.dir = os.path.dirname(path)
        self.map, self.templates = self.config["map"], self.config["templates"]
        rules = self.map["follow"]
        self.switches = sorted(r["param"] for r in rules if "present" in r)
        def present(key):
            return next(r["param"] for r in rules if "present" in r and key in r["present"])
        def knob(suffix, prefix=None, contains=None):
            return next(r["param"] for r in rules if r.get("from") == suffix and r.get("prefix") == prefix
                        and r.get("contains") == contains)
        self.overdrive = {"switch": present(OVERDRIVE), "gain": knob("_Gain", OVERDRIVE + "_"), "tone": knob("_Tone", OVERDRIVE + "_")}
        self.distortion = {"switch": present(DISTORTION), "gain": knob("_Gain", DISTORTION + "_")}
        self.knobs = {name: knob(suffix, contains="Amp_") for name, suffix in KNOBS.items()}
        self.input_gain_db = float(self.config["input"].get("gain_db", 0))  # tonehost raises the guitar by this first
        self.probe_db = float(self.config.get("probe_peak_db", -12))

    def state(self, amp):
        s = self.templates[amp]["state"]
        return s if s.startswith("/") else os.path.join(self.dir, s)

    def _rule(self, amp, param, overdrive):
        """The rule tonehost uses for a parameter from the gain knob: (scale, offset)."""
        for f in reversed(self.templates[amp].get("follow", [])):
            if f.get("param") == param and f.get("from") == "amp_gain":
                return f["scale"], f["offset"]
        for f in self.map["follow"]:
            if f.get("param") != param or f.get("from") != "amp_gain":
                continue
            if ("with" in f) != overdrive and ("with" in f or "without" in f):
                continue
            return f["scale"], f["offset"]
        raise KeyError((amp, param))

    def drive(self, amp):
        """The amp's Drive at gain 1 (0.93, or 0.6 on amps with gain enough of their own)."""
        return self._rule(amp, 0, False)[0]

    def input(self, amp, overdrive):
        """tonehost's Master Input in dB at gain 0, and its rise to gain 1."""
        scale, offset = self._rule(amp, 32, overdrive)
        return offset, scale

    def params(self, amp, gain, knobs=None, overdrive=None, distortion=None):
        """The Audio Unit parameters for a tone as the Stomp plays it. gain is 0-1, knobs and pedals 0-100."""
        out = {int(k): float(v) for k, v in self.templates[amp]["params"].items()}
        for s in self.switches:
            out[s] = 0.0
        out[0] = self.drive(amp) * gain
        offset, scale = self.input(amp, overdrive is not None)
        out[32], out[33] = offset + scale * gain, 0.0
        for name, value in (knobs or {}).items():
            out[self.knobs[name]] = value / 100
        if overdrive is not None:
            out[self.overdrive["switch"]] = 1.0
            out[self.overdrive["gain"]] = 0.0098 * overdrive[0]
            out[self.overdrive["tone"]] = 0.01 * overdrive[1]
        if distortion is not None:
            out[self.distortion["switch"]] = 1.0
            out[self.distortion["gain"]] = 0.0098 * distortion
        return out

    def default_knob(self, amp, name):
        return 100 * float(self.templates[amp]["params"].get(str(self.knobs[name]), 0.5))


def models():
    out = {}
    for f in os.listdir(RES):
        if f.endswith(".models"):
            data = json.load(open(os.path.join(RES, f)))
            for m in data if isinstance(data, list) else []:
                if isinstance(m, dict) and m.get("symbolicID"):
                    out[m["symbolicID"]] = m
    return out


def channel_volume(amp, M):
    p = {x["symbolicID"]: x.get("default") for x in M["HD2_" + amp]["params"]}
    return p.get("ChVol", p.get("Ch Vol"))


def jobs(th, amps):
    """(label, state, params) for each amp: the gain alone, with each pedal, and each tone knob at its ends."""
    out = []
    for amp in amps:
        for g in GAINS:
            out.append(("%s|plain|%g" % (amp, g), th.state(amp), th.params(amp, g)))
            out.append(("%s|overdrive|%g" % (amp, g), th.state(amp), th.params(amp, g, overdrive=(PEDAL_GAIN, PEDAL_GAIN))))
            out.append(("%s|distortion|%g" % (amp, g), th.state(amp), th.params(amp, g, distortion=PEDAL_GAIN)))
        for name in KNOBS:
            for v in (0, 100):
                for g in KNOB_GAINS:
                    out.append(("%s|%s=%d|%g" % (amp, name, v, g), th.state(amp), th.params(amp, g, knobs={name: v})))
    return out


def measure(th, todo):
    tool = os.path.join(ROOT, "build", "measure_helix")
    subprocess.check_call(["clang", "-O2", "-fobjc-arc", os.path.join(ROOT, "tools", "measure_helix.m"), "-framework", "Foundation",
                           "-framework", "AudioToolbox", "-o", tool])
    text = "".join("%s\t%s\t%s\n" % (label, state, " ".join("%d=%g" % kv for kv in sorted(ps.items()))) for label, state, ps in todo)
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=os.path.join(REARMED, "libnetguard.dylib"))
    return subprocess.run([tool, "--at", str(int(th.probe_db))], input=text, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, check=True).stdout


def interpolate(points, x):
    if x <= points[0][0]:
        return points[0][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return points[-1][1]


def calibrate(amp, level, th, M):
    """The cab Level formula for an amp: terms the app sums, the output block's level, and how far it misses."""
    plain = [(100 * g, level["plain", g]) for g in GAINS]
    pedals = {kind: [(100 * g, round(level[kind, g] - level["plain", g], 2)) for g in GAINS] for kind in ("overdrive", "distortion")}
    slopes = {}
    for name in KNOBS:
        slopes[name] = sum((level["%s=100" % name, g] - level["%s=0" % name, g]) / 100 for g in KNOB_GAINS) / len(KNOB_GAINS)
    defaults = {name: th.default_knob(amp, name) for name in KNOBS}
    volume = channel_volume(amp, M)
    held = 20 * math.log10(min(volume, 1 / LEAD_LIFT) / volume)  # Ch Vol below its default on the Stomp, taken as linear

    def model(g, kind=None, knobs=None):
        x = interpolate(plain, 100 * g) + (interpolate(pedals[kind], 100 * g) if kind else 0)
        return x + sum(slopes[n] * (v - defaults[n]) for n, v in (knobs or {}).items())
    misses = [abs(model(g, knobs={n: v}) - level["%s=%d" % (n, v), g]) for n in KNOBS for v in (0, 100) for g in KNOB_GAINS]
    # The cab's Level: target - the level the Stomp plays at. The output block takes the rest: as much as the loudest
    # tones leave room for, so the quietest come up as far as they can. tonehost raises a near-silent amp all the way
    # (at gain 0 some are 80 dB down); the Stomp can't, and those stay quieter.
    swing = sum(abs(slopes[n]) * max(defaults[n], 100 - defaults[n]) for n in KNOBS)
    needs = [TARGET_DB - held - model(g, kind) for g in GAINS for kind in (None, "overdrive", "distortion")]
    output = min(OUTPUT_MAX, math.floor(min(needs) - swing - CAB_RANGE[0]), math.ceil(max(needs) + swing - CAB_RANGE[1]))
    low = min(needs) - swing - output
    short = max(0.0, max(needs) - output - CAB_RANGE[1])
    reach = next((100 * g for g in GAINS if TARGET_DB - held - model(g) - output <= CAB_RANGE[1]), 100.0)
    terms = [{"add": round(TARGET_DB - held - output, 2)},
             {"from": "gain", "points": [[x, round(-y, 2)] for x, y in plain]}]
    for kind in ("overdrive", "distortion"):
        terms.append({"from": "gain", "with": kind, "points": [[x, round(-y, 2)] for x, y in pedals[kind]]})
    for n in KNOBS:
        if abs(slopes[n]) >= 0.005:  # under half a dB from end to end
            d = defaults[n]
            terms.append({"from": n, "points": [[0, round(slopes[n] * d, 2)], [100, round(-slopes[n] * (100 - d), 2)]]})
    od0, od1 = th.input(amp, True)
    in0, in1 = th.input(amp, False)
    return {"drive": th.drive(amp), "input_db": [round(in0 + th.input_gain_db, 2), round(in1, 2)],
            "input_overdrive_db": [round(od0 + th.input_gain_db, 2), round(od1, 2)],
            "output_db": output, "cab_db": terms, "cab_lowest_db": round(low, 1), "knob_miss_db": round(max(misses), 1),
            "short_db": round(short, 1), "full_from_gain": reach,
            "knob_db": {n: round(100 * s, 1) for n, s in slopes.items()}}


def main():
    th, M = Tonehost(), models()
    amps = json.load(open(os.path.join(ROOT, "hx-stomp-presets", "amps.json")))["slots"]
    missing = [a for a in amps if a not in th.templates]
    if missing:
        sys.exit("tonehost has no state for %s: run its tonehost/helix/setup.sh" % ", ".join(missing))
    if len(sys.argv) > 1:
        text = open(sys.argv[1]).read()
    else:
        text = measure(th, jobs(th, amps))
        saved = os.path.join(ROOT, "build", "calibration-measured.txt")
        with open(saved, "w") as f:  # first: measuring takes a while, and this reads it again
            f.write(text)
        print("measurements in %s" % saved)
    level, failed = {}, set()
    for line in text.splitlines():
        label, value = line.split()[:2]
        amp, what, g = label.split("|")
        if value == "failed":  # measure_helix couldn't load the state
            failed.add(amp)
            continue
        level.setdefault(amp, {})[what, float(g)] = float(value)
    if failed:
        sys.exit("Helix Native couldn't load tonehost's state for %s" % ", ".join(sorted(failed)))
    out = {"cab_range": list(CAB_RANGE), "_": "From tools/calibrate_stomp.py: Helix Native measured as the presets per amp play a tone, for "
                "make_stomp_presets.py. cab_db is the formula for the cab's Level by CC 37, so that a guitar's pluck peaking at "
                "-18 dB comes out at target_db.", "target_db": TARGET_DB, "guitar_db": th.probe_db - th.input_gain_db, "amps": {}}
    for amp in amps:
        out["amps"][amp] = c = calibrate(amp, level[amp], th, M)
        print("%-18s drive x%.2f  output %+3d dB  level reached from gain %3d, short by up to %4.1f dB  knobs %s, off by up to %.1f dB" % (
            amp, c["drive"], c["output_db"], c["full_from_gain"], c["short_db"],
            " ".join("%s %+.1f" % (n[0], v) for n, v in c["knob_db"].items()), c["knob_miss_db"]))
    too_low = [a for a, c in out["amps"].items() if c["cab_lowest_db"] < CAB_RANGE[0]]
    if too_low:
        print("cab Level below %g dB needed by: %s (the lowest is clamped)" % (CAB_RANGE[0], ", ".join(too_low)))
    with open(os.path.join(ROOT, "hx-stomp-presets", "calibration.json"), "w") as f:
        f.write(json.dumps(out, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
