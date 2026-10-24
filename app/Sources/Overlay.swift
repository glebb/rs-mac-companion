import Foundation

/// RockSniffer-compatible stream overlays: keeps what RockSniffer's addon API reports (its
/// "currentState", "memoryReadout" and "songDetails", field names and enums as RockSniffer
/// serializes them), fed by the dylib's events; serves it with OverlayServer and writes
/// RockSniffer's default OBS text files and album_cover.jpeg to DATA_DIR/output.
@MainActor
final class Overlay {
    /// RockSniffer's SnifferState.
    enum State: Int { case none = 0, inMenus, songSelected, songStarting, songPlaying, songEnding }

    private(set) var server: OverlayServer?
    private(set) var problem: String?
    let outputDir: String
    let addonsDir: String?
    private let storageDir: String
    private let record: (String) -> Void

    // From the events
    private var connectedAt: Date?
    private var archive = ""
    private var arrangement = ""            // e.g. "selftrap_bass"
    private var songKey = ""
    private var heartbeatTime: Double?
    private var stats: GameEvent.Stats?
    private var lastStats: GameEvent.Stats? // kept after the song: addons read its noteData at the song's end
    private var statsSince: Date?           // when the current stats object appeared
    private var statsAt: Date?              // last stats event
    private var timerMovedAt: Date?
    private var lastTimer: Double?
    private var ended = false               // the song was left; menus until the next song
    private var lastMode = 0                // the mode of the last song played (for its review)
    private var songAt: Date?               // last song event
    private var leftAt: Date?               // when the last song's stats went

    // Song details (read in the background, cached per archive and song)
    private var detailsKey = ""
    private var loadedKey = ""                   // detailsKey once its details are in (or unreadable)
    private var detailsJSON = Data("null".utf8)  // as RockSniffer before its first song (addons check for it)
    private var details: [String: Any]?
    private var ids: [String: String] = [:]
    private var cache: [String: (details: [String: Any], ids: [String: String])] = [:]

    private(set) var state = State.none
    private var endingSince: Date?
    private var timer: Timer?
    private var written: [String: String] = [:]

    init(dataDir: String, record: @escaping (String) -> Void) {
        outputDir = dataDir + "/output"
        storageDir = dataDir + "/addon_storage"
        addonsDir = Bundle.main.resourceURL.map { $0.appendingPathComponent("addons").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        self.record = record
    }

    var running: Bool { server != nil }

    /// Starts or stops serving on the port (and the text files with it).
    func configure(enabled: Bool, port: Int) {
        if !enabled || server?.port != port {
            if let s = server {
                s.stop()
                server = nil
                timer?.invalidate()
                timer = nil
                record("overlays: stopped serving on port \(s.port)")
            }
        }
        guard enabled, server == nil else { return }
        let s = OverlayServer(port: port, addonsDir: addonsDir, storageDir: storageDir) { [weak self] in
            self?.response() ?? Data()
        }
        if let error = s.start() {
            problem = "Overlays: port \(port) unavailable (\(error))."
            record("overlays: \(problem!)")
            return
        }
        problem = nil
        server = s
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        written = [:]
        writeAlbumCover()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        record("overlays: serving http://127.0.0.1:\(port)/ (addons: \(addonsDir ?? "none")), text files in \(outputDir)")
    }

    // MARK: Events

    func handle(_ e: GameEvent) {
        switch e.event {
        case "song", "state":
            if e.event == "state" {
                connectedAt = Date()
                heartbeatTime = e.time
            }
            guard let arr = e.arrangement, let path = e.archive, !path.isEmpty else { return }
            if e.event == "song" { songAt = Date() }
            if e.event == "song" || arr != arrangement { ended = false }
            arrangement = arr
            songKey = e.song_key ?? ""
            if path != archive || detailsKey != Self.key(path, arr) {
                archive = path
                loadDetails()
            }
        case "stats":
            if e.live == false {
                if stats != nil { leftAt = Date() }
                stats = nil
                statsAt = nil
                return
            }
            if stats == nil { statsSince = Date(); ended = false }
            stats = e.stats
            lastStats = e.stats
            statsAt = Date()
            lastMode = mode
            if let t = e.time {
                if t != lastTimer { timerMovedAt = Date() }
                lastTimer = t
            }
        default:
            break
        }
    }

    private static func key(_ archive: String, _ arrangement: String) -> String {
        let prefix = arrangement.lastIndex(of: "_").map { String(arrangement[..<$0]) } ?? arrangement
        return archive + "|" + prefix.lowercased()
    }

    private func loadDetails() {
        let key = Self.key(archive, arrangement)
        detailsKey = key
        if let hit = cache[key] { return setDetails(hit, key) }
        let (path, prefix) = (archive, String(key.split(separator: "|").last ?? ""))
        Task.detached(priority: .utility) {
            let t0 = Date()
            let read = SongDetails.read(archive: path, prefix: prefix)
            await MainActor.run {
                guard let read else {
                    if self.detailsKey == key { self.loadedKey = key }
                    return self.record("overlays: could not read \(path)")
                }
                self.cache[key] = read
                self.record(String(format: "overlays: read %@ from %@ in %.0f ms", prefix, (path as NSString).lastPathComponent,
                                   Date().timeIntervalSince(t0) * 1000))
                if self.detailsKey == key { self.setDetails(read, key) }
            }
        }
    }

    private func setDetails(_ read: (details: [String: Any], ids: [String: String]), _ key: String) {
        loadedKey = key
        details = read.details
        ids = read.ids
        detailsJSON = (try? JSONSerialization.data(withJSONObject: read.details)) ?? detailsJSON
        writeAlbumCover()
    }

    // MARK: State

    private var connected: Bool { connectedAt.map { Date().timeIntervalSince($0) < 3 } ?? false }
    private var songLength: Double { (details?["songLength"] as? NSNumber)?.doubleValue ?? 0 }
    private var mode: Int { stats.map { $0.mode == "sa" ? 2 : 1 } ?? 0 }  // RockSniffer's RSMode


    /// RockSniffer's states from what the dylib sees: a song is played while its note-stats
    /// object exists; it ends when the timer stops at the song's end or the object goes. The
    /// stats object can appear before the song event names the song (the arrangement is found
    /// after it), so a new song stays "selected" until its song event and details are in (or
    /// 2 s have passed): addons start a song with the details they see on "starting".
    private func tick() {
        let now = Date()
        if let at = statsAt, now.timeIntervalSince(at) > 2 { stats = nil; statsAt = nil; leftAt = now }
        let previous = state
        var next: State
        if !connected {
            next = .none
        } else if stats != nil {
            let stopped = timerMovedAt.map { now.timeIntervalSince($0) > 1.5 } ?? false
            let since = statsSince ?? now
            let named = songAt.map { at in leftAt.map { at > $0 } ?? true } ?? false
            if (!named || detailsKey != loadedKey) && now.timeIntervalSince(since) < 2 { next = .songSelected }
            else if previous == .songSelected || now.timeIntervalSince(since) < 1 { next = .songStarting }
            else if stopped && songLength > 0 && (lastTimer ?? 0) >= songLength - 1 { next = .songEnding }
            else { next = .songPlaying }
        } else if previous == .songPlaying || previous == .songStarting || (previous == .songEnding && !ended) {
            next = .songEnding  // left the song: a moment of "ending", then the menus
            ended = true
            endingSince = now
        } else if previous == .songEnding, let since = endingSince, now.timeIntervalSince(since) < 2 {
            next = .songEnding
        } else {
            next = arrangement.isEmpty || ended ? .inMenus : .songSelected
        }
        if next == .songEnding && previous != .songEnding { endingSince = now }
        state = next
        if next != previous { record("overlays: state \(previous) → \(next)") }
        writeText()
    }

    private var songTimer: Double { lastTimer.flatMap { stats != nil ? $0 : nil } ?? heartbeatTime ?? 0 }

    /// RockSniffer's noteData (LearnASongNoteData or ScoreAttackNoteData), or nil before the
    /// first song. After a song it stays the song's last, as RockSniffer's.
    private func noteData() -> [String: Any]? {
        guard let s = stats ?? lastStats else { return nil }
        let total = s.hits + s.misses
        let accuracy = total == 0 ? 100.0 : s.hits == 0 ? 0 : Double(s.hits) / Double(total) * 100
        var d: [String: Any] = [
            "Accuracy": accuracy, "TotalNotes": total, "TotalNotesHit": s.hits, "CurrentHitStreak": s.streak,
            "HighestHitStreak": s.best_streak, "TotalNotesMissed": s.misses, "CurrentMissStreak": s.miss_streak,
        ]
        guard s.mode == "sa" else { return d }
        let p = s.phrases ?? [0, 0, 0, 0], c = s.phrase_streaks ?? [0, 0, 0, 0], h = s.best_phrase_streaks ?? [0, 0, 0, 0]
        let kinds = ["Perfect", "Good", "Passed", "Failed"]
        d["HighestMissStreak"] = s.best_miss_streak ?? 0
        d["CurrentPerfectHitStreak"] = s.perfect_streak ?? 0
        d["TotalPerfectHits"] = s.perfect_hits ?? 0
        d["CurrentLateHitStreak"] = s.late_streak ?? 0
        d["TotalLateHits"] = s.late_hits ?? 0
        for (i, k) in kinds.enumerated() where i < p.count && i < c.count && i < h.count {
            d["\(k)Phrases"] = p[i]
            d["Current\(k)PhraseStreak"] = c[i]
            d["Highest\(k)PhraseStreak"] = h[i]
        }
        d["CurrentScore"] = s.score ?? 0
        d["CurrentMultiplier"] = s.multiplier ?? 0
        d["HighestMultiplier"] = s.best_multiplier ?? 0
        return d
    }

    /// The body of GET / (RockSniffer's AddonServiceListener.JsonResponse).
    private func response() -> Data {
        let readout: [String: Any] = [
            "songTimer": songTimer,
            "songID": songKey,
            "arrangementID": ids[arrangement.lowercased()] ?? "",
            "gameStage": state == .songEnding ? (lastMode == 2 ? "sa_songreview" : "las_songreview") : "",
            "mode": mode,
            "noteData": noteData() ?? NSNull(),
        ]
        let head: [String: Any] = [
            "success": details != nil && connected,
            "currentState": state.rawValue,
            "memoryReadout": readout,
            "Version": "0.6.4",
        ]
        var out = (try? JSONSerialization.data(withJSONObject: head)) ?? Data("{}".utf8)
        out.removeLast()  // "}": the song details go in as they are cached
        out += Data(#","songDetails":"#.utf8) + detailsJSON + Data("}".utf8)
        return out
    }

    // MARK: Text files (RockSniffer's default outputs)

    private static let outputs = [
        ("song_details.txt", "%SONG_ARTIST% - %SONG_NAME%"),
        ("album_details.txt", "%SONG_ALBUM% (%ALBUM_YEAR%)"),
        ("song_timer.txt", "%SONG_TIMER%/%SONG_LENGTH%"),
        ("notes.txt", "%NOTES_HIT%/%TOTAL_NOTES%"),
        ("accuracy.txt", "%CURRENT_ACCURACY%"),
        ("streaks.txt", "%CURRENT_STREAK%/%HIGHEST_STREAK%"),
    ]

    /// mm:ss of the time rounded up, as RockSniffer's FormatTime.
    private static func time(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.up))
        return String(format: "%02d:%02d", t / 60 % 60, t % 60)
    }

    private func writeText() {
        let d = details ?? [:]
        func str(_ k: String) -> String { d[k].flatMap { $0 is NSNull ? nil : "\($0)" } ?? "" }
        let toolkit = d["toolkit"] as? [String: Any] ?? [:]
        func tk(_ k: String) -> String { toolkit[k].flatMap { $0 is NSNull ? nil : "\($0)" } ?? "" }
        let nd = noteData()
        func n(_ k: String) -> Int { nd?[k] as? Int ?? 0 }
        let accuracy = nd?["Accuracy"] as? Double ?? 100
        let songFields: [(String, String)] = [
            ("%SONG_ID%", str("songID")), ("%SONG_ARTIST%", str("artistName")), ("%SONG_NAME%", str("songName")),
            ("%SONG_ALBUM%", str("albumName")), ("%ALBUM_YEAR%", str("albumYear")),
            ("%SONG_LENGTH%", Self.time(songLength)), ("%TOOLKIT_VERSION%", tk("version")),
            ("%TOOLKIT_AUTHOR%", tk("author")), ("%TOOLKIT_PACKAGE_VERSION%", tk("package_version")),
            ("%TOOLKIT_COMMENT%", tk("comment")),
        ]
        let readoutFields: [(String, String)] = [
            ("%SONG_TIMER%", Self.time(songTimer)), ("%NOTES_HIT%", "\(n("TotalNotesHit"))"),
            ("%CURRENT_STREAK%", "\(n("CurrentHitStreak") - n("CurrentMissStreak"))"),
            ("%HIGHEST_STREAK%", "\(n("HighestHitStreak"))"), ("%NOTES_MISSED%", "\(n("TotalNotesMissed"))"),
            ("%TOTAL_NOTES%", "\(n("TotalNotes"))"), ("%CURRENT_ACCURACY%", String(format: "%.2f%%", accuracy)),
        ]
        for (file, format) in Self.outputs {
            var text = format
            for (k, v) in songFields { text = text.replacingOccurrences(of: k, with: v) }
            if text != format && details == nil { text = "" }  // song fields but no song: nothing
            for (k, v) in readoutFields { text = text.replacingOccurrences(of: k, with: v) }
            guard written[file] != text else { continue }
            written[file] = text
            try? text.write(toFile: outputDir + "/" + file, atomically: true, encoding: .utf8)
        }
    }

    private func writeAlbumCover() {
        guard running else { return }
        let path = outputDir + "/album_cover.jpeg"
        if let art = details?["albumArt"] as? String, let jpeg = Data(base64Encoded: art) {
            try? jpeg.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
