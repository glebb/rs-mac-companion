import Foundation

/// The tone -> preset mapping in DATA_DIR/presets.json, shared with rstone.py and
/// make_catalog.py and evaluated the same way as presets.py (first match wins):
///   1. songs: per arrangement and slot   2. tones: per tone key
///   3. rules: by tags ("all"/"any") or words in the tone key ("name")   4. default
/// The resulting preset name is then read as a category: a category name itself, or the
/// "categories" section (e.g. "Distortion": "Heavy"). Overrides made in the app write
/// category names into "songs" (for every part of the song that uses the tone). The file is
/// re-read when it changes.
final class Presets {
    struct Match {
        let preset: String
        let category: Category
        let reason: String      // "song override", "tone override", "tags ...", "name" or "default"
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

    /// With overrides false, only the rules and the default count: what the tone would be
    /// without anyone's changes.
    func match(arrangement: String, slot: String, key: String, descriptors: [String], overrides: Bool = true) -> Match {
        func result(_ preset: String, _ reason: String) -> Match {
            Match(preset: preset, category: category(of: preset), reason: reason)
        }
        if overrides, let song = (data["songs"] as? [String: Any])?[arrangement] as? [String: Any], let p = song[slot] as? String {
            return result(p, "song override")
        }
        let tones = (data["tones"] as? [String: Any]) ?? [:]
        if overrides, let p = tones.first(where: { $0.key.lowercased() == key.lowercased() })?.value as? String {
            return result(p, "tone override")
        }
        let tags = Set(descriptors.map { $0.uppercased() })
        let lower = key.lowercased()
        let words = Set(lower.split { !("a"..."z").contains($0) }.map(String.init))  // re.findall(r"[a-z]+")
        for case let rule as [String: Any] in (data["rules"] as? [Any]) ?? [] {
            guard let preset = rule["preset"] as? String else { continue }
            if let all = rule["all"] as? [String], !Set(all).isSubset(of: tags) { continue }
            if let any = rule["any"] as? [String], !tags.isDisjoint(with: any) {
                return result(preset, "tags " + tags.sorted().joined(separator: "+"))
            }
            if let names = rule["name"] as? [String],
               names.contains(where: { words.contains($0) || ($0.count >= 4 && lower.contains($0)) }) {
                return result(preset, "name")
            }
        }
        return result(data["default"] as? String ?? "Clean", "default")
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
