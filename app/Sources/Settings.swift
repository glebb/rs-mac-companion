import Foundation

/// Settings in DATA_DIR/rscompanion.json, shared with the in-game dylib (which reads lead_ms and
/// overlay_enabled and picks up changes within a second). Keys this app does not know are kept.
///   {"lead_ms": 100, "midi_channel": 1, "programs": {"Clean": 0, "Crunch": 1, "Heavy": 2, "Lead": 3},
///    "game_dir": "/path/to/Rocksmith2014",     (only when not where Steam has it)
///    "overlay_enabled": false, "overlay_port": 9938,
///    "song_tones": false,                      (a SysEx describing each song's tones, SongTones.swift)
///    "song_tone_programs": true, "song_tone_first_program": 8,  (and Program Changes that play them)
///    "ai_classify": false, "ai_model": "gpt-6-luna"}            (ask an AI model about new songs, AIClassifier.swift;
///                                                                the API key is in the keychain)
struct Settings: Equatable {
    var gameDir: String?            // the Rocksmith2014 folder, if not where Steam has it
    var leadMs = 100
    var channel = 1                 // 1-16
    var programs = [0, 1, 2, 3]     // Program Change per category (Clean, Crunch, Heavy, Lead)
    var overlayEnabled = false      // RockSniffer-compatible stream overlays (OverlayServer)
    var overlayPort = 9938          // RockSniffer's default
    var songTones = false           // a SysEx describes each song's tones when it loads (SongTones.swift)
    var songTonePrograms = true     // with it, song tone i plays on Program Change songToneFirstProgram + i
    var songToneFirstProgram = SongTones.defaultFirstProgram
    var aiClassify = false          // ask an AI model about each new song (AIClassifier.swift)
    var aiModel = AIClassifier.defaultModel

    /// Common layouts: the four categories on Program Change 0-3 or 4-7 (e.g. two guitar
    /// channels of one device), or a number per category.
    enum Target: String, CaseIterable, Identifiable {
        case first = "Program Change 0–3"
        case second = "Program Change 4–7"
        case custom = "Custom"
        var id: String { rawValue }
        var programs: [Int]? {
            switch self {
            case .first: [0, 1, 2, 3]
            case .second: [4, 5, 6, 7]
            case .custom: nil
            }
        }
    }

    /// Picking 0-3 or 4-7 sets the programs; Custom keeps them to edit.
    var target: Target {
        get { Target.allCases.first { $0.programs == programs } ?? .custom }
        set {
            if let p = newValue.programs { programs = p }
            else if newValue == .custom, target != .custom { programs = programs.map { $0 + 16 } }  // clear of the presets (0-7) and the default song tones (8-12)
        }
    }

    func program(for category: Category) -> Int { programs[category.rawValue] }

    static func load(from path: String) -> Settings {
        var s = Settings()
        guard let raw = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return s }
        if let v = json["game_dir"] as? String, !v.isEmpty { s.gameDir = v }
        if let v = json["lead_ms"] as? Int { s.leadMs = min(max(v, 0), 2000) }
        if let v = json["midi_channel"] as? Int { s.channel = min(max(v, 1), 16) }
        if let v = json["overlay_enabled"] as? Bool { s.overlayEnabled = v }
        if let v = json["overlay_port"] as? Int, (1024...65535).contains(v) { s.overlayPort = v }
        if let v = json["song_tones"] as? Bool { s.songTones = v }
        if let v = json["song_tone_programs"] as? Bool { s.songTonePrograms = v }
        if let v = json["song_tone_first_program"] as? Int { s.songToneFirstProgram = min(max(v, 0), 128 - SongTones.maxTones) }
        if let v = json["ai_classify"] as? Bool { s.aiClassify = v }
        if let v = json["ai_model"] as? String, !v.isEmpty { s.aiModel = v }
        if let p = json["programs"] as? [String: Any] {
            for c in Category.allCases { if let v = p[c.name] as? Int { s.programs[c.rawValue] = min(max(v, 0), 127) } }
        }
        return s
    }

    func save(to path: String) {
        var json = (FileManager.default.contents(atPath: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["game_dir"] = gameDir
        json["lead_ms"] = leadMs
        json["midi_channel"] = channel
        json["overlay_enabled"] = overlayEnabled
        json["overlay_port"] = overlayPort
        json["song_tones"] = songTones
        json["song_tone_programs"] = songTonePrograms
        json["song_tone_first_program"] = songToneFirstProgram
        json["ai_classify"] = aiClassify
        json["ai_model"] = aiModel
        json["programs"] = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.name, programs[$0.rawValue]) })
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
