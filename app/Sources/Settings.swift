import Foundation

/// Settings in DATA_DIR/rscompanion.json, shared with the in-game dylib (which reads lead_ms and
/// overlay_enabled and picks up changes within a second). Keys this app does not know are kept.
///   {"lead_ms": 100, "profile": "program-changes",  (what's sent over MIDI: profiles/<name>.json, Profile.swift)
///    "game_dir": "/path/to/Rocksmith2014",     (only when not where Steam has it)
///    "overlay_enabled": false, "overlay_port": 9938,
///    "ai_classify": false, "ai_model": "gpt-6-luna"}            (ask an AI model about new songs, AIClassifier.swift;
///                                                                the API key is in the keychain)
/// Without "profile", the MIDI settings from before profiles (midi_channel, programs, song_tones,
/// song_tone_programs, song_tone_first_program) become one: Profile.legacy.
struct Settings: Equatable {
    var gameDir: String?            // the Rocksmith2014 folder, if not where Steam has it
    var leadMs = 100
    var profile: String?            // the device profile; nil: not chosen yet, see Companion.init
    var overlayEnabled = false      // RockSniffer-compatible stream overlays (OverlayServer)
    var overlayPort = 9938          // RockSniffer's default
    var aiClassify = false          // ask an AI model about each new song (AIClassifier.swift)
    var aiModel = AIClassifier.defaultModel

    static func load(from path: String) -> Settings {
        var s = Settings()
        guard let raw = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return s }
        if let v = json["game_dir"] as? String, !v.isEmpty { s.gameDir = v }
        if let v = json["lead_ms"] as? Int { s.leadMs = min(max(v, 0), 2000) }
        if let v = json["profile"] as? String, !v.isEmpty { s.profile = v }
        if let v = json["overlay_enabled"] as? Bool { s.overlayEnabled = v }
        if let v = json["overlay_port"] as? Int, (1024...65535).contains(v) { s.overlayPort = v }
        if let v = json["ai_classify"] as? Bool { s.aiClassify = v }
        if let v = json["ai_model"] as? String, !v.isEmpty { s.aiModel = v }
        return s
    }

    func save(to path: String) {
        var json = (FileManager.default.contents(atPath: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["game_dir"] = gameDir
        json["lead_ms"] = leadMs
        json["profile"] = profile
        json["overlay_enabled"] = overlayEnabled
        json["overlay_port"] = overlayPort
        json["ai_classify"] = aiClassify
        json["ai_model"] = aiModel
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
