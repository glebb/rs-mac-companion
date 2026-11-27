import Foundation

/// What a tone's gear does, read from the song's archive with native/rsfile.c: how distorted it
/// is (drive 0-1: below 1/3 clean, then crunch, above 2/3 heavy), its time and modulation
/// effects, and how heavy a song is. The same rules and tables as rig.py, which the catalog uses
/// to check them against a whole library.
enum Rig {
    struct Gear {
        let key: String
        let knobs: [String: Double]     // named without the key's prefix: "Gain", "Mix", ...

        func knob(_ names: String...) -> Double? { names.lazy.compactMap { knobs[$0] }.first }
    }

    struct Tone {
        let key: String
        let gear: [String: Gear]        // by slot: "Amp", "Cabinet", "PrePedal1", "Rack2", ...
        var descriptors: [String] = []  // its tags: "CLEAN", "DISTORTION", ... (as rsfile.c reads them)
    }

    struct Arrangement {
        let name: String                // e.g. "selftrap_rhythm"
        let path: String                // Lead, Rhythm, Combo, Bass
        let slots: [String]             // tone keys of Base, A-D ("" if unused)
        let tones: [Tone]
        let changes: [(time: Double, id: Int)]  // id 0-3 = slots A-D
        let length: Double?
        let lowString: Double           // the lowest string in semitones from E2 (bass E1), with the cent offset
        let tempo: Double?
        var tuning: Tuning?             // nil if unknown
    }

    /// An arrangement's tuning, as native/rsfile.c's rs_json_tuning and rig.py's tuning_name read it. A stock
    /// arrangement has string0..string5 (bass: the first 4 count), low string first, offsets from E standard. An RS
    /// Extended Range chart ("ExtendedRange" in its manifest) with 7 or 8 guitar strings or 5 or 6 bass strings has
    /// string0..string{N-1}, thickest first, each an offset from that string's own standard pitch (guitar 8: F#1 B1
    /// E2 ..., 7 from B1; bass 5: B0 E1 A1 D2 G2, 6 and C3). One with 6 (guitar) or 4 (bass) strings is stock.
    struct Tuning: Equatable {
        let strings: Int                // N: 6 or 4 stock, 7-8 or 5-6 extended
        let extended: Bool
        let stock: [Double]             // the stock strings from E standard, low first: guitar the top six of an
                                        // extended chart, bass its four after the low B, then the rest and 0
        let positional: [Double]        // an extended chart's N offsets, thickest first (empty if stock)
        let lowString: Double           // the lowest string in semitones from E2 (bass E1), with the cent offset
        let name: String                // "Drop D", "custom", "B standard (7-string)", "Drop A (5-string)", ...
    }

    static let notes = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// "E standard", "Drop D", "Eb standard", ..., "custom", and for an extended chart with its string count, "B
    /// standard (7-string)" (nil if unknown), as rig.py's tuning_name.
    static func tuningName(_ a: Arrangement) -> String? { a.tuning?.name }

    /// The tuning from a manifest's attributes (Tuning, CentOffset, ExtendedRange), or nil without one it can read.
    static func tuning(_ attributes: [String: Any], bass: Bool) -> Tuning? {
        guard let t = attributes["Tuning"] as? [String: Any] else { return nil }
        var v: [Double] = []
        while v.count <= 8, let x = t["string\(v.count)"] as? NSNumber { v.append(x.doubleValue) }
        let n = v.count, stock = bass ? 4 : 6, max = bass ? 6 : 8
        guard n >= stock else { return nil }
        let extended = n > stock && attributes["ExtendedRange"] != nil
        if extended && n > max { return nil }
        let count = extended ? n : stock
        // The lowest string's standard pitch from the stock low string: guitar a fourth down per string added, bass B.
        let base = !extended ? 0 : bass ? -5 : -5 * (n - 6)
        let six = (0..<6).map { i -> Double in
            let from = !extended ? i : bass ? 1 + i : n - 6 + i
            return from < n ? v[from] : 0
        }
        let cents = (attributes["CentOffset"] as? NSNumber)?.doubleValue ?? 0
        let ints = v.prefix(count).map { Int($0) }
        let note = { (e: Int) in notes[((4 + e) % 12 + 12) % 12] }
        let suffix = extended ? " (\(n)-string)" : ""
        let r = ints[1], same = ints.dropFirst().allSatisfy { $0 == r }
        let name = same && ints[0] == r ? "\(note(base + r)) standard\(suffix)"
            : same && ints[0] == r - 2 ? "Drop \(note(base + r - 2))\(suffix)" : "custom\(suffix)"
        return Tuning(strings: count, extended: extended, stock: six, positional: extended ? v : [],
                      lowString: Double(base) + v[0] + cents / 100, name: name)
    }

    // MARK: Drive

    /// Amp key without "Amp_" -> (gain where it starts to break up, gain where it gets heavy, or
    /// nil if it never does).
    static let amps: [String: (crunch: Double, heavy: Double?)] = [
        "HG500": (30, 70), "MarshallJVM410H": (25, 50), "MarshallJCM800": (35, 75),
        "OrangeRockerverb": (30, 55), "OrangeJimmyBean": (25, 50),
        "CA100": (30, 50), "GB50": (40, 70), "OrangeTinyTerror": (40, 70),
        "MarshallDSL100H": (40, 80), "MarshallDSL15H": (40, 80),
        "GB100": (40, 95), "HG100": (40, 95), "HG180": (40, 95), "CA85": (40, 95), "EN50": (40, 95),
        "MarshallPlexi": (40, nil), "MarshallJTM45": (40, nil), "Marshall1962Bluesbreaker": (45, nil),
        "OrangeAD50": (45, nil), "OrangeOR100": (40, nil), "OrangeOR50H": (40, nil),
        "TW22": (50, nil), "TW26": (50, nil), "TW40": (50, nil), "EN30": (50, nil),
        "AT20": (50, nil), "AT120": (50, nil), "BT15": (50, nil), "BT30": (50, nil), "BT45": (50, nil),
        "GibsonGA8": (50, nil), "GibsonGA79": (50, nil), "GibsonGA88": (50, nil),
        "EpiphoneZephyr": (50, nil), "EpiphoneElectarM": (50, nil), "EpiphoneElectarCentury": (50, nil),
        "CA38": (55, nil), "GB38": (60, nil), "CS90": (70, nil), "CS100": (70, nil), "CS120": (70, nil),
    ]
    static let unknownAmp: (crunch: Double, heavy: Double?) = (50, 95)

    /// Pedals that distort by themselves: drive at least floor + span * gain.
    static let distortionPedals: [String: (floor: Double, span: Double)] = [
        "Pedal_MetalDistortion": (0.45, 0.5), "Pedal_ShredZone": (0.45, 0.5), "Pedal_MarshallGuvnorPlus": (0.4, 0.45),
        "Pedal_Distortion": (0.4, 0.45), "Pedal_VintageDistortion": (0.4, 0.4),
        "Pedal_CaptFuzzle": (0.3, 0.35), "Pedal_BuzzOne": (0.3, 0.35), "Pedal_BuzzToo": (0.3, 0.35),
        "Pedal_FuzzWasHe": (0.3, 0.35), "Pedal_Octavius": (0.3, 0.3),
    ]
    /// Overdrives and boosts push the amp: drive + push * gain.
    static let boostPedals: [String: Double] = [
        "Pedal_LineDrive": 0.15, "Pedal_GermaniumDrive": 0.15, "Pedal_SuperDrive": 0.15,
        "Pedal_CustomDrive": 0.15, "Pedal_RangeBooster": 0.1,
    ]
    static let acoustic: Set<String> = ["Pedal_AcousticEmulator"]

    static func ampDrive(_ amp: String, gain: Double) -> Double {
        let name = amp.hasPrefix("Amp_") ? String(amp.dropFirst(4)) : amp
        let (crunch, heavy) = amps[name] ?? unknownAmp
        let g = min(max(gain, 0), 100)
        if g < crunch { return g / crunch / 3 }
        guard let heavy else { return 1.0 / 3 + (g - crunch) / (100 - crunch) * 0.25 }
        if g < heavy { return 1.0 / 3 + (g - crunch) / (heavy - crunch) / 3 }
        return 2.0 / 3 + (g - heavy) / max(100 - heavy, 1) / 3
    }

    /// The amp's gain knob (the Plexi has two Loudness knobs instead: the higher counts). As in
    /// rsfile.c, any knob named like a gain counts: some custom songs name knobs after another amp.
    static func gain(_ amp: Gear) -> Double? {
        amp.knobs.filter { name, _ in
            ["Gain", "Loudness1", "Loudness2"].contains { name == $0 || name.hasSuffix("_" + $0) }
        }.values.max()
    }

    /// How distorted the tone is, 0-1, or nil without an amp and its gain.
    static func drive(_ tone: Tone) -> Double? {
        guard let amp = tone.gear["Amp"], let g = gain(amp) else { return nil }
        var d = ampDrive(amp.key, gain: g)
        if tone.gear.values.contains(where: { acoustic.contains($0.key) }) { return min(d, 0.25) }
        let pedals = tone.gear.filter { $0.key.contains("Pedal") }.values.map {
            (key: $0.key, gain: min(max($0.knob("Gain", "Boost") ?? 0, 0), 100) / 100)
        }
        // Boosts first, then the pedals that distort by themselves (so the order doesn't matter).
        d += pedals.reduce(0) { $0 + (boostPedals[$1.key] ?? 0) * $1.gain }
        for p in pedals { if let dist = distortionPedals[p.key] { d = max(d, dist.floor + dist.span * p.gain) } }
        return min(d, 1)
    }

    /// "clean", "crunch" or "heavy" for a drive value, as rig.py's band(); nil if unknown.
    static func band(_ d: Double?) -> String? {
        guard let d else { return nil }
        return d < 1.0 / 3 ? "clean" : d < 2.0 / 3 ? "crunch" : "heavy"
    }

    /// A tone's drive for its category, which has the last word: whatever put a tone in Clean,
    /// Crunch or Heavy, a rule or an override, its drive stays in that band. Lead has no band.
    /// A band's top is where the next one starts, so a drive stops just below it, and band() agrees.
    static func corrected(_ drive: Double, category: Category) -> Double {
        guard category != .lead else { return min(max(drive, 0), 1) }
        let low = Double(category.rawValue) / 3
        return min(max(drive, low), category == .heavy ? 1 : (low + 1.0 / 3).nextDown)
    }

    // MARK: Effects

    struct Delay { let key: String; let time: Double?; let mix: Double?; let feedback: Double? }
    struct Reverb { let key: String; let mix: Double? }
    struct Modulation { let kind: String; let key: String; let mix: Double?; let rate: Double? }
    struct Pedal { let key: String; let gain: Double?; let tone: Double? }
    struct Effects {
        var delay: Delay?; var reverb: Reverb?; var mod: Modulation?
        var overdrive: Pedal?; var distortion: Pedal?
        /// What a device profile switches: delay, reverb, the modulation's kind, and the drive pedals.
        var kinds: Set<String> {
            Set((delay != nil ? ["delay"] : []) + (reverb != nil ? ["reverb"] : []) + (mod.map { [$0.kind] } ?? [])
                + (overdrive != nil ? ["overdrive"] : []) + (distortion != nil ? ["distortion"] : []))
        }
    }

    /// The drive pedals a device can play with its own, as rs-tonehost does (rearmed-mods, tonehost/helix/gear.json):
    /// boosts and overdrives, and distortion, metal and fuzz pedals. A key starting with one counts.
    static let overdrivePedals = ["Pedal_CustomDrive", "Pedal_GermaniumDrive", "Pedal_LineDrive", "Pedal_MarshallGuvnorPlus",
                                  "Pedal_RangeBooster", "Pedal_SuperDrive", "Bass_Pedal_BassOverdrive"]
    static let distortionPedalKeys = ["Pedal_Distortion", "Pedal_MetalDistortion", "Pedal_ShredZone", "Pedal_VintageDistortion",
                                      "Bass_Pedal_BassDistortion", "Pedal_BuzzOne", "Pedal_BuzzToo", "Pedal_CaptFuzzle",
                                      "Pedal_FuzzWasHe", "Bass_Pedal_BassFuzz"]

    /// Modulation by words in the gear key, first match wins.
    static let modulation: [(word: String, kind: String)] = [
        ("Flanger", "flanger"), ("Phase", "phaser"), ("Chorus", "chorus"), ("Enbig", "chorus"),
        ("Clones", "chorus"), ("Trem", "tremolo"), ("Vibe", "vibe"), ("Rota", "vibe"), ("OmniMod", "vibe"),
    ]
    static let reverbs = ["Verb", "Spring", "Chamber", "Plate"]

    /// The tone's delay, reverb and modulation, each the one with the most mix if it has several, and its
    /// drive pedals, each the one with the most gain.
    static func effects(_ tone: Tone) -> Effects {
        var fx = Effects()
        // Ties go to the first in slot order, as in rig.py.
        func more(_ mix: Double?, than kept: Double??) -> Bool { kept == nil || (mix ?? 0) > ((kept ?? nil) ?? 0) }
        func louder(_ p: Pedal, than kept: Pedal?) -> Bool { kept.map { (p.gain ?? 0) > ($0.gain ?? 0) } ?? true }
        for (slot, item) in tone.gear.sorted(by: { $0.key < $1.key }) where slot != "Amp" && slot != "Cabinet" {
            let mix = item.knobs["Mix"]
            let pedal = Pedal(key: item.key, gain: item.knob("Gain", "Boost"), tone: item.knobs["Tone"])
            if overdrivePedals.contains(where: item.key.hasPrefix) {
                if louder(pedal, than: fx.overdrive) { fx.overdrive = pedal }
            } else if distortionPedalKeys.contains(where: item.key.hasPrefix) {
                if louder(pedal, than: fx.distortion) { fx.distortion = pedal }
            } else if item.knobs["Feedback"] != nil, let time = item.knob("Time", "TimeL") {
                if more(mix, than: fx.delay.map { $0.mix }) {
                    fx.delay = Delay(key: item.key, time: time, mix: mix, feedback: item.knobs["Feedback"])
                }
            } else if reverbs.contains(where: { item.key.contains($0) }) {
                if more(mix, than: fx.reverb.map { $0.mix }) { fx.reverb = Reverb(key: item.key, mix: mix) }
            } else if let kind = modulation.first(where: { item.key.contains($0.word) })?.kind {
                if more(mix, than: fx.mod.map { $0.mix }) {
                    fx.mod = Modulation(kind: kind, key: item.key, mix: mix, rate: item.knob("Rate", "Speed"))
                }
            }
        }
        return fx
    }

    /// The amps whose Bass, Mid and Treble are in dB, -12 to 12, where every other amp's go from 0 to 100
    /// (the game's gears.psarc, manifests/gears; rs-tonehost's tone_db has the same nine).
    static let toneKnobsInDB: Set<String> = ["Bass_Amp_BT880B", "Bass_Amp_BT975B", "Bass_Amp_CH300B", "Bass_Amp_CH600B",
                                             "Bass_Amp_CS75B", "Bass_Amp_EdenE300", "Bass_Amp_EdenWT550",
                                             "Bass_Amp_EdenWT800", "Bass_Amp_HT400B"]

    /// An amp's tone knob on the 0-100 of every other amp's: on those in dB, 0 dB is the middle, as rs-tonehost has it.
    static func toneKnob(_ amp: Gear?, _ name: String) -> Double? {
        guard let amp, let v = amp.knobs[name] else { return nil }
        return toneKnobsInDB.contains(amp.key) ? 50 + v * 100 / 24 : v
    }

    /// The broad shape of a tone's EQ pedals and racks, in dB: how much they raise or cut the lows (under 300 Hz),
    /// the mids (to 2 kHz) and the highs, all of them added up, each within ±12 dB. A graphic EQ's bands are
    /// averaged in each region; the Studio EQs' Bass and Treble are shelves, so they count in full for the lows and
    /// the highs, and their mid bands, which are narrower, count by half where their frequency is.
    /// nil without an EQ.
    static func eqShape(_ tone: Tone) -> (low: Double, mid: Double, high: Double)? {
        func region(_ hz: Double) -> Int { hz < 300 ? 0 : hz < 2000 ? 1 : 2 }
        var shape = [0.0, 0.0, 0.0], any = false
        for item in tone.gear.values {
            switch item.key {
            case "Pedal_EQ5", "Pedal_EQ8", "Bass_Pedal_BassEQ8":   // knobs named by their frequency in Hz
                var sums = [0.0, 0.0, 0.0], counts = [0.0, 0.0, 0.0]
                for (name, gain) in item.knobs {
                    guard let hz = Double(name) else { continue }
                    sums[region(hz)] += gain
                    counts[region(hz)] += 1
                }
                for r in 0..<3 where counts[r] > 0 { shape[r] += sums[r] / counts[r] }
                any = true
            case "Rack_StudioEQ", "Rack_StudioGraphicEQ":           // the mid bands' frequency in Hz, or kHz under 20
                shape[0] += item.knobs["Bass"] ?? 0
                shape[2] += item.knobs["Treble"] ?? 0
                for band in ["LoMid", "Mid", "HiMid"] {
                    guard let gain = item.knobs[band], let f = item.knobs[band + "Freq"] else { continue }
                    shape[region(f < 20 ? f * 1000 : f)] += gain / 2
                }
                any = true
            default:
                continue
            }
        }
        guard any else { return nil }
        let clamp = { (x: Double) in min(max(x, -12), 12) }
        return (clamp(shape[0]), clamp(shape[1]), clamp(shape[2]))
    }

    /// dB of an EQ's shape onto an amp's tone knob: ±12 dB is half the knob's travel, as on the amps whose knobs are in dB
    static let eqKnobPerDB = 100.0 / 24

    /// The amp's tone knob with the tone's EQ folded in, 0-100; nil where the amp has no such knob.
    static func toneKnobWithEQ(_ tone: Tone, _ name: String) -> Double? {
        guard let knob = toneKnob(tone.gear["Amp"], name) else { return nil }
        guard let eq = eqShape(tone) else { return knob }
        let db = name == "Bass" ? eq.low : name == "Mid" ? eq.mid : eq.high
        return min(max(knob + db * eqKnobPerDB, 0), 100)
    }

    /// The Lo-Fi Filter's mix, 0-100, where the tone has one: how far a band limit goes
    static func lofi(_ tone: Tone) -> Double? {
        tone.gear.values.first { $0.key == "Pedal_LoFiFilter" }.map { $0.knobs["Mix"] ?? 100 }
    }

    /// What a device profile's knobs read (Profile.knobSources), as the song's gear sets them; what
    /// the tone doesn't have is left out. The drive isn't here: it depends on the song (corrected).
    static func values(_ tone: Tone) -> [String: Double] {
        let fx = effects(tone), amp = tone.gear["Amp"]
        let all: [String: Double?] = [
            "gain": amp.flatMap(gain), "bass": toneKnob(amp, "Bass"), "mid": toneKnob(amp, "Mid"),
            "treble": toneKnob(amp, "Treble"), "presence": amp?.knobs["Pres"],
            "bass_eq": toneKnobWithEQ(tone, "Bass"), "mid_eq": toneKnobWithEQ(tone, "Mid"),
            "treble_eq": toneKnobWithEQ(tone, "Treble"), "lofi": lofi(tone),
            "delay_time": fx.delay?.time, "delay_mix": fx.delay?.mix, "delay_feedback": fx.delay?.feedback,
            "reverb_mix": fx.reverb?.mix, "modulation_mix": fx.mod?.mix, "modulation_rate": fx.mod?.rate,
            "overdrive_gain": fx.overdrive?.gain, "overdrive_tone": fx.overdrive?.tone, "distortion_gain": fx.distortion?.gain,
        ]
        return all.compactMapValues { $0 }
    }

    // MARK: Songs

    /// The arrangement's tone for a slot's tone key. Some custom songs name the slot a little
    /// differently from the tone ("Hotel California" for "HotelCalifornia"): then the tone whose
    /// key matches without spaces and punctuation, or the only tone there is.
    static func tone(_ a: Arrangement, key: String) -> Tone? {
        let loose = { (k: String) in k.lowercased().filter { $0.isLetter || $0.isNumber } }
        return a.tones.first { $0.key.lowercased() == key.lowercased() }
            ?? a.tones.first { loose($0.key) == loose(key) }
            ?? (a.tones.count == 1 ? a.tones[0] : nil)
    }

    /// The slots' tone keys in the order the song first plays them (Base first), each once
    /// (case-insensitively), with the seconds each plays.
    static func toneOrder(_ a: Arrangement) -> [(key: String, seconds: Double)] {
        let end = a.length ?? a.changes.last?.time ?? 0
        var order: [(key: String, seconds: Double)] = []
        func add(_ key: String, _ seconds: Double) {
            guard !key.isEmpty else { return }
            if let i = order.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
                order[i].seconds += seconds
            } else {
                order.append((key, seconds))
            }
        }
        var key = a.slots.first ?? "", start = 0.0
        for (time, id) in a.changes {
            add(key, max(min(time, end) - start, 0))
            if (0..<4).contains(id), a.slots.indices.contains(id + 1), !a.slots[id + 1].isEmpty {
                key = a.slots[id + 1]
            }
            start = time
        }
        add(key, max(end - start, 0))
        return order
    }

    /// How heavy a song is, 0-1: the drive of the tone its rhythm part (else its combo or lead
    /// part) plays longest, plus 0.1 when the lowest string is at C or lower (also the B of an
    /// extended-range 7-string). Of several parts of a kind (combo, combo2) the first by name counts.
    static func heaviness(_ arrangements: [Arrangement]) -> Double? {
        let sorted = arrangements.sorted { $0.name.lowercased() < $1.name.lowercased() }  // main part before alternates
        for path in ["Rhythm", "Combo", "Lead"] {
            for a in sorted where a.path == path {
                // The longest; of equally long ones the first played, as in rig.py.
                guard let main = toneOrder(a).reduce(nil, { (best: (key: String, seconds: Double)?, t) in
                          best.map { t.seconds > $0.seconds ? t : $0 } ?? t
                      }),
                      let t = tone(a, key: main.key), let d = drive(t) else { continue }
                return min(d + (a.lowString <= -4 ? 0.1 : 0), 1)
            }
        }
        return nil
    }

    // MARK: Reading

    /// Every arrangement (but vocals) of the song whose files start with `prefix` (e.g.
    /// "selftrap"), or nil if the archive can't be read.
    static func read(archive: String, prefix: String) -> [Arrangement]? {
        guard let p = rs_psarc_open(archive) else { return nil }
        defer { rs_psarc_close(p) }
        func read(_ path: String) -> Data? {
            guard let e = rs_psarc_find(p, path) else { return nil }
            var len = 0
            guard let bytes = rs_psarc_read(p, e, &len) else { return nil }
            defer { free(bytes) }
            return Data(bytes: bytes, count: len)
        }
        let manifests = (0..<Int(p.pointee.n)).map { String(cString: p.pointee.e[$0].path) }.filter {
            $0.hasPrefix("manifests/") && $0.hasSuffix(".json")
                && ($0 as NSString).lastPathComponent.lowercased().hasPrefix(prefix.lowercased() + "_")
        }
        var out: [Arrangement] = []
        for path in manifests.sorted() {
            guard let data = read(path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = (json["Entries"] as? [String: Any])?.values.first as? [String: Any],
                  let a = entry["Attributes"] as? [String: Any],
                  let kind = a["ArrangementName"] as? String, kind != "Vocals" else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var changes: [(time: Double, id: Int)] = []
            if let sng = read("songs/bin/macos/\(name).sng") {
                sng.withUnsafeBytes { buf in
                    var list: UnsafeMutablePointer<rs_tone_change>?
                    guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return }
                    let n = rs_sng_tones(base, sng.count, &list)
                    for i in 0..<max(Int(n), 0) { changes.append((Double(list![i].time), Int(list![i].id))) }
                    free(list)
                }
            }
            let tuning = Self.tuning(a, bass: kind == "Bass")
            out.append(Arrangement(
                name: name, path: kind,
                slots: ["Tone_Base", "Tone_A", "Tone_B", "Tone_C", "Tone_D"].map { a[$0] as? String ?? "" },
                tones: ((a["Tones"] as? [[String: Any]]) ?? []).map(tone),
                changes: changes, length: (a["SongLength"] as? NSNumber)?.doubleValue, lowString: tuning?.lowString ?? 0,
                tempo: (a["SongAverageTempo"] as? NSNumber)?.doubleValue, tuning: tuning))
        }
        return out
    }

    /// A manifest's tone: its key and GearList, knobs named without the gear key's prefix.
    private static func tone(_ t: [String: Any]) -> Tone {
        var gear: [String: Gear] = [:]
        for case let (slot, item as [String: Any]) in (t["GearList"] as? [String: Any]) ?? [:] {
            guard let key = item["Key"] as? String else { continue }
            var knobs: [String: Double] = [:]
            for case let (name, value as NSNumber) in (item["KnobValues"] as? [String: Any]) ?? [:] {
                knobs[name.hasPrefix(key + "_") ? String(name.dropFirst(key.count + 1)) : name] = value.doubleValue
            }
            gear[slot] = Gear(key: key, knobs: knobs)
        }
        // "$[35716]CLEAN" -> "CLEAN"
        let descriptors = ((t["ToneDescriptors"] as? [String]) ?? []).map { d -> String in
            guard d.hasPrefix("$["), let end = d.firstIndex(of: "]") else { return d }
            return String(d[d.index(after: end)...])
        }
        return Tone(key: t["Key"] as? String ?? "", gear: gear, descriptors: descriptors)
    }
}
