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
    @Published var paused = false
    @Published private(set) var settings: Settings
    @Published private(set) var installStatus: GameInstaller.Status = .notInstalled
    @Published private(set) var installMessage: String?
    @Published private(set) var gameRunning = false
    private var gameRunningSince: Date?
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
        overlay = Overlay(dataDir: dataDir) { [weak self] in self?.record($0) }
        overlay.configure(enabled: settings.overlayEnabled, port: settings.overlayPort)
        checkGame()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkGame()
                self?.reloadSettingsIfEdited()
            }
        }
    }

    // MARK: Installation in Rocksmith

    var installer: GameInstaller {
        GameInstaller(gameDir: settings.gameDir ?? GameInstaller.steamGameDir(),
                      bundledDylib: Bundle.main.url(forResource: "librscompanion", withExtension: "dylib"))
    }

    /// Whether the game runs, and its install status (re-read only when the files change).
    func checkGame(force: Bool = false) {
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

    /// Something about the installation the user should know or do, for the main window.
    var attention: (text: String, action: String?)? {
        switch installStatus {
        case .gameNotFound: return ("Rocksmith not found. Set its folder in Settings.", nil)
        case .notInstalled:
            let replaced = FileManager.default.fileExists(atPath: installer.backup)
            return (replaced ? "Not installed in Rocksmith. Steam may have updated the game." : "Not installed in Rocksmith yet.",
                    "Install")
        case .updateAvailable: return ("An update for Rocksmith is ready.", "Update")
        case let .problem(text): return (text, nil)
        case .installed:
            if gameRunning, let since = gameRunningSince, Date().timeIntervalSince(since) > 20, !connected() {
                return ("Rocksmith is running without the companion. Restart Rocksmith.", nil)
            }
            return nil
        }
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
        var slots = [(arrangement: arrangement, slot: row.slot)]
        for part in songParts {
            for (slot, key) in part.slots where key.lowercased() == row.key.lowercased() {
                if !(part.arrangement == arrangement && slot == row.slot) { slots.append((part.arrangement, slot)) }
            }
        }
        presets.set(slots, key: row.key, to: category)
        let places = slots.map { "\($0.arrangement) \($0.slot)" }.joined(separator: ", ")
        record("override: \(row.key) → \(category?.name ?? "automatic") in \(places)")
        remap(reason: "override")
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
        if presets.reload() {
            record("presets.json changed; mapping again")
            remap(reason: "presets.json changed")
        }
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
        guard !archive.isEmpty, let arrangements = Rig.read(archive: archive, prefix: songPrefix) else { return }
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

    /// Mapping changed: refresh the rows, and switch if the active tone's category changed.
    private func remap(reason: String) {
        tones = rows()
        guard let a = active else { return }
        let m = match(a)
        activeCategory = m.category
        makeSongTones(force: true)  // the template categories may have changed
        send(reason: "\(a.tone) (\(reason))")
    }

    private func match(_ t: GameEvent.Tone, overrides: Bool = true) -> Presets.Match {
        presets.match(arrangement: arrangement, slot: t.slot,
                      tone: Presets.Tone(key: t.tone, descriptors: t.descriptors, amp: t.amp, gain: t.gain,
                                         drive: toneDrives[t.tone.lowercased()]),
                      artist: artist, overrides: overrides)
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
