import Foundation

/// What RS Companion sends and where: a device or tool's half of the deal, in a JSON file in
/// DATA_DIR/profiles (docs/device-profiles.md). The app knows Rocksmith; a profile knows the gear.
struct Profile: Equatable, Identifiable {
    enum Step: Equatable {
        case pc(Int)
        case cc(Int, Int)
        case wait(Int)              // milliseconds
        case bytes([UInt8])         // one MIDI message, as it is
        case songTonesMessage       // the SysEx describing the song's tones (SongTones.swift)

        var label: String {
            switch self {
            case .pc(let p): "PC \(p)"
            case .cc(let n, let v): "CC \(n) = \(v)"
            case .wait(let ms): "wait \(ms) ms"
            case .bytes(let b): b.map { String(format: "%02X", $0) }.joined(separator: " ")
            case .songTonesMessage: "song tones"
            }
        }
    }

    enum Destination: Equatable {
        case virtual                // the virtual source "Rocksmith Companion", for apps that listen
        case device(String)         // sent straight to the MIDI destination of this name
    }

    /// A CC that follows a value of the tone (knobSources), or a sum of terms of them: the value's
    /// range onto 0-127.
    struct Knob: Equatable {
        var cc: Int
        var from: String            // "" for a knob with terms
        var range: [Double]         // the value at CC 0, and at CC 127
        var fallback: Int?          // sent for a tone without the value; nil sends nothing
        var rangeWith: [String: [Double]] = [:]  // effect kind -> the range for a tone that has it
        var terms: [Term] = []

        /// One part of a knob's sum: a constant, or a value of the tone through straight lines
        /// between points, counted only for a tone with the effect `with` if given.
        struct Term: Equatable {
            var add: Double = 0
            var from: String?
            var points: [[Double]] = []     // [value, result], by value
            var with: String?

            func value(_ values: [String: Double], kinds: Set<String>) -> Double? {
                guard let from else { return add }
                guard let v = values[from], with.map(kinds.contains) ?? true else { return nil }
                guard let first = points.first, let last = points.last else { return add }
                if v <= first[0] { return add + first[1] }
                for (a, b) in zip(points, points.dropFirst()) where v <= b[0] {
                    return add + a[1] + (b[1] - a[1]) * (v - a[0]) / (b[0] - a[0])
                }
                return add + last[1]
            }
        }

        func value(_ values: [String: Double], kinds: Set<String> = []) -> Int? {
            let v: Double
            if terms.isEmpty {
                guard let x = values[from] else { return fallback }
                v = x
            } else {
                let parts = terms.map { ($0.from, $0.value(values, kinds: kinds)) }
                guard parts.contains(where: { $0.0 != nil && $0.1 != nil }) else { return fallback }
                v = parts.compactMap(\.1).reduce(0, +)
            }
            let r = rangeWith.keys.sorted().first(where: kinds.contains).flatMap { rangeWith[$0] } ?? range
            return Int((min(max((v - r[0]) / (r[1] - r[0]), 0), 1) * 127).rounded())
        }
    }

    /// A delay for a category's tones that have none of their own (addDelay): its time in beats of
    /// the song's tempo, its mix and feedback as the song's pedals have them (0-100).
    struct AddedDelay: Equatable {
        var beats: Double
        var mix: Double
        var feedback: Double

        static let tempoUnknown = 120.0     // beats per minute, for a song whose tempo isn't known
    }

    struct Invalid: Error { let why: String }

    /// The file name without .json.
    var id = ""
    var name = ""
    var destination = Destination.virtual
    var channel = 1
    /// By style; "*" is any style without its own.
    var songLoad: [String: [Step]] = [:]
    /// By the song's amp ("Amp_CA100"), ahead of songLoad.
    var ampLoad: [String: [Step]] = [:]
    /// Run the song's load sequence again when the song is described anew (its mapping or AI
    /// answer changed). Off, a device isn't switched while the song plays.
    var songLoadAgain = false
    /// Per category, by Category.rawValue.
    var category: [[Step]] = Category.allCases.map { _ in [] }
    /// "Lead clean": a category's steps for its tones whose drive is in that band, ahead of `category`.
    var categoryByBand: [String: [Step]] = [:]
    /// Song tone i plays on this Program Change + i, instead of its category's steps.
    var toneFirstProgram: Int?
    /// Effect kind (see effectKinds) -> CC, 127 when the tone has it and 0 when not.
    var effects: [String: Int] = [:]
    var knobs: [Knob] = []
    /// By the song's amp, as in ampLoad: knobs that take the place of the ones on the same CC, or add to them.
    var ampKnobs: [String: [Knob]] = [:]
    /// By category name, or category and band ("Lead crunch", which wins): a delay for those tones that have
    /// none, so a lead isn't only louder.
    var addDelay: [String: AddedDelay] = [:]

    static let defaultID = "program-changes"
    static let effectKinds = ["delay", "reverb", "chorus", "flanger", "phaser", "tremolo", "vibe", "overdrive", "distortion"]
    static let bands = ["clean", "crunch", "heavy"]
    /// What a knob can follow, with its range when the file gives none. See Rig.values.
    static let knobSources: [String: [Double]] = [
        "drive": [0, 1], "gain": [0, 100], "bass": [0, 100], "mid": [0, 100], "treble": [0, 100], "presence": [0, 100],
        "delay_time": [0, 2000], "delay_mix": [0, 100], "delay_feedback": [0, 100],
        "reverb_mix": [0, 100], "modulation_mix": [0, 100], "modulation_rate": [0, 100],
        "overdrive_gain": [0, 100], "overdrive_tone": [0, 100], "distortion_gain": [0, 100],
    ]

    /// Used when no profile can be read: nothing but the category Program Changes, from the
    /// virtual source.
    static let plain = Profile(id: defaultID, name: "Program Changes",
                               category: Category.allCases.map { [.pc($0.rawValue)] })

    /// Whether the song's gear has to be read from its archive. A band's steps need the tone's drive,
    /// and an added delay the song's tempo and whether the tone has a delay of its own.
    var needsSongData: Bool {
        !songLoad.isEmpty || !ampLoad.isEmpty || toneFirstProgram != nil || !effects.isEmpty || !knobs.isEmpty
            || !ampKnobs.isEmpty || !categoryByBand.isEmpty || !addDelay.isEmpty
    }

    /// A category's steps for a tone with this drive: its band's ("Lead clean") if the profile has
    /// them, else the category's own.
    func categorySteps(_ c: Category, drive: Double?) -> [Step] {
        Rig.band(drive).flatMap { categoryByBand[c.name + " " + $0] } ?? category[c.rawValue]
    }

    /// The amp whose sequence plays the song: of those listed in ampLoad, the one that plays longest,
    /// amps with the same sequence counting as one (of equally long ones the first played); nil if
    /// none is listed.
    func songAmp(_ amps: [(key: String, seconds: Double)]) -> String? {
        var found: [(amp: String, steps: [Step], seconds: Double)] = []
        for amp in amps {
            guard let steps = ampLoad[amp.key] else { continue }
            if let i = found.firstIndex(where: { $0.steps == steps }) { found[i].seconds += amp.seconds } else { found.append((amp.key, steps, amp.seconds)) }
        }
        return found.reduce(nil) { (best: (amp: String, steps: [Step], seconds: Double)?, a) in
            best.map { a.seconds > $0.seconds ? a : $0 } ?? a
        }?.amp
    }

    /// The sequence of the song's amp (songAmp), else the style's.
    func songLoadSteps(style: String, amps: [(key: String, seconds: Double)] = []) -> [Step] {
        songAmp(amps).flatMap { ampLoad[$0] } ?? songLoad[style] ?? songLoad["*"] ?? []
    }

    /// The knobs for a song played through `amp`'s sequence: its own on a CC in place of the shared ones.
    func knobs(amp: String?) -> [Knob] {
        guard let own = amp.flatMap({ ampKnobs[$0] }), !own.isEmpty else { return knobs }
        return knobs.filter { k in !own.contains { $0.cc == k.cc } } + own
    }

    /// What plays a tone: the first steps set the sound, then the knobs, then the effect CCs, all
    /// of them on or off, since a device's snapshot may have just reset them, and last so an effect
    /// comes on already set. Kinds sharing a CC count as one. `toneIndex` is the tone's place among
    /// the song's tones, if it's one of them. A category's steps for the band of the tone's drive
    /// ("Lead clean") win over its plain ones. A tone with no delay of its own gets its category's
    /// addDelay, timed by `tempo` (beats per minute). `amp` is the song's amp (songAmp), for ampKnobs.
    func toneSteps(category c: Category, toneIndex: Int?, effectKinds: Set<String>,
                   knobValues: [String: Double] = [:], tempo: Double? = nil, amp: String? = nil) -> [Step] {
        var steps = categorySteps(c, drive: knobValues["drive"])
        if let first = toneFirstProgram, let toneIndex { steps = [.pc(first + toneIndex)] }
        var on = effectKinds, knobValues = knobValues
        let band = Rig.band(knobValues["drive"]).map { c.name + " " + $0 }
        if let added = band.flatMap({ addDelay[$0] }) ?? addDelay[c.name], !on.contains("delay") {
            on.insert("delay")
            knobValues["delay_time"] = added.beats * 60000 / (tempo.flatMap { $0 > 0 ? $0 : nil } ?? AddedDelay.tempoUnknown)
            knobValues["delay_mix"] = added.mix
            knobValues["delay_feedback"] = added.feedback
        }
        let active = Set(effects.filter { on.contains($0.key) }.values)
        let turned = knobs(amp: amp).compactMap { knob in knob.value(knobValues, kinds: on).map { Step.cc(knob.cc, $0) } }
        return steps + turned + Set(effects.values).sorted().map { .cc($0, active.contains($0) ? 127 : 0) }
    }

    var destinationLabel: String {
        switch destination {
        case .virtual: "virtual source, channel \(channel)"
        case .device(let name): "\(name), channel \(channel)"
        }
    }

    /// For Settings.
    var summary: String {
        switch destination {
        case .virtual: "Sent on channel \(channel) from the virtual MIDI source \"Rocksmith Companion\". "
            + "Choose it as the MIDI input of your amp, speaker or app if it doesn't listen to all sources."
        case .device(let name): "Sent on channel \(channel) straight to \"\(name)\"."
        }
    }

    /// Steps as one line: "CC 69 = 2, CC 20 = 127".
    static func label(_ steps: [Step]) -> String {
        steps.isEmpty ? "nothing" : steps.map(\.label).joined(separator: ", ")
    }

    // MARK: The file

    static func parse(_ data: Data, id: String) throws -> Profile {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Invalid(why: "not valid JSON")
        }
        let known = ["name", "comment", "destination", "channel", "song_load", "song_load_again", "category",
                     "tone_first_program", "effects", "amp_load", "knobs", "amp_knobs", "add_delay"]
        if let unknown = json.keys.sorted().first(where: { !known.contains($0) }) {
            throw Invalid(why: "unknown key \"\(unknown)\"")
        }
        var p = Profile(id: id)
        guard let name = json["name"] as? String, !name.isEmpty else { throw Invalid(why: "it needs a \"name\"") }
        p.name = name
        if let value = json["destination"] {
            guard let text = value as? String, !text.isEmpty else { throw Invalid(why: "\"destination\" is a name") }
            p.destination = text == "virtual" ? .virtual : .device(text)
        }
        if let value = json["channel"] { p.channel = try number(value, "channel", 1...16) }
        if let value = json["song_load"] {
            guard let styles = value as? [String: Any] else { throw Invalid(why: "\"song_load\" is an object of styles") }
            p.songLoad = try styles.mapValues { try steps($0) }
        }
        if let value = json["amp_load"] {
            guard let amps = value as? [String: Any] else { throw Invalid(why: "\"amp_load\" is an object of amps") }
            if let wrong = amps.keys.sorted().first(where: { !$0.contains("Amp_") }) {
                throw Invalid(why: "\"\(wrong)\" isn't an amp: they read like Amp_CA100")
            }
            p.ampLoad = try amps.mapValues { try steps($0) }
        }
        if let value = json["song_load_again"] {
            guard let again = value as? Bool else { throw Invalid(why: "\"song_load_again\" is true or false") }
            p.songLoadAgain = again
        }
        if let value = json["category"] {
            guard let categories = value as? [String: Any] else { throw Invalid(why: "\"category\" is an object") }
            for (name, list) in categories {
                let (c, band) = try categoryKey(name)
                if band != nil { p.categoryByBand[name] = try steps(list) } else { p.category[c.rawValue] = try steps(list) }
            }
        }
        if let value = json["tone_first_program"] {
            p.toneFirstProgram = try number(value, "tone_first_program", 0...(128 - SongTones.maxTones))
        }
        if let value = json["effects"] {
            guard let map = value as? [String: Any] else { throw Invalid(why: "\"effects\" is an object") }
            for (kind, cc) in map {
                guard effectKinds.contains(kind) else { throw Invalid(why: "unknown effect \"\(kind)\"") }
                p.effects[kind] = try number(cc, "effects \(kind)", 0...127)
            }
        }
        func knobList(_ value: Any, _ what: String) throws -> [Knob] {
            guard let list = value as? [Any] else { throw Invalid(why: "\"\(what)\" is a list") }
            let knobs = try list.map(knob)
            let ccs = knobs.map(\.cc)
            if let twice = ccs.first(where: { cc in ccs.filter { $0 == cc }.count > 1 }) {
                throw Invalid(why: "two knobs on CC \(twice)")
            }
            if let shared = ccs.first(where: p.effects.values.contains) {
                throw Invalid(why: "CC \(shared) is both a knob and an effect")
            }
            return knobs
        }
        if let value = json["knobs"] { p.knobs = try knobList(value, "knobs") }
        if let value = json["amp_knobs"] {
            guard let amps = value as? [String: Any] else { throw Invalid(why: "\"amp_knobs\" is an object of amps") }
            for (amp, list) in amps {
                guard p.ampLoad[amp] != nil else { throw Invalid(why: "amp_knobs: \"\(amp)\" isn't in amp_load") }
                p.ampKnobs[amp] = try knobList(list, "amp_knobs \(amp)")
            }
        }
        if let value = json["add_delay"] {
            guard let categories = value as? [String: Any] else { throw Invalid(why: "\"add_delay\" is an object of categories") }
            guard p.effects["delay"] != nil else { throw Invalid(why: "\"add_delay\" needs a delay CC in \"effects\"") }
            for (name, spec) in categories {
                _ = try categoryKey(name)
                p.addDelay[name] = try addedDelay(spec)
            }
        }
        return p
    }

    /// "Lead" or "Lead clean": the category, and the band if given.
    private static func categoryKey(_ name: String) throws -> (Category, String?) {
        let parts = name.split(separator: " ").map(String.init)
        guard let c = Category.allCases.first(where: { $0.name == parts.first }), parts.count <= 2,
              parts.count == 1 || bands.contains(parts[1]) else {
            throw Invalid(why: "unknown category \"\(name)\": a category, or one and a band (clean, crunch, heavy)")
        }
        return (c, parts.count == 2 ? parts[1] : nil)
    }

    private static func addedDelay(_ spec: Any) throws -> AddedDelay {
        guard let d = spec as? [String: Any] else { throw Invalid(why: "an added delay is an object") }
        if let unknown = d.keys.sorted().first(where: { !["beats", "mix", "feedback"].contains($0) }) {
            throw Invalid(why: "unknown add_delay key \"\(unknown)\"")
        }
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double {
            guard let n = d[key] as? NSNumber, range.contains(n.doubleValue) else {
                throw Invalid(why: "add_delay \(key) must be \(range.lowerBound.formatted())–\(range.upperBound.formatted())")
            }
            return n.doubleValue
        }
        return AddedDelay(beats: try number("beats", 0.0625...4), mix: try number("mix", 0...100),
                          feedback: try number("feedback", 0...100))
    }

    private static func knob(_ value: Any) throws -> Knob {
        guard let d = value as? [String: Any] else { throw Invalid(why: "a knob is an object") }
        if let unknown = d.keys.sorted().first(where: { !["cc", "from", "sum", "range", "with", "default"].contains($0) }) {
            throw Invalid(why: "unknown knob key \"\(unknown)\"")
        }
        let cc = try number(d["cc"], "knob cc", 0...127)
        func pair(_ value: Any, _ what: String) throws -> [Double] {
            guard let pair = (value as? [NSNumber])?.map(\.doubleValue), pair.count == 2, pair[0] != pair[1] else {
                throw Invalid(why: "\(what) is two different numbers")
            }
            return pair
        }
        var k = Knob(cc: cc, from: "", range: [0, 1], fallback: try d["default"].map { try number($0, "knob default", 0...127) })
        switch (d["from"], d["sum"]) {
        case (let from as String, nil):
            guard let range = knobSources[from] else {
                throw Invalid(why: "a knob's \"from\" is one of \(knobSources.keys.sorted().joined(separator: ", "))")
            }
            (k.from, k.range) = (from, range)
        case (nil, let sum?):
            guard let list = sum as? [Any], !list.isEmpty else { throw Invalid(why: "a knob's \"sum\" is a list of terms") }
            k.terms = try list.map(term)
            guard d["range"] != nil else { throw Invalid(why: "a knob with a \"sum\" needs a \"range\"") }
        default:
            throw Invalid(why: "a knob has a \"from\" or a \"sum\"")
        }
        if let value = d["range"] { k.range = try pair(value, "a knob's \"range\"") }
        if let value = d["with"] {
            guard let map = value as? [String: Any] else { throw Invalid(why: "a knob's \"with\" is an object of effects") }
            for (kind, range) in map {
                guard effectKinds.contains(kind) else { throw Invalid(why: "unknown effect \"\(kind)\" in a knob's \"with\"") }
                k.rangeWith[kind] = try pair(range, "a knob's range with \(kind)")
            }
        }
        return k
    }

    /// {"add": -3}, or {"from": "gain", "points": [[0, 1.5], [100, -2]]}, maybe with "with": "overdrive".
    private static func term(_ value: Any) throws -> Knob.Term {
        guard let d = value as? [String: Any] else { throw Invalid(why: "a term is an object") }
        if let unknown = d.keys.sorted().first(where: { !["add", "from", "points", "with"].contains($0) }) {
            throw Invalid(why: "unknown term key \"\(unknown)\"")
        }
        var t = Knob.Term()
        if let add = d["add"] {
            guard let n = add as? NSNumber else { throw Invalid(why: "a term's \"add\" is a number") }
            t.add = n.doubleValue
        }
        if let from = d["from"] {
            guard let from = from as? String, knobSources[from] != nil else {
                throw Invalid(why: "a term's \"from\" is one of \(knobSources.keys.sorted().joined(separator: ", "))")
            }
            guard let points = (d["points"] as? [[NSNumber]])?.map({ $0.map(\.doubleValue) }), !points.isEmpty,
                  points.allSatisfy({ $0.count == 2 }), zip(points, points.dropFirst()).allSatisfy({ $0[0] < $1[0] }) else {
                throw Invalid(why: "a term's \"points\" are [value, result] pairs, by rising value")
            }
            (t.from, t.points) = (from, points)
        } else if d["points"] != nil || d["with"] != nil {
            throw Invalid(why: "a term with \"points\" needs a \"from\"")
        } else if d["add"] == nil {
            throw Invalid(why: "a term has an \"add\" or a \"from\"")
        }
        if let with = d["with"] {
            guard let kind = with as? String, effectKinds.contains(kind) else { throw Invalid(why: "a term's \"with\" is an effect") }
            t.with = kind
        }
        return t
    }

    private static func number(_ value: Any?, _ what: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let n = value as? Int, range.contains(n) else {
            throw Invalid(why: "\(what) must be \(range.lowerBound)–\(range.upperBound)")
        }
        return n
    }

    private static func steps(_ value: Any) throws -> [Step] {
        guard let list = value as? [Any] else { throw Invalid(why: "a sequence is a list of steps") }
        return try list.map(step)
    }

    private static func step(_ value: Any) throws -> Step {
        guard let d = value as? [String: Any] else { throw Invalid(why: "a step is an object") }
        if d.count == 1, let v = d["pc"] { return .pc(try number(v, "pc", 0...127)) }
        if d.count == 2, let n = d["cc"] {
            return .cc(try number(n, "cc", 0...127), try number(d["value"], "cc value", 0...127))
        }
        if d.count == 1, let v = d["wait_ms"] { return .wait(try number(v, "wait_ms", 0...5000)) }
        if d.count == 1, let v = d["bytes"] { return .bytes(try message(v)) }
        if d.count == 1, d["song_tones_message"] as? Bool == true { return .songTonesMessage }
        throw Invalid(why: "unknown step: \(d.keys.sorted().joined(separator: ", "))")
    }

    /// One MIDI message from hex: "F0 7E 7F 06 01 F7" or "B0 45 02".
    private static func message(_ value: Any) throws -> [UInt8] {
        guard let text = value as? String else { throw Invalid(why: "\"bytes\" is hex text") }
        let parts = text.split(separator: " ").map { UInt8($0, radix: 16) }
        let bytes = parts.compactMap { $0 }
        guard bytes.count == parts.count, let status = bytes.first else { throw Invalid(why: "bad bytes: \(text)") }
        let data = status == 0xF0 ? bytes.dropFirst().dropLast() : bytes.dropFirst()
        let length: Int? = switch status {
        case 0xF0: bytes.last == 0xF7 ? bytes.count : nil
        case 0xC0...0xDF: 2
        case 0x80...0xEF: 3
        default: nil
        }
        guard bytes.count == length, data.allSatisfy({ $0 < 0x80 }) else {
            throw Invalid(why: "bytes aren't one MIDI message: \(text)")
        }
        return bytes
    }

    /// The file's JSON.
    var json: Data {
        func encode(_ steps: [Step]) -> [[String: Any]] {
            steps.map {
                switch $0 {
                case .pc(let p): ["pc": p]
                case .cc(let n, let v): ["cc": n, "value": v]
                case .wait(let ms): ["wait_ms": ms]
                case .bytes: ["bytes": $0.label]
                case .songTonesMessage: ["song_tones_message": true]
                }
            }
        }
        var out: [String: Any] = ["name": name, "channel": channel, "song_load_again": songLoadAgain]
        switch destination {
        case .virtual: out["destination"] = "virtual"
        case .device(let name): out["destination"] = name
        }
        out["song_load"] = songLoad.mapValues(encode)
        out["amp_load"] = ampLoad.mapValues(encode)
        var categories = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.name, encode(category[$0.rawValue])) })
        for (name, steps) in categoryByBand { categories[name] = encode(steps) }
        out["category"] = categories
        if let toneFirstProgram { out["tone_first_program"] = toneFirstProgram }
        out["effects"] = effects
        func encode(_ knob: Knob) -> [String: Any] {
            var k: [String: Any] = ["cc": knob.cc, "range": knob.range]
            if knob.terms.isEmpty { k["from"] = knob.from } else {
                k["sum"] = knob.terms.map { t -> [String: Any] in
                    var o: [String: Any] = [:]
                    if t.add != 0 || t.from == nil { o["add"] = t.add }
                    if let from = t.from { (o["from"], o["points"]) = (from, t.points) }
                    o["with"] = t.with
                    return o
                }
            }
            k["default"] = knob.fallback
            if !knob.rangeWith.isEmpty { k["with"] = knob.rangeWith }
            return k
        }
        out["knobs"] = knobs.map(encode)
        if !ampKnobs.isEmpty { out["amp_knobs"] = ampKnobs.mapValues { $0.map(encode) } }
        if !addDelay.isEmpty {
            out["add_delay"] = addDelay.mapValues { d in ["beats": d.beats, "mix": d.mix, "feedback": d.feedback] }
        }
        return (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// The same output, whatever the profile is called.
    func sendsTheSame(as other: Profile) -> Bool {
        var a = self, b = other
        (a.id, a.name, b.id, b.name) = ("", "", "", "")
        return a == b
    }

    /// The profile for the MIDI settings of rscompanion.json from before there were profiles.
    static func legacy(json: [String: Any]) -> Profile {
        var p = plain
        p.id = "migrated"
        p.name = "My MIDI settings"
        if let v = json["midi_channel"] as? Int { p.channel = min(max(v, 1), 16) }
        if let programs = json["programs"] as? [String: Any] {
            for c in Category.allCases {
                if let v = programs[c.name] as? Int { p.category[c.rawValue] = [.pc(min(max(v, 0), 127))] }
            }
        }
        if json["song_tones"] as? Bool == true {
            p.songLoad = ["*": [.songTonesMessage]]
            p.songLoadAgain = true
            if json["song_tone_programs"] as? Bool ?? true {
                let first = json["song_tone_first_program"] as? Int ?? SongTones.defaultFirstProgram
                p.toneFirstProgram = min(max(first, 0), 128 - SongTones.maxTones)
            }
        }
        return p
    }
}

/// The profiles in DATA_DIR/profiles. The ones that come with the app are copied there if
/// missing, so they can be edited, and a new file shows up as a new profile.
final class Profiles {
    let dir: String
    private(set) var all: [Profile] = []
    private(set) var errors: [String: String] = [:]     // id -> why its file can't be used
    private var signature: [String] = []

    init(dir: String, bundled: URL?) {
        self.dir = dir
        let files = FileManager.default
        try? files.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in bundled.flatMap({ try? files.contentsOfDirectory(atPath: $0.path) }) ?? [] where name.hasSuffix(".json") {
            let target = dir + "/" + name
            if !files.fileExists(atPath: target), let bundled { try? files.copyItem(atPath: bundled.path + "/" + name, toPath: target) }
        }
        reload()
    }

    /// Reads the folder again if a file changed. Returns true if one did.
    @discardableResult
    func reload() -> Bool {
        let files = FileManager.default
        let names = ((try? files.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        let now = names.map { name -> String in
            let date = (try? files.attributesOfItem(atPath: dir + "/" + name))?[.modificationDate] as? Date
            return "\(name) \(date?.timeIntervalSince1970 ?? 0)"
        }
        guard now != signature else { return false }
        signature = now
        all = []
        errors = [:]
        for name in names {
            let id = String(name.dropLast(".json".count))
            do {
                guard let data = files.contents(atPath: dir + "/" + name) else { throw Profile.Invalid(why: "can't be read") }
                all.append(try Profile.parse(data, id: id))
            } catch {
                errors[id] = (error as? Profile.Invalid)?.why ?? "can't be read"
            }
        }
        all.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return true
    }

    func profile(_ id: String) -> Profile? { all.first { $0.id == id } }

    /// The profile for settings from before there were profiles: one that sends the same, or
    /// a new file with those settings.
    func migrate(legacy: Profile) -> String {
        if let same = all.first(where: { $0.sendsTheSame(as: legacy) }) { return same.id }
        try? legacy.json.write(to: URL(fileURLWithPath: dir + "/" + legacy.id + ".json"), options: .atomic)
        reload()
        return legacy.id
    }
}
