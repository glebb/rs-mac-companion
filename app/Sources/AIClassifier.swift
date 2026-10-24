import Foundation
import Security

/// Asks an OpenAI model what a song is, as classify_songs.py does for a whole library (same
/// prompt, line format and answer schema, so the two share DATA_DIR/ai_classified.json): its
/// style, and whether its distorted tones sound like crunch or heavy on the record. Presets reads
/// the answers (Presets.answer). Sends the artist, title and what the rules measured.
enum AIClassifier {
    static let defaultModel = "gpt-6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// What the model is told about a song (classify_songs.py songs_from_index).
    struct Song {
        let songKey: String
        let artist: String
        let title: String
        let tuning: String?
        let tempo: Double?
        let heaviness: Double?
        let ruleStyle: String
        let ruleCategories: [String: Int]   // category name -> tones the rules give it
        let amps: [String]
    }

    // Keep in step with SYSTEM in classify_songs.py.
    static let system = """
        You classify songs for a guitar practice tool that switches the player's amp presets \
        while they play Rocksmith. For each song you get its artist, title and what the tool's rules \
        measured from the Rocksmith tones. The rules only see amp gain knobs, and Rocksmith tone designers \
        often turn the gain up past what the record sounds like, so judge from how the original recording \
        sounds, using the measurements as a hint.

        For each song answer:
        - style: the one of the given styles that fits the recording best.
        - distortion: how the song's distorted guitar parts sound on the record. "crunch" is edge-of- \
        breakup to classic rock overdrive (AC/DC, Bon Jovi, Led Zeppelin, most 60s-80s rock); "heavy" is \
        high-gain distortion (metal, hard rock with saturated rhythm tones, grunge with fuzz). Use "none" \
        only when the song has no distorted guitar at all.
        - confidence: "high" when you know the recording, "medium" when you know the artist's sound but \
        not this song, "low" when you are guessing from the measurements.
        - reason: at most 12 words.

        Answer for every song key you are given, using the key exactly as written.
        """

    /// The song's line in the prompt (classify_songs.py describe).
    static func describe(_ s: Song) -> String {
        let h = s.heaviness.map { String(format: "%.2f", $0) } ?? "?"
        let tempo = s.tempo.map { String(format: "%g bpm", $0) } ?? "tempo ?"
        let cats = s.ruleCategories.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return "\(s.songKey) | \(s.artist) - \(s.title) | \(s.tuning ?? "tuning ?"), \(tempo) | "
            + "heaviness \(h), rules say \(s.ruleStyle) | tones: \(cats.isEmpty ? "no guitar tones" : cats) | "
            + "amps: \(s.amps.isEmpty ? "?" : s.amps.joined(separator: ", "))"
    }

    static func prompt(_ s: Song, styles: [String]) -> String {
        "Styles: \(styles.joined(separator: ", "))\n\nSongs (key | artist - title | tuning, tempo | "
            + "rules' heaviness 0-1 and style | categories the rules give its tones | main amps):\n" + describe(s)
    }

    static func schema(styles: [String]) -> [String: Any] {
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "song_key": ["type": "string"],
                "style": ["type": "string", "enum": styles],
                "distortion": ["type": "string", "enum": ["crunch", "heavy", "none"]],
                "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                "reason": ["type": "string"],
            ],
            "required": ["song_key", "style", "distortion", "confidence", "reason"],
            "additionalProperties": false,
        ]
        return ["type": "object", "properties": ["songs": ["type": "array", "items": item]],
                "required": ["songs"], "additionalProperties": false]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The model's answer for the song, as stored in ai_classified.json (with "model").
    static func classify(_ s: Song, styles: [String], model: String, key: String,
                         endpoint: URL = endpoint) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": system, "input": prompt(s, styles: styles),
            "reasoning": ["effort": "low"],
            "text": ["format": ["type": "json_schema", "name": "songs", "strict": true, "schema": schema(styles: styles)]],
        ] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw Failure(description: message ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard json["status"] as? String == "completed" else {
            throw Failure(description: "no answer (\(json["status"] as? String ?? "?"))")
        }
        // The text of the first output_text in the output messages.
        let text = ((json["output"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .first { $0["type"] as? String == "output_text" }?["text"] as? String
        guard let text, let songs = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["songs"]
                as? [[String: Any]],
              var answer = songs.first(where: { ($0["song_key"] as? String)?.lowercased() == s.songKey.lowercased() })
        else { throw Failure(description: "the answer didn't name the song") }
        answer["model"] = model
        return answer
    }

    /// Adds (or replaces) a song's answer in ai_classified.json, keeping the others.
    static func save(_ answer: [String: Any], songKey: String, to path: String) {
        var all = FileManager.default.contents(atPath: path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        all[songKey.lowercased()] = answer
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// The OpenAI API key, kept in the login keychain rather than in rscompanion.json (which the
/// in-game library reads too).
enum APIKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.rs-mac-companion.openai",
        kSecAttrAccount as String: "api-key",
    ]

    static func get() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key, or with nil or "" removes it.
    static func set(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
