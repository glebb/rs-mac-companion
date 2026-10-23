import Foundation

/// The tone -> preset mapping in DATA_DIR/presets.json, shared with rstone.py and
/// make_catalog.py and evaluated the same way as presets.py (first match wins):
///   1. songs: per arrangement and slot   2. tones: per tone key
///   3. rules: by tags ("all"/"any"), words in the tone key ("name"), the tone's amp ("amp"), its
///      gain knob ("gain": at least) and how distorted its rig is ("drive": clean, crunch or heavy)
///   4. default
/// The result of 3 or 4 may then be changed by the song's artist ("artists": {"Bon Jovi":
/// {"Heavy": "Crunch"}}). The resulting preset name is read as a category: a category name
/// itself, or the "categories" section (e.g. "Distortion": "Heavy"). Overrides made in the app write
/// category names into "songs" (for every part of the song that uses the tone). The file is
/// re-read when it changes.
final class Presets {
    struct Match {
        let preset: String
        let category: Category
        let reason: String      // "song override", "tone override", "tags ...", "name" or "default"
                                // (then ", artist ..." if the artist section changed it)
    }

    let path: String
    private var data: [String: Any] = [:]
    private var modified: Date?

    /// Preset names used before categories existed, for files without a "categories" section.
    private static let builtinCategories: [String: Category] = [
        "distortion": .heavy, "acoustic": .clean, "bass": .clean, "bass drive": .crunch,
    ]

    init(path: String, defaults: URL?) {
        self.path = path
        if !FileManager.default.fileExists(atPath: path), let defaults {
            try? FileManager.default.copyItem(at: defaults, to: URL(fileURLWithPath: path))
        }
        reload()
    }

    /// Re-reads the file if it changed. Returns true if it did.
    @discardableResult
    func reload() -> Bool {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard date != modified else { return false }
        modified = date
        guard let raw = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return false }
        data = json
        return true
    }

    /// The tone to map: its key and tags, and if known its amp, gain knob (0-100) and drive (0-1,
    /// Rig.drive).
    struct Tone {
        let key: String
        let descriptors: [String]
        var amp: String? = nil
        var gain: Double? = nil
        var drive: Double? = nil
    }

    /// With overrides false, only the rules, the default and the artist section count: what the
    /// tone would be without changes made to this song.
    func match(arrangement: String, slot: String, tone: Tone, artist: String, overrides: Bool = true) -> Match {
        func result(_ preset: String, _ reason: String) -> Match {
            Match(preset: preset, category: category(of: preset), reason: reason)
        }
        let key = tone.key
        if overrides, let song = (data["songs"] as? [String: Any])?[arrangement] as? [String: Any], let p = song[slot] as? String {
            return result(p, "song override")
        }
        let tones = (data["tones"] as? [String: Any]) ?? [:]
        if overrides, let p = tones.first(where: { $0.key.lowercased() == key.lowercased() })?.value as? String {
            return result(p, "tone override")
        }
        let (preset, reason) = rule(tone)
        let name = artist.trimmingCharacters(in: .whitespaces)
        if let remap = (data["artists"] as? [String: Any])?
            .first(where: { $0.key.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() })?
            .value as? [String: Any] {
            let wanted = [preset.lowercased(), category(of: preset).name.lowercased()]
            for w in wanted {
                if let p = remap.first(where: { $0.key.lowercased() == w })?.value as? String {
                    return result(p, "\(reason), artist \(name)")
                }
            }
        }
        return result(preset, reason)
    }

    /// "Amp_HG500" and "HG500" both -> "hg500".
    private static func ampName(_ amp: String?) -> String {
        let a = (amp ?? "").lowercased()
        return a.hasPrefix("amp_") ? String(a.dropFirst(4)) : a
    }

    /// The rules and the default: (preset, reason).
    private func rule(_ tone: Tone) -> (String, String) {
        let tags = Set(tone.descriptors.map { $0.uppercased() })
        let lower = tone.key.lowercased()
        let words = Set(lower.split { !("a"..."z").contains($0) }.map(String.init))  // re.findall(r"[a-z]+")
        let amp = Self.ampName(tone.amp)
        for case let rule as [String: Any] in (data["rules"] as? [Any]) ?? [] {
            guard let preset = rule["preset"] as? String else { continue }
            if let all = rule["all"] as? [String], !Set(all).isSubset(of: tags) { continue }
            if let amps = rule["amp"] as? [String], !amps.map(Self.ampName).contains(amp) { continue }
            if let min = (rule["gain"] as? NSNumber)?.doubleValue {
                guard let gain = tone.gain, gain >= min else { continue }
            }
            if let bands = rule["drive"] as? [String] {
                guard let band = Rig.band(tone.drive), bands.contains(where: { $0.lowercased() == band }) else { continue }
            }
            var gear = ""
            if rule["amp"] != nil || rule["gain"] != nil {
                gear = ", amp \(amp.isEmpty ? "?" : amp) gain " + (tone.gain.map { String(format: "%g", $0) } ?? "?")
            }
            if rule["drive"] != nil, let d = tone.drive, let band = Rig.band(d) {
                gear += String(format: ", drive %.2f ", d) + band
            }
            let any = rule["any"] as? [String], names = rule["name"] as? [String]
            if let any, !tags.isDisjoint(with: any) {
                return (preset, "tags " + tags.sorted().joined(separator: "+") + gear)
            }
            if let names, names.contains(where: { words.contains($0) || ($0.count >= 4 && lower.contains($0)) }) {
                return (preset, "name" + gear)
            }
            if any == nil && names == nil {
                return (preset, "tags " + tags.sorted().joined(separator: "+") + gear)
            }
        }
        return (data["default"] as? String ?? "Clean", "default")
    }

    /// The style label of a song, for song tone messages: "song_styles" names one for a song key
    /// or an artist (song key first); otherwise the last of "styles" whose "from" the song's
    /// heaviness reaches. Without a "styles" section: Soft, Classic rock (0.4), Metal (0.75).
    /// (Read too: "banks"/"song_banks" and "rigs"/"song_rigs", what styles were called before.)
    func style(heaviness: Double?, artist: String, songKey: String) -> String {
        let named = songStyles.reduce(into: [String: String]()) {
            if let v = $1.value as? String { $0[$1.key.trimmingCharacters(in: .whitespaces).lowercased()] = v }
        }
        if let r = named[songKey.lowercased()] ?? named[artist.trimmingCharacters(in: .whitespaces).lowercased()] {
            return r
        }
        let h = heaviness ?? 0
        return styles.last { h >= $0.from }?.name ?? styles[0].name
    }

    /// Every style a song may get: "styles", then the ones only "song_styles" names.
    var styleNames: [String] {
        let named = songStyles.sorted { $0.key < $1.key }.compactMap { $0.value as? String }
        var names: [String] = []
        for name in styles.map(\.name) + named where !names.contains(where: { $0.lowercased() == name.lowercased() }) {
            names.append(name)
        }
        return names
    }

    private var songStyles: [String: Any] {
        (data["song_styles"] ?? data["song_banks"] ?? data["song_rigs"]) as? [String: Any] ?? [:]
    }

    /// "styles" by heaviness; Soft, Classic rock (0.4), Metal (0.75) without the section.
    private var styles: [(name: String, from: Double)] {
        let list = ((data["styles"] ?? data["banks"] ?? data["rigs"]) as? [[String: Any]] ?? []).compactMap { r -> (name: String, from: Double)? in
            guard let name = r["name"] as? String else { return nil }
            return (name, (r["from"] as? NSNumber)?.doubleValue ?? 0)
        }
        return list.isEmpty ? [("Soft", 0), ("Classic rock", 0.4), ("Metal", 0.75)] : list
    }

    func category(of preset: String) -> Category {
        if let c = Category.allCases.first(where: { $0.name.lowercased() == preset.lowercased() }) { return c }
        let mapped = ((data["categories"] as? [String: Any]) ?? [:])
            .first { $0.key.lowercased() == preset.lowercased() }?.value as? String
        if let mapped, let c = Category.allCases.first(where: { $0.name.lowercased() == mapped.lowercased() }) { return c }
        return Self.builtinCategories[preset.lowercased()] ?? .clean
    }

    /// Sets (or with nil removes) the override for these arrangement slots, in one save.
    /// Removing also drops a "tones" entry for the key (written by hand or by older versions),
    /// so the tone really goes back to automatic.
    func set(_ slots: [(arrangement: String, slot: String)], key: String, to category: Category?) {
        reload()
        var songs = (data["songs"] as? [String: Any]) ?? [:]
        for (arrangement, slot) in slots {
            var song = (songs[arrangement] as? [String: Any]) ?? [:]
            song[slot] = category?.name
            songs[arrangement] = song.isEmpty ? nil : song
        }
        data["songs"] = songs
        if category == nil, var tones = data["tones"] as? [String: Any] {
            for k in tones.keys where k.lowercased() == key.lowercased() { tones[k] = nil }
            data["tones"] = tones
        }
        save()
    }

    private func save() {
        guard let json = try? JSONSerialization.data(withJSONObject: data,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? json.write(to: URL(fileURLWithPath: path), options: .atomic)
        modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
