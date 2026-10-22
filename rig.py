"""What a tone's rig does, from the song index's "rig" (every gear item with its knobs): how
distorted it is, and its time and modulation effects; and how heavy a whole song is.

drive is 0-1: below 1/3 clean, 1/3-2/3 crunch, above 2/3 heavy. It comes from the amp model and
its gain knob (amps break up and get heavy at different settings) and the drive pedals in front
of it. The amp thresholds follow the amp rules in presets.default.json. A tone with an acoustic
emulator is an acoustic guitar sound: clean whatever the amp."""

# Amp key without "Amp_" -> (gain where it starts to break up, gain where it gets heavy, or None
# if it never does).
AMPS = {
    "HG500": (25, 50), "MarshallJVM410H": (25, 50), "MarshallJCM800": (35, 75),
    "OrangeRockerverb": (30, 55), "OrangeJimmyBean": (25, 50),
    "CA100": (30, 50), "GB50": (40, 70), "OrangeTinyTerror": (40, 70),
    "MarshallDSL100H": (40, 80), "MarshallDSL15H": (40, 80),
    "GB100": (40, 95), "HG100": (40, 95), "HG180": (40, 95), "CA85": (40, 95), "EN50": (40, 95),
    "MarshallPlexi": (40, None), "MarshallJTM45": (40, None), "Marshall1962Bluesbreaker": (45, None),
    "OrangeAD50": (45, None), "OrangeOR100": (40, None), "OrangeOR50H": (40, None),
    "TW22": (50, None), "TW26": (50, None), "TW40": (50, None), "EN30": (50, None),
    "AT20": (50, None), "AT120": (50, None), "BT15": (50, None), "BT30": (50, None), "BT45": (50, None),
    "GibsonGA8": (50, None), "GibsonGA79": (50, None), "GibsonGA88": (50, None),
    "EpiphoneZephyr": (50, None), "EpiphoneElectarM": (50, None), "EpiphoneElectarCentury": (50, None),
    "CA38": (55, None), "GB38": (60, None), "CS90": (70, None), "CS100": (70, None), "CS120": (70, None),
}
UNKNOWN_AMP = (50, 95)

# Pedals that distort by themselves: drive at least floor + span * gain.
DISTORTION_PEDALS = {
    "Pedal_MetalDistortion": (0.45, 0.5), "Pedal_ShredZone": (0.45, 0.5), "Pedal_MarshallGuvnorPlus": (0.4, 0.45),
    "Pedal_Distortion": (0.4, 0.45), "Pedal_VintageDistortion": (0.4, 0.4),
    # Fuzz is thick but mostly classic rock: crunch, heavy only on top of a driven amp.
    "Pedal_CaptFuzzle": (0.3, 0.35), "Pedal_BuzzOne": (0.3, 0.35), "Pedal_BuzzToo": (0.3, 0.35),
    "Pedal_FuzzWasHe": (0.3, 0.35), "Pedal_Octavius": (0.3, 0.3),
}
# Overdrives and boosts push the amp: drive + push * gain.
ACOUSTIC = ("Pedal_AcousticEmulator",)
BOOST_PEDALS = {"Pedal_LineDrive": 0.15, "Pedal_GermaniumDrive": 0.15, "Pedal_SuperDrive": 0.15,
                "Pedal_CustomDrive": 0.15, "Pedal_RangeBooster": 0.1}

# Modulation by words in the gear key, first match wins.
MODULATION = [("Flanger", "flanger"), ("Phase", "phaser"), ("Chorus", "chorus"), ("Enbig", "chorus"),
              ("Clones", "chorus"), ("Trem", "tremolo"), ("Vibe", "vibe"), ("Rota", "vibe"), ("OmniMod", "vibe")]
REVERBS = ("Verb", "Spring", "Chamber", "Plate")


def _knob(item, *names):
    """The first of these knobs the item has, or None."""
    return next((item["knobs"][n] for n in names if n in item["knobs"]), None)


def amp_drive(amp, gain):
    """0-1 from the amp key ('Amp_HG500') and its gain knob (0-100)."""
    if gain is None:
        return None
    name = amp[4:] if amp.startswith("Amp_") else amp
    crunch, heavy = AMPS.get(name, UNKNOWN_AMP)
    g = min(max(gain, 0), 100)
    if g < crunch:
        return g / crunch / 3
    if heavy is None:  # breaks up but never gets heavy: at most just under 0.6
        return 1 / 3 + (g - crunch) / (100 - crunch) * 0.25
    if g < heavy:
        return 1 / 3 + (g - crunch) / (heavy - crunch) / 3
    return 2 / 3 + (g - heavy) / max(100 - heavy, 1) / 3


def drive(rig, gain=None):
    """How distorted the tone is, 0-1 (None without an amp). gain is the amp's gain knob as the
    index gives it (the Plexi has Loudness knobs instead), if known."""
    amp = rig.get("Amp")
    if not amp:
        return None
    if gain is None:
        gain = _knob(amp, "Gain")
    d = amp_drive(amp["key"], gain)
    if d is None:
        return None
    if any(item["key"] in ACOUSTIC for item in rig.values()):
        return min(d, 0.25)
    for slot, item in rig.items():
        if "Pedal" not in slot:
            continue
        g = min(max(_knob(item, "Gain", "Boost") or 0, 0), 100) / 100
        if item["key"] in BOOST_PEDALS:
            d += BOOST_PEDALS[item["key"]] * g
        elif item["key"] in DISTORTION_PEDALS:
            floor, span = DISTORTION_PEDALS[item["key"]]
            d = max(d, floor + span * g)
    return min(d, 1.0)


def band(d):
    """'clean', 'crunch' or 'heavy' for a drive value ('' if unknown)."""
    return "" if d is None else "clean" if d < 1 / 3 else "crunch" if d < 2 / 3 else "heavy"


def effects(rig):
    """The tone's time and modulation effects: {"delay": {"time", "mix", "feedback"},
    "reverb": {"mix"}, "mod": {"kind", "mix", "rate"}}, each only if the tone has one (the one
    with the most mix if it has several)."""
    out = {}

    def keep(kind, value):
        if kind not in out or (value.get("mix") or 0) > (out[kind].get("mix") or 0):
            out[kind] = value

    for slot, item in rig.items():
        key, knobs = item["key"], item["knobs"]
        if slot in ("Amp", "Cabinet"):
            continue
        if "Feedback" in knobs and ("Time" in knobs or "TimeL" in knobs):
            keep("delay", {"time": _knob(item, "Time", "TimeL"), "mix": knobs.get("Mix"),
                           "feedback": knobs["Feedback"]})
        elif any(w in key for w in REVERBS):
            keep("reverb", {"mix": knobs.get("Mix")})
        else:
            kind = next((k for w, k in MODULATION if w in key), None)
            if kind:
                keep("mod", {"kind": kind, "mix": knobs.get("Mix"), "rate": _knob(item, "Rate", "Speed")})
    return out


NOTES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


def tuning_name(tuning, bass=False):
    """'E standard', 'Drop D', 'Eb standard', ... or 'custom' (None if unknown)."""
    if tuning is None:
        return None
    strings = [int(x) for x in tuning[:4 if bass else 6]]
    rest = set(strings[1:])
    if len(rest) != 1:
        return "custom"
    r = rest.pop()
    if strings[0] == r:
        return f"{NOTES[(4 + r) % 12]} standard"
    if strings[0] == r - 2:
        return f"Drop {NOTES[(2 + r) % 12]}"
    return "custom"


GUITAR_PATHS = ("Lead", "Rhythm", "Combo")


def tone_def(arrangement, key):
    """The arrangement's tone for a slot's tone key, or None. Some custom songs name the slot a
    little differently from the tone ('Hotel California' for 'HotelCalifornia'): then the tone
    whose key matches without spaces and punctuation, or the only tone there is."""
    tones = arrangement["tones"]
    loose = lambda k: "".join(c for c in k.lower() if c.isalnum())
    return (next((t for t in tones if t["key"].lower() == key.lower()), None)
            or next((t for t in tones if loose(t["key"]) == loose(key)), None)
            or (tones[0] if len(tones) == 1 else None))


def song_heaviness(arrangements):
    """How heavy a song is, 0-1, from its guitar arrangements: the most distorted tone any of
    them uses, plus 0.1 when the low string is tuned down to C or lower. None without guitar
    tones."""
    drives, low = [], 0
    for a in arrangements:
        if a["path"] not in GUITAR_PATHS:
            continue
        for key in {k.lower() for k in a["slots"] if k}:
            t = tone_def(a, key)
            if t and t.get("rig"):
                d = drive(t["rig"], t.get("gain"))
                if d is not None:
                    drives.append(d)
        if a.get("tuning"):
            low = min(low, a["tuning"][0] + (a.get("centOffset") or 0) / 100)
    if not drives:
        return None
    return min(max(drives) + (0.1 if low <= -4 else 0), 1.0)
