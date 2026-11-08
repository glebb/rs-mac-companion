#!/usr/bin/env python3
"""Measures Helix Native's amps and writes hx-stomp-presets/calibration.json for tools/make_stomp_presets.py.

    tools/calibrate_stomp.py [MEASUREMENTS]

The Stomp has the same models as Helix Native, and Native can be measured with no guitar: tools/measure_helix.m plays a
pluck through each saved state of rs-tonehost at many levels. MEASUREMENTS is its output, to read it again without
measuring. Two things come out per amp:

- gain: the amp's Drive at the tone's drive 0 and 1, so a drive means as much distortion on every amp. Dirt is how far
  in dB a guitar's level is above the level where the amp starts to compress. A tone's drive d should give DIRT_PER_DRIVE
  * (d - 1/2): 0 at the top of Crunch's middle. Two presets that sounded right on a Stomp set that scale.
- level_db: what to add at the tone's drive 0 and 1 so every amp comes out alike, as an amp gets far louder with Drive.

An amp whose level doesn't move with knob 0 can't be swept, and keeps the generator's default: tonehost's states put each
amp's gain on that knob, whatever the amp calls it.
"""
import json, math, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REARMED = os.path.expanduser("~/Library/Application Support/RS Re-ARMed")
RES = "/Applications/Line6/HX Edit.app/Contents/Resources"
LEVELS = [-60 + 6 * i for i in range(10)]
GUITAR_DB = -18         # a guitar's peaks at the Stomp, from tonehost's logs: about -14 to -20
NOISE_DB = -65          # below this an amp's hum is what's measured
DIRT_PER_DRIVE = 30     # dB from drive 0 to 1: clean at -10, crunch at 0, heavy at +10
COMPRESSED_DB = 3
REFERENCE = ("AmpBrit2203", 0.5, 0.45, 2.0)  # Classic Rock's Crunch: amp, Drive, Ch Vol, cab Level. Its level is the target
QUIETEST_DB = 6         # how far below a clean tone's level the lowest drive may fall
LEAD_LIFT = 1.41        # as in make_stomp_presets.py: Ch Vol is kept below 1 / this


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


def measure():
    tool = os.path.join(ROOT, "build", "measure_helix")
    subprocess.check_call(["clang", "-O2", "-fobjc-arc", os.path.join(ROOT, "tools", "measure_helix.m"), "-framework", "Foundation",
                           "-framework", "AudioToolbox", "-o", tool])
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=os.path.join(REARMED, "libnetguard.dylib"))
    return subprocess.check_output([tool, os.path.join(REARMED, "tonehost", "config.json")], env=env, stderr=subprocess.DEVNULL, text=True)


def dirt(out):
    """dB a guitar sits above where the amp compresses by COMPRESSED_DB; -18 if it never does."""
    gains = [(l, o - l) for l, o in zip(LEVELS, out) if o > NOISE_DB]
    if not gains:
        return -18.0
    top = max(g for _, g in gains)
    start = [g for _, g in gains].index(top)
    for (l0, g0), (l1, g1) in zip(gains[start:], gains[start + 1:]):
        if g1 <= top - COMPRESSED_DB:
            return GUITAR_DB - (l0 + (l1 - l0) * (g0 - (top - COMPRESSED_DB)) / (g0 - g1))
    return -18.0


def interpolate(xs, ys, x):
    if x <= xs[0]:
        return ys[0]
    for x0, x1, y0, y1 in zip(xs, xs[1:], ys, ys[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return ys[-1]


def fit(points):
    """The line through (x, y) points, as its values at 0 and 1."""
    n = len(points)
    mx = sum(p[0] for p in points) / n
    my = sum(p[1] for p in points) / n
    b = sum((p[0] - mx) * (p[1] - my) for p in points) / sum((p[0] - mx) ** 2 for p in points)
    return my - b * mx, my + b * (1 - mx)


def calibrate(amp, rows, target, M):
    xs = [r[0] for r in rows]
    level = [r[1][LEVELS.index(GUITAR_DB)] for r in rows]
    if max(level) - min(level) < 0.5:
        return None
    # Dirt only rises with Drive, so read from the top: a spike at the lowest Drives, hum or a state just loaded, doesn't count
    dirts = [dirt(out) for _, out in rows]
    for i in range(len(dirts) - 2, -1, -1):
        dirts[i] = min(dirts[i], dirts[i + 1])
    def drive_for(want):
        if want <= dirts[0]:
            return xs[0]
        for i in range(1, len(xs)):
            if dirts[i] >= want:
                d0, d1 = dirts[i - 1], dirts[i]
                return xs[i - 1] + (xs[i] - xs[i - 1]) * ((want - d0) / (d1 - d0) if d1 > d0 else 1)
        return 1.0
    points = [(d, drive_for(DIRT_PER_DRIVE * (d - 0.5))) for d in (1 / 6, 1 / 2, 5 / 6)]
    low, high = fit(points)
    low, high = min(max(low, 0), 1), min(max(high, 0), 1)
    # Below a clean tone's Drive an amp may fall silent, which no straight line of levels can follow
    clean = interpolate(xs, level, points[0][1])
    low = max(low, next((x for x, l in zip(xs, level) if l >= clean - QUIETEST_DB), low))
    high = max(high, low + 0.02)
    # Ch Vol on the Stomp is lower than Native's default on some amps, and read as linear
    volume = channel_volume(amp, M)
    held = 20 * math.log10(min(volume, 1 / LEAD_LIFT) / volume)
    trims = [(d / 10, target - (interpolate(xs, level, low + (high - low) * d / 10) + held)) for d in range(1, 10)]
    t0, t1 = fit(trims)
    miss = max(abs(t - (t0 + (t1 - t0) * d)) for d, t in trims)
    return {"gain": [round(low, 3), round(high, 3)], "level_db": [round(t0, 1), round(t1, 1)], "level_miss_db": round(miss, 1)}


def main():
    text = open(sys.argv[1]).read() if len(sys.argv) > 1 else measure()
    rows = {}
    for line in text.splitlines():
        p = line.split()
        rows.setdefault(p[0], []).append((float(p[1]), [float(x) for x in p[2:]]))
    M = models()
    amp, x, volume, cab = REFERENCE
    xs = [r[0] for r in rows[amp]]
    level = [r[1][LEVELS.index(GUITAR_DB)] for r in rows[amp]]
    target = interpolate(xs, level, x) + 20 * math.log10(volume / channel_volume(amp, M)) + cab
    out = {"_": "From tools/calibrate_stomp.py: Helix Native's amps measured, for make_stomp_presets.py. target_db is where a guitar's peaks at %d dB come out." % GUITAR_DB,
           "target_db": round(target, 1), "amps": {}}
    for name in sorted(rows):
        c = calibrate(name, rows[name], target, M)
        if c:
            out["amps"][name] = c
    skipped = sorted(set(rows) - set(out["amps"]))
    out["not_measured"] = skipped
    with open(os.path.join(ROOT, "hx-stomp-presets", "calibration.json"), "w") as f:
        f.write(json.dumps(out, indent=1, sort_keys=True) + "\n")
    for name, c in sorted(out["amps"].items()):
        print("%-18s gain %.2f-%.2f  level %+6.1f to %+6.1f dB, off by up to %.1f" % (name, *c["gain"], *c["level_db"], c["level_miss_db"]))
    print("target %.1f dB; not measured: %s" % (target, ", ".join(skipped)))


if __name__ == "__main__":
    main()
