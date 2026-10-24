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
        let lowString: Double           // the low string's tuning in semitones, with the cent offset
        let tempo: Double?
        var strings: [Int] = []         // each string's tuning in semitones, low string first
    }

    static let notes = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// "E standard", "Drop D", "Eb standard", ... or "custom" (nil if unknown), as rig.py's tuning_name.
    static func tuningName(_ a: Arrangement) -> String? {
        let strings = Array(a.strings.prefix(a.path == "Bass" ? 4 : 6))
        guard let low = strings.first else { return nil }
        let rest = Set(strings.dropFirst())
        guard rest.count == 1, let r = rest.first else { return "custom" }
        if low == r { return "\(notes[((4 + r) % 12 + 12) % 12]) standard" }
        if low == r - 2 { return "Drop \(notes[((2 + r) % 12 + 12) % 12])" }
        return "custom"
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

    // MARK: Effects

    struct Delay { let key: String; let time: Double?; let mix: Double?; let feedback: Double? }
    struct Reverb { let key: String; let mix: Double? }
    struct Modulation { let kind: String; let key: String; let mix: Double?; let rate: Double? }
    struct Effects { var delay: Delay?; var reverb: Reverb?; var mod: Modulation? }

    /// Modulation by words in the gear key, first match wins.
    static let modulation: [(word: String, kind: String)] = [
        ("Flanger", "flanger"), ("Phase", "phaser"), ("Chorus", "chorus"), ("Enbig", "chorus"),
        ("Clones", "chorus"), ("Trem", "tremolo"), ("Vibe", "vibe"), ("Rota", "vibe"), ("OmniMod", "vibe"),
    ]
    static let reverbs = ["Verb", "Spring", "Chamber", "Plate"]

    /// The tone's delay, reverb and modulation, each the one with the most mix if it has several.
    static func effects(_ tone: Tone) -> Effects {
        var fx = Effects()
        // Ties go to the first in slot order, as in rig.py.
        func more(_ mix: Double?, than kept: Double??) -> Bool { kept == nil || (mix ?? 0) > ((kept ?? nil) ?? 0) }
        for (slot, item) in tone.gear.sorted(by: { $0.key < $1.key }) where slot != "Amp" && slot != "Cabinet" {
            let mix = item.knobs["Mix"]
            if item.knobs["Feedback"] != nil, let time = item.knob("Time", "TimeL") {
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
    /// part) plays longest, plus 0.1 when the low string is tuned down to C or lower. Of several
    /// parts of a kind (combo, combo2) the first by name counts.
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
            let tuning = a["Tuning"] as? [String: Any]
            let low = ((tuning?["string0"] as? NSNumber)?.doubleValue ?? 0)
                + ((a["CentOffset"] as? NSNumber)?.doubleValue ?? 0) / 100
            out.append(Arrangement(
                name: name, path: kind,
                slots: ["Tone_Base", "Tone_A", "Tone_B", "Tone_C", "Tone_D"].map { a[$0] as? String ?? "" },
                tones: ((a["Tones"] as? [[String: Any]]) ?? []).map(tone),
                changes: changes, length: (a["SongLength"] as? NSNumber)?.doubleValue, lowString: low,
                tempo: (a["SongAverageTempo"] as? NSNumber)?.doubleValue,
                strings: (0..<6).compactMap { (tuning?["string\($0)"] as? NSNumber)?.intValue }))
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
