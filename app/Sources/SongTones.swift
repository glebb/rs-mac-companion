import Foundation

/// Song-made tones for Stagehand (rig-plan.md): when a song loads, a message tells Stagehand to
/// fill its scratch tones, one per tone of the arrangement in the order the song first plays
/// them; during the song Program Change 8 + i plays scratch tone i.
///
/// Each scratch tone starts as a copy of a tone in one of the player's rigs (the rig picked by
/// the song's heaviness, the tone by the tone's category, as mapped by presets.json) and takes
/// the song tone's time and modulation effects. Only FX, Delay and Reverb are set, so each tone
/// keeps its template's level. Names are the JBL app's, as Stagehand shows them.
///
///   {"v": 1, "kind": "song-tones", "song": "18 And Life", "artist": "Skid Row", "rig": "Classic rock",
///    "tones": [{"program": 8, "key": "skid18an_clean", "base": "Clean",
///               "set": {"FX": {"on": true, "model": "Chorus", "Mix": 35}, "Delay": {"on": false},
///                       "Reverb": {"on": true, "Mix": 25}}}, ...]}
struct SongTones {
    static let firstProgram = 8
    static let maxTones = 5         // Base and A-D
    static let maxMix = 35.0        // so a wet tone doesn't get louder than its template

    struct Tone {
        let key: String
        let base: Category
        let set: [String: [String: Any]]
    }

    let song: String
    let artist: String
    let rig: String
    let heaviness: Double?
    let tones: [Tone]

    /// The program that plays a tone key, or nil if it isn't one of the song's tones.
    func program(for key: String) -> Int? {
        tones.firstIndex { $0.key.lowercased() == key.lowercased() }.map { Self.firstProgram + $0 }
    }

    /// Builds the tones of `arrangement` from the song's arrangements as read from its archive.
    /// `category` maps a slot and tone key to the template category, `rig` a heaviness to a rig.
    static func make(song: String, artist: String, arrangement name: String, from arrangements: [Rig.Arrangement],
                     category: (_ slot: String, _ key: String) -> Category, rig: (Double?) -> String) -> SongTones? {
        guard let a = arrangements.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        let slots = ["Base", "A", "B", "C", "D"]
        let tempo = a.tempo ?? arrangements.compactMap(\.tempo).first
        let tones = Rig.toneOrder(a).prefix(maxTones).map { entry -> Tone in
            let slot = a.slots.firstIndex { $0.lowercased() == entry.key.lowercased() }.map { slots[$0] } ?? "Base"
            let fx = Rig.tone(a, key: entry.key).map(Rig.effects) ?? Rig.Effects()
            return Tone(key: entry.key, base: category(slot, entry.key), set: settings(fx, tempo: tempo))
        }
        let heaviness = Rig.heaviness(arrangements)
        return SongTones(song: song, artist: artist, rig: rig(heaviness), heaviness: heaviness, tones: Array(tones))
    }

    /// What a scratch tone changes in its template: FX and Delay follow the song tone (on with
    /// its model and mix, or off); Reverb only when the song tone has one.
    static func settings(_ fx: Rig.Effects, tempo: Double?) -> [String: [String: Any]] {
        var set: [String: [String: Any]] = [:]
        if let d = fx.delay {
            let time = d.time ?? tempo.map { 60000 / $0 } ?? 400
            var delay: [String: Any] = ["on": true, "model": delayModel(d.key), "Time": round(min(max(time, 20), 1000))]
            if let mix = d.mix { delay["Mix"] = round(min(mix, maxMix)) }
            if let fb = d.feedback { delay["Fdbk"] = round(min(max(fb, 0), 100)) }
            set["Delay"] = delay
        } else {
            set["Delay"] = ["on": false]
        }
        if let m = fx.mod {
            var mod: [String: Any] = ["on": true, "model": modModel(m.kind)]
            if m.kind == "chorus", let mix = m.mix { mod["Mix"] = round(min(mix, maxMix)) }  // the others have no Mix
            set["FX"] = mod
        } else {
            set["FX"] = ["on": false]
        }
        if let r = fx.reverb {
            var reverb: [String: Any] = ["on": true]
            if let mix = r.mix { reverb["Mix"] = round(min(mix, maxMix)) }
            set["Reverb"] = reverb
        }
        return set
    }

    /// The BandBox delay closest to a Rocksmith delay.
    static func delayModel(_ key: String) -> String {
        if ["TapeEcho", "ValveEcho", "OilCanEcho", "NoFiEcho", "CosmicEcho"].contains(where: key.contains) { return "Echopress 900" }
        if ["AnalogueDelay", "NPNDelay"].contains(where: key.contains) { return "Analog Echo" }
        if key.contains("ModDelay") { return "Sweep Echo" }
        return "Pure Echo"
    }

    static func modModel(_ kind: String) -> String {
        switch kind {
        case "flanger": "Jetter Flanger"
        case "phaser": "Green Phaser"
        case "tremolo": "Tremolo"
        case "vibe": "Minivibe"
        default: "Chorus"
        }
    }

    /// The message as JSON text, 7-bit clean (other characters as \u escapes) for SysEx.
    var json: String {
        let body: [String: Any] = [
            "v": 1, "kind": "song-tones", "song": song, "artist": artist, "rig": rig,
            "tones": tones.enumerated().map { i, t in
                ["program": Self.firstProgram + i, "key": t.key, "base": t.base.name, "set": t.set] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        var out = ""
        for unit in text.utf16 {
            if unit < 0x80 { out.unicodeScalars.append(Unicode.Scalar(unit)!) } else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }

    /// One line for the log: "Classic rock (0.62): 8 skid18an_clean Clean +FX Chorus, 9 ..."
    var summary: String {
        let h = heaviness.map { String(format: "%.2f", $0) } ?? "?"
        return "\(rig) (\(h)): " + tones.enumerated().map { i, t in
            let on = ["FX", "Delay", "Reverb"].compactMap { name -> String? in
                guard let s = t.set[name], s["on"] as? Bool == true else { return nil }
                return (s["model"] as? String).map { "\(name) \($0)" } ?? name
            }
            return "\(Self.firstProgram + i) \(t.key) \(t.base.name)" + (on.isEmpty ? "" : " +" + on.joined(separator: " +"))
        }.joined(separator: ", ")
    }
}
