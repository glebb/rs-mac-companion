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

    struct Invalid: Error { let why: String }

    /// The file name without .json.
    var id = ""
    var name = ""
    var destination = Destination.virtual
    var channel = 1
    /// By style; "*" is any style without its own.
    var songLoad: [String: [Step]] = [:]
    /// Run the song's load sequence again when the song is described anew (its mapping or AI
    /// answer changed). Off, a device isn't switched while the song plays.
    var songLoadAgain = false
    /// Per category, by Category.rawValue.
    var category: [[Step]] = Category.allCases.map { _ in [] }
    /// Song tone i plays on this Program Change + i, instead of its category's steps.
    var toneFirstProgram: Int?
    /// Effect kind (see effectKinds) -> CC, 127 when the tone has it and 0 when not.
    var effects: [String: Int] = [:]

    static let defaultID = "program-changes"
    static let effectKinds = ["delay", "reverb", "chorus", "flanger", "phaser", "tremolo", "vibe"]

    /// Used when no profile can be read: nothing but the category Program Changes, from the
    /// virtual source.
    static let plain = Profile(id: defaultID, name: "Program Changes",
                               category: Category.allCases.map { [.pc($0.rawValue)] })

    /// Whether the song's gear has to be read from its archive.
    var needsSongData: Bool { !songLoad.isEmpty || toneFirstProgram != nil || !effects.isEmpty }

    func songLoadSteps(style: String) -> [Step] { songLoad[style] ?? songLoad["*"] ?? [] }

    /// What plays a tone: the first steps set the sound, and the effect CCs follow, all of them
    /// on or off, since a device's snapshot may have just reset them. Kinds sharing a CC count
    /// as one. `toneIndex` is the tone's place among the song's tones, if it's one of them.
    func toneSteps(category c: Category, toneIndex: Int?, effectKinds on: Set<String>) -> [Step] {
        var steps = category[c.rawValue]
        if let first = toneFirstProgram, let toneIndex { steps = [.pc(first + toneIndex)] }
        let active = Set(effects.filter { on.contains($0.key) }.values)
        return steps + Set(effects.values).sorted().map { .cc($0, active.contains($0) ? 127 : 0) }
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
                     "tone_first_program", "effects"]
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
        if let value = json["song_load_again"] {
            guard let again = value as? Bool else { throw Invalid(why: "\"song_load_again\" is true or false") }
            p.songLoadAgain = again
        }
        if let value = json["category"] {
            guard let categories = value as? [String: Any] else { throw Invalid(why: "\"category\" is an object") }
            for (name, list) in categories {
                guard let c = Category.allCases.first(where: { $0.name == name }) else {
                    throw Invalid(why: "unknown category \"\(name)\"")
                }
                p.category[c.rawValue] = try steps(list)
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
        return p
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
        out["category"] = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.name, encode(category[$0.rawValue])) })
        if let toneFirstProgram { out["tone_first_program"] = toneFirstProgram }
        out["effects"] = effects
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
