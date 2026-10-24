import Foundation

/// A tone slot of the current arrangement, as shown in the window.
struct ToneRow: Identifiable, Equatable {
    let slot: String
    let key: String
    let descriptors: [String]
    let category: Category
    let preset: String
    let reason: String      // why: "song override", "tone override", "tags ...", "name", "default"
    let automatic: Category // what it would be without overrides
    var overridden: Bool { reason.hasSuffix("override") }
    var id: String { slot }
}

/// What an AI model says about the current song, as the window shows it.
struct AIVerdict: Equatable {
    enum State: Equatable {
        case asking
        case answered(Presets.Answer)
        case guess                  // answered with low confidence: not used
        case failed(String)
        case rejected               // you rejected its answer for this song
    }
    let state: State
    var changes: [String] = []      // what it changes here: "dist: Heavy → Crunch", "style: Soft → Classic rock"
}

/// Receives the dylib's events, keeps the current song and tone, maps tones to categories with
/// presets.json, and sends a Program Change when the active tone's category changes. With
/// song tone messages on, it also describes the song's tones in a SysEx when a song loads
/// (SongTones.swift), for a tool that makes a sound per tone, and plays those instead.
@MainActor
final class Companion: ObservableObject {
    static let shared = Companion()

    @Published private(set) var song: String?
    @Published private(set) var artist = ""
    @Published private(set) var arrangement = ""
    @Published private(set) var tones: [ToneRow] = []
    @Published private(set) var activeSlot: String?
    @Published private(set) var activeCategory: Category?
    @Published private(set) var timerLocked = false
    @Published private(set) var leadMs = 100
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var lastMIDI: String?
    @Published private(set) var madeTones: SongTones?   // the song tones described for this song
    @Published private(set) var problem: String?
    @Published private(set) var presetsError: String?  // presets.json can't be read (Presets.error)
    @Published var paused = false
    @Published private(set) var settings: Settings
    @Published private(set) var installStatus: GameInstaller.Status = .notInstalled
    @Published private(set) var installMessage: String?
    @Published private(set) var gameRunning = false
    private var gameRunningSince: Date?
    @Published private(set) var game: String?           // the last heartbeat's "game"; nil: Rocksmith
    @Published private(set) var rnrRunning = false
    private var rnrRunningSince: Date?
    @Published private(set) var rnrMessage: String?
    private var installCheckKey: [Date?] = []

    let dataDir: String
    private let settingsPath: String
    private var settingsModified: Date?
    private var socket: EventSocket?
    private let midi = MIDIOut()
    private let presets: Presets
    private var sentProgram: Int?
    private var archive = ""
    private var songTonesKey = ""   // archive|arrangement the song tones were described for
    private var active: GameEvent.Tone?
    private var songTones: [GameEvent.Tone] = []
    private var songParts: [GameEvent.Part] = []
    private var toneDrives: [String: Double] = [:]  // tone key (lowercased) -> drive 0-1, from the song's files
    private var drivesKey = ""                      // archive|song the drives were read for
    private var rigArrangements: [Rig.Arrangement] = []  // the song's parts, from its files (readDrives)
    @Published private(set) var ai: AIVerdict?
    private var asking: Set<String> = []            // song keys the AI model is being asked about
    private var aiFailures: [String: String] = [:]  // song key -> why asking failed (asked again next launch)
    private let log: FileHandle?
    private(set) var overlay: Overlay!

    private init() {
        dataDir = ProcessInfo.processInfo.environment["RS_COMPANION_DATA"]
            ?? NSHomeDirectory() + "/Library/Application Support/rs-mac-companion"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let logPath = dataDir + "/rs-companion-app.log"
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        log = FileHandle(forWritingAtPath: logPath)
        _ = try? log?.seekToEnd()
        settingsPath = dataDir + "/rscompanion.json"
        settings = Settings.load(from: settingsPath)
        settingsModified = Self.modified(settingsPath)
        presets = Presets(path: dataDir + "/presets.json",
                          defaults: Bundle.main.url(forResource: "presets.default", withExtension: "json"))
        problem = midi.error
        let socket = EventSocket(path: dataDir + "/events.sock") { [weak self] in self?.handle($0) }
        if let error = socket.start() { problem = error }
        self.socket = socket
        record("started; listening on \(socket.path); mapping in \(presets.path)")
        if let done = presets.upgrade() { record(done) }
        checkPresets(reload: false)
        overlay = Overlay(dataDir: dataDir) { [weak self] in self?.record($0) }
        overlay.configure(enabled: settings.overlayEnabled, port: settings.overlayPort)
        checkGame()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkGame()
                self?.reloadSettingsIfEdited()
                self?.checkPresets()
            }
        }
    }

    // MARK: Installation in Rocksmith

    var installer: GameInstaller {
        GameInstaller(gameDir: settings.gameDir ?? GameInstaller.steamGameDir(),
                      bundledDylib: Bundle.main.url(forResource: "librscompanion", withExtension: "dylib"))
    }

    /// Whether the game (and RockNRoller) runs, and the game's install status (re-read only when
    /// the files change).
    func checkGame(force: Bool = false) {
        let rnr = !RockNRoller.running.isEmpty
        if rnr != rnrRunning { rnrRunningSince = rnr ? Date() : nil }
        rnrRunning = rnr
        let i = installer
        let running = i.gameRunning
        if running != gameRunning { gameRunningSince = running ? Date() : nil }
        gameRunning = running
        let key = [i.executable, i.installedDylib].map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
        guard force || key != installCheckKey else { return }
        installCheckKey = key
        let status = i.status()
        if status != installStatus { record("Rocksmith: \(status.summary) (\(i.gameDir))") }
        installStatus = status
    }

    /// What the button of an attention notice does.
    enum AttentionAction: Equatable {
        case installInGame(String)      // its label: Install or Update
        case openRockNRoller

        var label: String {
            switch self {
            case let .installInGame(label): label
            case .openRockNRoller: "Restart RockNRoller"
            }
        }
    }

    /// Something about the installation the user should know or do, for the main window.
    var attention: (text: String, action: AttentionAction?)? {
        if rnrRunning, let since = rnrRunningSince, Date().timeIntervalSince(since) > 5, !connected(to: RockNRoller.game) {
            return ("RockNRoller is running without the companion.", .openRockNRoller)
        }
        // Playing in RockNRoller: how Rocksmith is installed doesn't matter now.
        if connected(to: RockNRoller.game) { return nil }
        switch installStatus {
        case .gameNotFound: return ("Rocksmith not found. Set its folder in Settings.", nil)
        case .notInstalled:
            let replaced = FileManager.default.fileExists(atPath: installer.backup)
            return (replaced ? "Not installed in Rocksmith. Steam may have updated the game." : "Not installed in Rocksmith yet.",
                    .installInGame("Install"))
        case .updateAvailable: return ("An update for Rocksmith is ready.", .installInGame("Update"))
        case let .problem(text): return (text, nil)
        case .installed:
            if gameRunning, let since = gameRunningSince, Date().timeIntervalSince(since) > 20, !connected() {
                return ("Rocksmith is running without the companion. Restart Rocksmith.", nil)
            }
            return nil
        }
    }

    func perform(_ action: AttentionAction) {
        switch action {
        case .installInGame: installInGame()
        case .openRockNRoller: openRockNRoller()
        }
    }

    // MARK: RockNRoller

    /// Opens RockNRoller with the companion library (restarting it if it runs).
    func openRockNRoller() {
        rnrMessage = rnrRunning ? "Restarting RockNRoller…" : "Opening RockNRoller…"
        Task {
            do {
                try await RockNRoller.open(dataDir: dataDir)
                rnrMessage = nil
                record("opened RockNRoller with the companion library")
            } catch {
                rnrMessage = "\(error)"
                record("opening RockNRoller failed: \(error)")
            }
            checkGame()
        }
    }

    /// The app a song is picked in, for the window: the connected one, else the ones there are.
    var gameLabel: String {
        if connected() { return game == RockNRoller.game ? RockNRoller.name : "Rocksmith" }
        return RockNRoller.appURL != nil ? "Rocksmith or RockNRoller" : "Rocksmith"
    }

    func installInGame() {
        do {
            let done = try installer.install()
            installMessage = gameRunning ? "Done. Restart Rocksmith to use it." : "Installed. Start Rocksmith."
            record("installed in Rocksmith: \(done)")
        } catch {
            installMessage = "\(error)"
            record("install failed: \(error)")
        }
        checkGame(force: true)
    }

    func uninstallFromGame() {
        do {
            let done = try installer.uninstall()
            installMessage = "Removed from Rocksmith."
            record("removed from Rocksmith: \(done)")
        } catch {
            installMessage = "\(error)"
            record("uninstall failed: \(error)")
        }
        checkGame(force: true)
    }

    /// The folder picked in Settings isn't the game.
    func notGame(_ name: String) {
        installMessage = "\(name) isn't Rocksmith: choose the Rocksmith2014 folder or Rocksmith2014.app."
    }

    func setGameDir(_ dir: String?) {
        var s = settings
        s.gameDir = dir
        update(s)
        installMessage = nil
        checkGame(force: true)
    }

    func shutdown() {
        socket?.stop()
        record("quit")
    }

    /// The game (with the dylib) counts as connected while heartbeats keep coming.
    func connected(at now: Date = Date()) -> Bool {
        guard let beat = lastHeartbeat else { return false }
        return now.timeIntervalSince(beat) < 3
    }

    /// Connected to that game ("rocknroller"; nil: Rocksmith).
    func connected(to game: String?) -> Bool { connected() && self.game == game }

    func resend() {
        sentProgram = nil
        send(reason: "resend")
    }

    /// Saves new settings (shared with the dylib, which picks up lead_ms within a second) and
    /// resends the current tone if the MIDI output changed.
    func update(_ new: Settings) {
        guard new != settings else { return }
        // A new first program changes the message, so it is sent again.
        let renumbered = new.songToneFirstProgram != settings.songToneFirstProgram
        let midiChanged = new.channel != settings.channel || new.programs != settings.programs
            || new.songTones != settings.songTones || new.songTonePrograms != settings.songTonePrograms || renumbered
        settings = new
        new.save(to: settingsPath)
        settingsModified = Self.modified(settingsPath)
        record("settings: channel \(new.channel), programs \(new.programs), lead \(new.leadMs) ms, overlays "
            + (new.overlayEnabled ? "on (port \(new.overlayPort))" : "off") + ", song tones " + (new.songTones ? "on" : "off"))
        if midiChanged {
            makeSongTones(force: renumbered)
            resend()
        }
        overlay.configure(enabled: new.overlayEnabled, port: new.overlayPort)
        if new.aiClassify { classifyIfNeeded() }
    }

    func program(for category: Category) -> Int { settings.program(for: category) }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func setPaused(_ value: Bool) {
        paused = value
        record(value ? "MIDI paused" : "MIDI resumed")
        if !value { send(reason: "resumed") }
    }

    /// Sets (category) or removes (nil: back to automatic) the override for a tone in every
    /// part of this song that uses it, saves presets.json, and switches right away if that
    /// changes the active tone's category.
    func override(_ row: ToneRow, to category: Category?) {
        setOverride(row, to: category)
        remap(reason: "override")
    }

    private func setOverride(_ row: ToneRow, to category: Category?) {
        var slots = [(arrangement: arrangement, slot: row.slot)]
        for part in songParts {
            for (slot, key) in part.slots where key.lowercased() == row.key.lowercased() {
                if !(part.arrangement == arrangement && slot == row.slot) { slots.append((part.arrangement, slot)) }
            }
        }
        presets.set(slots, key: row.key, to: category)
        let places = slots.map { "\($0.arrangement) \($0.slot)" }.joined(separator: ", ")
        record("override: \(row.key) → \(category?.name ?? "automatic") in \(places)")
    }

    // MARK: AI

    /// Keeps what the AI model changed for this song as your own: its tones' categories as
    /// overrides (in every part that uses them) and its style in "song_styles".
    func acceptAI() {
        guard case .answered = ai?.state else { return }
        let key = Presets.songKey(arrangement)
        for row in tones where row.reason.hasSuffix(", AI") { setOverride(row, to: row.category) }
        let heaviness = Rig.heaviness(rigArrangements)
        let style = presets.style(heaviness: heaviness, artist: artist, songKey: key)
        if style != presets.style(heaviness: heaviness, artist: artist, songKey: key, ai: false) {
            presets.setStyle(key, style)
            record("AI accepted: \(key) style \(style)")
        }
        remap(reason: "AI accepted")
    }

    /// A new API key: songs that failed are asked about again.
    func apiKeyChanged() {
        aiFailures = [:]
        refreshAI()
        classifyIfNeeded()
    }

    /// Stops (or with false, starts again) using the AI model's answer for this song.
    func rejectAI(_ rejected: Bool = true) {
        let key = Presets.songKey(arrangement)
        presets.setRejected(key, rejected)
        record("AI " + (rejected ? "rejected" : "used again") + " for \(key)")
        remap(reason: rejected ? "AI rejected" : "AI used again")
    }

    /// The window's view of the AI for the current song.
    private func refreshAI() {
        guard song != nil, !arrangement.isEmpty else { ai = nil; return }
        let key = Presets.songKey(arrangement)
        if presets.isRejected(key) {
            ai = AIVerdict(state: .rejected)
        } else if let answer = presets.answer(key) {
            ai = AIVerdict(state: .answered(answer), changes: aiChanges(key))
        } else if presets.answered(key) {
            ai = AIVerdict(state: .guess)
        } else if asking.contains(key) {
            ai = AIVerdict(state: .asking)
        } else if let why = aiFailures[key] {
            ai = AIVerdict(state: .failed(why))
        } else {
            ai = nil
        }
    }

    /// What the AI changes for this song: tones it maps differently, and the style.
    private func aiChanges(_ key: String) -> [String] {
        var out: [String] = []
        for row in tones where row.reason.hasSuffix(", AI") {
            let t = songTones.first { $0.slot == row.slot } ?? gameTone(slot: row.slot, key: row.key)
            let change = "\(row.key): \(match(t, ai: false).category.name) → \(row.category.name)"
            if !out.contains(change) { out.append(change) }  // a tone in several slots
        }
        let heaviness = Rig.heaviness(rigArrangements)
        let style = presets.style(heaviness: heaviness, artist: artist, songKey: key)
        let ruled = presets.style(heaviness: heaviness, artist: artist, songKey: key, ai: false)
        if style != ruled { out.append("style: \(ruled) → \(style)") }
        return out
    }

    /// With the AI on and a key saved, asks the model about a song it hasn't answered yet, in the
    /// background; the song is mapped again when the answer comes.
    private func classifyIfNeeded() {
        guard settings.aiClassify, song != nil, !arrangement.isEmpty, !rigArrangements.isEmpty else { return }
        let key = Presets.songKey(arrangement)
        guard !presets.answered(key), !presets.isRejected(key), !asking.contains(key), aiFailures[key] == nil else { return }
        guard let apiKey = APIKey.get() else { return }
        let song = aiSong(key)
        let model = settings.aiModel, styles = presets.styleList, path = presets.answersPath
        asking.insert(key)
        refreshAI()
        record("AI: asking \(model) about \(key)")
        Task {
            do {
                let answer = try await AIClassifier.classify(song, styles: styles, model: model, key: apiKey)
                AIClassifier.save(answer, songKey: key, to: path)
                asking.remove(key)
                record("AI: \(key) \(answer["style"] as? String ?? "?"), \(answer["distortion"] as? String ?? "?") "
                    + "(\(answer["confidence"] as? String ?? "?")): \(answer["reason"] as? String ?? "")")
                presets.reload()
                remap(reason: "AI answer")
            } catch {
                asking.remove(key)
                aiFailures[key] = "\(error)"
                record("AI: asking about \(key) failed: \(error)")
                refreshAI()
            }
        }
    }

    /// What the model is told about the current song (classify_songs.py songs_from_index): what
    /// the rules alone give its guitar parts' tones.
    private func aiSong(_ key: String) -> AIClassifier.Song {
        let slotNames = ["Base", "A", "B", "C", "D"]
        let guitar = rigArrangements.filter { ["Lead", "Rhythm", "Combo"].contains($0.path) }
        var categories: [String: Int] = [:], amps: [(String, Int)] = []
        for a in guitar {
            for (i, toneKey) in a.slots.enumerated() where !toneKey.isEmpty && i < slotNames.count {
                guard let t = Rig.tone(a, key: toneKey) else { continue }
                let amp = t.gear["Amp"]?.key
                let m = presets.match(arrangement: a.name, slot: slotNames[i],
                                      tone: Presets.Tone(key: toneKey, descriptors: t.descriptors, amp: amp,
                                                         gain: t.gear["Amp"]?.knob("Gain"), drive: Rig.drive(t)),
                                      artist: artist, ai: false)
                categories[m.category.name, default: 0] += 1
                if let amp {
                    let name = amp.hasPrefix("Amp_") ? String(amp.dropFirst(4)) : amp
                    if let j = amps.firstIndex(where: { $0.0 == name }) { amps[j].1 += 1 } else { amps.append((name, 1)) }
                }
            }
        }
        let heaviness = Rig.heaviness(rigArrangements)
        return AIClassifier.Song(
            songKey: guitar.first.map { Presets.songKey($0.name) } ?? key, artist: artist.trimmingCharacters(in: .whitespaces),
            title: (song ?? "").trimmingCharacters(in: .whitespaces), tuning: guitar.first.flatMap(Rig.tuningName),
            tempo: (guitar.first ?? rigArrangements.first)?.tempo, heaviness: heaviness,
            ruleStyle: presets.style(heaviness: heaviness, artist: artist, songKey: key, ai: false),
            ruleCategories: categories,
            amps: amps.enumerated()
                .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }  // most used first
                .prefix(3).map(\.element.0))
    }

    /// Picks up rscompanion.json edited by hand (checked with every event and every 2 s).
    private func reloadSettingsIfEdited() {
        guard Self.modified(settingsPath) != settingsModified else { return }
        settingsModified = Self.modified(settingsPath)
        let new = Settings.load(from: settingsPath)
        guard new != settings else { return }
        // A new first program changes the message, so it is sent again.
        let renumbered = new.songToneFirstProgram != settings.songToneFirstProgram
        let midiChanged = new.channel != settings.channel || new.programs != settings.programs
            || new.songTones != settings.songTones || new.songTonePrograms != settings.songTonePrograms || renumbered
        settings = new
        record("rscompanion.json changed: channel \(new.channel), programs \(new.programs), lead \(new.leadMs) ms, "
            + "song tones " + (new.songTones ? "on" : "off"))
        if midiChanged {
            makeSongTones(force: renumbered)
            resend()
        }
        overlay.configure(enabled: new.overlayEnabled, port: new.overlayPort)
    }

    private func handle(_ e: GameEvent) {
        reloadSettingsIfEdited()
        checkPresets()
        if overlay.running { overlay.handle(e) }
        switch e.event {
        case "song":
            setSong(e)
            activeSlot = nil
            active = nil
            record("song \(e.song ?? "?") - \(e.artist ?? "?") (\(e.arrangement ?? "?")): "
                + tones.map { "\($0.slot)=\($0.key)→\($0.category.name)" }.joined(separator: ", "))
        case "tone":
            if e.arrangement != arrangement { setSong(e) }
            guard let slot = e.slot, let key = e.tone else { return }
            let descriptors = e.descriptors ?? []
            let tone = GameEvent.Tone(slot: slot, tone: key, descriptors: descriptors, amp: e.amp, gain: e.gain)
            let m = match(tone)
            active = tone
            activeSlot = slot
            activeCategory = m.category
            let when = e.time.map { String(format: " at %.2f s", $0) } ?? ""
            record("tone \(slot) \(key) [\(descriptors.joined(separator: " "))] from \(e.source ?? "?")\(when)"
                + " → \(m.category.name) (\(m.preset), \(m.reason))")
            send(reason: key)
        case "state":
            lastHeartbeat = Date()
            if e.game != game {
                game = e.game
                record("connected to " + (game == RockNRoller.game ? RockNRoller.name : "Rocksmith"))
            }
            timerLocked = e.timer_locked ?? false
            leadMs = e.lead_ms ?? leadMs
            guard e.song != nil else {
                // The game plays a song the in-game library didn't see load (or the game restarted).
                if song != nil {
                    record("no song from the game; song cleared until the next one loads")
                    clearSong()
                }
                return
            }
            if e.arrangement != arrangement || (tones.isEmpty && e.tones != nil) || (songParts.isEmpty && e.parts != nil) {
                setSong(e)
            }
            // Started mid-song: catch up with the active tone once.
            if active == nil, let slot = e.slot, let key = e.tone {
                let tone = songTones.first { $0.slot == slot && $0.tone == key }
                    ?? GameEvent.Tone(slot: slot, tone: key, descriptors: songTones.first { $0.slot == slot }?.descriptors ?? [])
                let m = match(tone)
                active = tone
                activeSlot = slot
                activeCategory = m.category
                record("caught up: tone \(slot) \(key) → \(m.category.name)")
                send(reason: key)
            }
        default:
            break
        }
    }

    private func clearSong() {
        song = nil
        artist = ""
        arrangement = ""
        archive = ""
        songTones = []
        songParts = []
        tones = []
        active = nil
        activeSlot = nil
        activeCategory = nil
        songTonesKey = ""
        madeTones = nil
        toneDrives = [:]
        drivesKey = ""
        rigArrangements = []
        ai = nil
    }

    private func setSong(_ e: GameEvent) {
        song = e.song
        artist = e.artist ?? ""
        arrangement = e.arrangement ?? ""
        archive = e.archive ?? archive
        if let list = e.tones { songTones = list }
        if let list = e.parts { songParts = list }
        readDrives()
        tones = rows()
        makeSongTones()
        refreshAI()
        classifyIfNeeded()
    }

    /// The song's file name prefix ("selftrap" for "selftrap_rhythm").
    private var songPrefix: String {
        arrangement.lastIndex(of: "_").map { String(arrangement[..<$0]) } ?? arrangement
    }

    /// Each tone's drive (how distorted its rig is, for the rules' "drive") from the song's
    /// archive, once per song (a few ms).
    private func readDrives() {
        let key = archive + "|" + songPrefix.lowercased()
        guard key != drivesKey else { return }
        drivesKey = key
        toneDrives = [:]
        rigArrangements = []
        guard !archive.isEmpty, let arrangements = Rig.read(archive: archive, prefix: songPrefix) else { return }
        rigArrangements = arrangements
        for a in arrangements {
            for key in a.slots where !key.isEmpty {
                if let t = Rig.tone(a, key: key), let d = Rig.drive(t) { toneDrives[key.lowercased()] = d }
            }
        }
    }

    /// With song tone messages on, reads the song's gear from its archive and sends the song's
    /// tones (once per arrangement; again when the settings or the mapping change).
    private func makeSongTones(force: Bool = false) {
        guard settings.songTones, let song, !arrangement.isEmpty, !archive.isEmpty else {
            if !settings.songTones { madeTones = nil }
            return
        }
        let key = archive + "|" + arrangement
        guard force || key != songTonesKey else { return }
        songTonesKey = key
        let prefix = songPrefix
        let t0 = Date()
        guard let arrangements = Rig.read(archive: archive, prefix: prefix),
              var made = SongTones.make(song: song, artist: artist, arrangement: arrangement, from: arrangements,
                                        firstProgram: settings.songToneFirstProgram,
                                        category: { slot, key in
                                            self.match(self.gameTone(slot: slot, key: key)).category
                                        },
                                        style: { self.presets.style(heaviness: $0, artist: self.artist, songKey: prefix) })
        else {
            madeTones = nil
            return record("song tones: could not read \(arrangement) from \(archive)")
        }
        made.styles = presets.styleNames
        madeTones = made
        let message = made.json
        if paused {
            return record("paused: would send song tones \(made.summary)")
        }
        midi.sysex([0x7D] + Array(message.utf8))
        record(String(format: "MIDI SysEx song tones (%d bytes, %.0f ms) %@", message.utf8.count + 1,
                      Date().timeIntervalSince(t0) * 1000, made.summary))
    }

    /// A tone key's tags, from the song event.
    /// The game's tone for a song tone, with its descriptors, amp and gain, so it gets the
    /// same category as when it plays; only the key and slot if the game didn't list it.
    private func gameTone(slot: String, key: String) -> GameEvent.Tone {
        guard let t = songTones.first(where: { $0.tone.lowercased() == key.lowercased() }) else {
            return GameEvent.Tone(slot: slot, tone: key, descriptors: [])
        }
        return GameEvent.Tone(slot: slot, tone: key, descriptors: t.descriptors, amp: t.amp, gain: t.gain)
    }

    private func rows() -> [ToneRow] {
        songTones.map { t in
            let m = match(t)
            let auto = match(t, overrides: false)
            return ToneRow(slot: t.slot, key: t.tone, descriptors: t.descriptors, category: m.category,
                           preset: m.preset, reason: m.reason, automatic: auto.category)
        }
    }

    /// Shows (and logs, once) whether presets.json can be read; with reload, re-reads it first
    /// if it changed.
    private func checkPresets(reload: Bool = true) {
        if reload, presets.reload() {
            record("presets.json changed; mapping again")
            remap(reason: "presets.json changed")
        }
        guard presets.error != presetsError else { return }
        presetsError = presets.error
        record(presetsError ?? "presets.json can be read again")
    }

    /// Mapping changed: refresh the rows, and switch if the active tone's category changed.
    private func remap(reason: String) {
        checkPresets(reload: false)  // an override or AI change reads the file before saving
        tones = rows()
        refreshAI()
        guard let a = active else { return }
        let m = match(a)
        activeCategory = m.category
        makeSongTones(force: true)  // the template categories may have changed
        send(reason: "\(a.tone) (\(reason))")
    }

    private func match(_ t: GameEvent.Tone, overrides: Bool = true, ai: Bool = true) -> Presets.Match {
        presets.match(arrangement: arrangement, slot: t.slot,
                      tone: Presets.Tone(key: t.tone, descriptors: t.descriptors, amp: t.amp, gain: t.gain,
                                         drive: toneDrives[t.tone.lowercased()]),
                      artist: artist, overrides: overrides, ai: ai)
    }

    /// The program for the active tone: its song tone's, or its category's.
    private func target() -> (program: Int, label: String)? {
        guard let category = activeCategory else { return nil }
        if settings.songTones, settings.songTonePrograms, let tone = active, let program = madeTones?.program(for: tone.tone) {
            return (program, "song tone, \(category.name)")
        }
        return (settings.program(for: category), category.name)
    }

    /// Sends only when the program changes: many devices drop unsaved edits on every preset
    /// change, so the same program is never sent twice in a row.
    private func send(reason: String) {
        guard let (program, label) = target(), program != sentProgram else { return }
        guard !paused else {
            record("paused: would send PC \(program) (\(label))")
            return
        }
        midi.programChange(program, channel: settings.channel)
        sentProgram = program
        let clock = Date().formatted(date: .omitted, time: .standard)
        lastMIDI = "PC \(program) ch \(settings.channel) (\(label)) · \(clock)"
        record("MIDI PC \(program) ch \(settings.channel) (\(label)) for \(reason)")
    }

    private let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"  // local time, like the dylib's log
        return f
    }()

    private func record(_ message: String) {
        log?.write(Data("\(stampFormat.string(from: Date())) \(message)\n".utf8))
    }
}
