import Foundation

/// Song tone messages: when a song loads, one SysEx (manufacturer 0x7D, then JSON) describes the
/// arrangement's tones, in the order the song first plays them, for any tool that builds or picks
/// a sound per song tone (Bandbox Stagehand is one). During the song Program Change first + i
/// plays tone i, unless "song_tone_programs" is off: then the category programs play as without it.
///
/// It describes, in Rocksmith's terms, and leaves the device's terms to the device: each tone's
/// category (as presets.json maps it), and its delay, modulation and reverb as the song's gear
/// sets them (an effect left out: the tone has none; knobs as Rocksmith has them, mix 0-100).
/// "style" labels the song by its heaviness ("styles" in presets.json); "styles" lists every
/// label a song may get.
///
///   {"v": 2, "kind": "song-tones", "song": "18 And Life", "artist": "Skid Row",
///    "arrangement": "skid18an_lead", "heaviness": 0.72, "tempo": 92.4, "low_string": 0,
///    "style": "Classic rock", "styles": ["Soft", "Classic rock", "Metal"], "main_amp": "Amp_MarshallJCM800",
///    "tones": [{"program": 8, "key": "skid18an_clean", "category": "Clean", "drive": 0.21,
///               "amp": {"gear": "Amp_MarshallJCM800", "gain": 30, "bass": 50, "mid": 60, "treble": 55},
///               "effects": {"modulation": {"kind": "chorus", "gear": "Pedal_Chorus", "mix": 60, "rate": 2.5},
///                           "reverb": {"gear": "Rack_StudioVerb", "mix": 25}}},
///              {"program": 9, "key": "skid18an_dist", "category": "Heavy",
///               "effects": {"delay": {"kind": "analog", "gear": "Pedal_AnalogueDelay", "time_ms": 400,
///                                     "mix": 30, "feedback": 20}}}, ...]}
///
/// Delay kinds: tape, analog, modulated, digital. Modulation kinds: chorus, flanger, phaser,
/// tremolo, vibe. "drive" is how distorted the tone should sound, 0-1, for the record and its
/// category (Rig.corrected); "amp" is the tone's amp as the song sets it, and "main_amp" the amp
/// the arrangement plays longest.
struct SongTones {
    static let defaultFirstProgram = 8
    static let maxTones = 5         // Base and A-D

    struct Tone {
        let key: String
        let category: Category
        let effects: Rig.Effects
        var drive: Double? = nil        // Rig.corrected
        var amp: Rig.Gear? = nil
        var values: [String: Double] = [:]  // what a profile's knobs read (Profile.knobSources)
    }

    let song: String
    let artist: String
    let arrangement: String
    let style: String
    /// Every style a song may get, so a tool can prepare for each (Stagehand makes a bank per style).
    var styles: [String] = []
    let heaviness: Double?
    let tempo: Double?
    let lowString: Double?
    let firstProgram: Int
    let tones: [Tone]
    /// The arrangement's amps in the order it plays them, with the seconds each plays.
    var amps: [(key: String, seconds: Double)] = []

    /// The amp the arrangement plays longest; of equally long ones the first played.
    var mainAmp: String? {
        amps.reduce(nil) { (best: (key: String, seconds: Double)?, a) in best.map { a.seconds > $0.seconds ? a : $0 } ?? a }?.key
    }

    /// The program that plays a tone key, or nil if it isn't one of the song's tones.
    func program(for key: String) -> Int? {
        tones.firstIndex { $0.key.lowercased() == key.lowercased() }.map { firstProgram + $0 }
    }

    /// Describes the tones of `arrangement` from the song's arrangements as read from its archive.
    /// `category` maps a slot and tone key to the tone's category, `style` a heaviness to a style.
    /// `gainOffset` is the AI's correction for the song, in drive bands.
    static func make(song: String, artist: String, arrangement name: String, from arrangements: [Rig.Arrangement],
                     firstProgram: Int = defaultFirstProgram, gainOffset: Double = 0,
                     category: (_ slot: String, _ key: String) -> Category, style: (Double?) -> String) -> SongTones? {
        guard let a = arrangements.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        let slots = ["Base", "A", "B", "C", "D"]
        let tones = Rig.toneOrder(a).prefix(maxTones).map { entry -> Tone in
            let slot = a.slots.firstIndex { $0.lowercased() == entry.key.lowercased() }.map { slots[$0] } ?? "Base"
            let c = category(slot, entry.key)
            guard let t = Rig.tone(a, key: entry.key) else { return Tone(key: entry.key, category: c, effects: Rig.Effects()) }
            let drive = Rig.drive(t).map { Rig.corrected($0, offset: gainOffset, category: c) }
            var values = Rig.values(t)
            values["drive"] = drive
            return Tone(key: entry.key, category: c, effects: Rig.effects(t), drive: drive, amp: t.gear["Amp"], values: values)
        }
        var amps: [(key: String, seconds: Double)] = []
        for entry in Rig.toneOrder(a) {
            guard let key = Rig.tone(a, key: entry.key)?.gear["Amp"]?.key else { continue }
            if let i = amps.firstIndex(where: { $0.key == key }) { amps[i].seconds += entry.seconds } else { amps.append((key, entry.seconds)) }
        }
        let heaviness = Rig.heaviness(arrangements)
        return SongTones(song: song, artist: artist, arrangement: a.name, style: style(heaviness), heaviness: heaviness,
                         tempo: a.tempo ?? arrangements.compactMap(\.tempo).first, lowString: a.lowString,
                         firstProgram: firstProgram, tones: Array(tones), amps: amps)
    }

    /// A tone's amp for the message: its model and the knobs every amp has, as the song sets them.
    static func amp(_ gear: Rig.Gear) -> [String: Any] {
        var out: [String: Any] = ["gear": gear.key]
        for (name, value) in [("gain", Rig.gain(gear)), ("bass", gear.knobs["Bass"]), ("mid", gear.knobs["Mid"]),
                              ("treble", gear.knobs["Treble"]), ("presence", gear.knobs["Pres"])] {
            if let value { out[name] = decimal(value, places: 1) }
        }
        return out
    }

    /// A tone's effects for the message: what the song's gear has, no more.
    static func effects(_ fx: Rig.Effects) -> [String: [String: Any]] {
        func number(_ v: Double) -> NSDecimalNumber { decimal(v, places: 1) }
        var out: [String: [String: Any]] = [:]
        if let d = fx.delay {
            var delay: [String: Any] = ["kind": delayKind(d.key), "gear": d.key]
            if let t = d.time { delay["time_ms"] = number(t) }
            if let m = d.mix { delay["mix"] = number(m) }
            if let f = d.feedback { delay["feedback"] = number(f) }
            out["delay"] = delay
        }
        if let m = fx.mod {
            var mod: [String: Any] = ["kind": m.kind, "gear": m.key]
            if let mix = m.mix { mod["mix"] = number(mix) }
            if let rate = m.rate { mod["rate"] = number(rate) }
            out["modulation"] = mod
        }
        if let r = fx.reverb {
            var reverb: [String: Any] = ["gear": r.key]
            if let mix = r.mix { reverb["mix"] = number(mix) }
            out["reverb"] = reverb
        }
        return out
    }

    /// `v` to `places` decimals, as JSON prints it (a Double prints 0.57 as 0.56999999999999995).
    static func decimal(_ v: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", v), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// What kind of delay a Rocksmith delay pedal or rack is.
    static func delayKind(_ gear: String) -> String {
        if ["TapeEcho", "ValveEcho", "OilCanEcho", "NoFiEcho", "CosmicEcho"].contains(where: gear.contains) { return "tape" }
        if ["AnalogueDelay", "NPNDelay"].contains(where: gear.contains) { return "analog" }
        if gear.contains("ModDelay") { return "modulated" }
        return "digital"
    }

    /// The message as JSON text, 7-bit clean (other characters as \u escapes) for SysEx.
    var json: String {
        var body: [String: Any] = [
            "v": 2, "kind": "song-tones", "song": song, "artist": artist, "arrangement": arrangement,
            "style": style, "styles": styles,
            "tones": tones.enumerated().map { i, t in
                var tone: [String: Any] = ["program": firstProgram + i, "key": t.key, "category": t.category.name,
                                           "effects": Self.effects(t.effects)]
                tone["drive"] = t.drive.map { Self.decimal($0, places: 2) }
                tone["amp"] = t.amp.map(Self.amp)
                return tone
            },
        ]
        body["main_amp"] = mainAmp
        body["heaviness"] = heaviness.map { Self.decimal($0, places: 2) }
        body["tempo"] = tempo.map { Self.decimal($0, places: 1) }
        body["low_string"] = lowString.map { Self.decimal($0, places: 2) }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        var out = ""
        for unit in text.utf16 {
            if unit < 0x80 { out.unicodeScalars.append(Unicode.Scalar(unit)!) } else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }

    /// One line for the log: "Classic rock (0.72): 8 skid18an_clean Clean +modulation chorus +reverb, 9 ..."
    var summary: String {
        let h = heaviness.map { String(format: "%.2f", $0) } ?? "?"
        return "\(style) (\(h)): " + tones.enumerated().map { i, t in
            var on: [String] = []
            if let d = t.effects.delay { on.append("delay \(Self.delayKind(d.key))") }
            if let m = t.effects.mod { on.append("modulation \(m.kind)") }
            if t.effects.reverb != nil { on.append("reverb") }
            return "\(firstProgram + i) \(t.key) \(t.category.name)" + (on.isEmpty ? "" : " +" + on.joined(separator: " +"))
        }.joined(separator: ", ")
    }
}
