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
/// presets.json, and sends a Program Change when the active tone's category changes.
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
    private var sentCategory: Category?
    private var active: (slot: String, key: String, descriptors: [String])?
    private var songTones: [GameEvent.Tone] = []
    private var songParts: [GameEvent.Part] = []
    private let log: FileHandle?

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
        checkGame()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkGame() }
        }
    }

    // MARK: Installation in Rocksmith

    var installer: GameInstaller {
        GameInstaller(gameDir: settings.gameDir ?? GameInstaller.defaultGameDir,
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
        sentCategory = nil
        if let category = activeCategory { send(category, reason: "resend") }
    }

    /// Saves new settings (shared with the dylib, which picks up lead_ms within a second) and
    /// resends the current tone if the MIDI output changed.
    func update(_ new: Settings) {
        guard new != settings else { return }
        let midiChanged = new.channel != settings.channel || new.programs != settings.programs
        settings = new
        new.save(to: settingsPath)
        settingsModified = Self.modified(settingsPath)
        record("settings: channel \(new.channel), programs \(new.programs), lead \(new.leadMs) ms")
        if midiChanged { resend() }
    }

    func program(for category: Category) -> Int { settings.program(for: category) }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func setPaused(_ value: Bool) {
        paused = value
        record(value ? "MIDI paused" : "MIDI resumed")
        if !value, let category = activeCategory, category != sentCategory { send(category, reason: "resumed") }
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

    private func handle(_ e: GameEvent) {
        if Self.modified(settingsPath) != settingsModified {  // edited by hand
            settingsModified = Self.modified(settingsPath)
            let new = Settings.load(from: settingsPath)
            if new != settings {
                let midiChanged = new.channel != settings.channel || new.programs != settings.programs
                settings = new
                record("rscompanion.json changed: channel \(new.channel), programs \(new.programs), lead \(new.leadMs) ms")
                if midiChanged { resend() }
            }
        }
        if presets.reload() {
            record("presets.json changed; mapping again")
            remap(reason: "presets.json changed")
        }
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
            let m = presets.match(arrangement: arrangement, slot: slot, key: key, descriptors: descriptors)
            active = (slot, key, descriptors)
            activeSlot = slot
            activeCategory = m.category
            let when = e.time.map { String(format: " at %.2f s", $0) } ?? ""
            record("tone \(slot) \(key) [\(descriptors.joined(separator: " "))] from \(e.source ?? "?")\(when)"
                + " → \(m.category.name) (\(m.preset), \(m.reason))")
            send(m.category, reason: key)
        case "state":
            lastHeartbeat = Date()
            timerLocked = e.timer_locked ?? false
            leadMs = e.lead_ms ?? leadMs
            guard e.song != nil else { return }
            if e.arrangement != arrangement || (tones.isEmpty && e.tones != nil) || (songParts.isEmpty && e.parts != nil) {
                setSong(e)
            }
            // Started mid-song: catch up with the active tone once.
            if active == nil, let slot = e.slot, let key = e.tone {
                let descriptors = songTones.first { $0.slot == slot }?.descriptors ?? []
                let m = presets.match(arrangement: arrangement, slot: slot, key: key, descriptors: descriptors)
                active = (slot, key, descriptors)
                activeSlot = slot
                activeCategory = m.category
                record("caught up: tone \(slot) \(key) → \(m.category.name)")
                send(m.category, reason: key)
            }
        default:
            break
        }
    }

    private func setSong(_ e: GameEvent) {
        song = e.song
        artist = e.artist ?? ""
        arrangement = e.arrangement ?? ""
        if let list = e.tones { songTones = list }
        if let list = e.parts { songParts = list }
        tones = rows()
    }

    private func rows() -> [ToneRow] {
        songTones.map { t in
            let m = presets.match(arrangement: arrangement, slot: t.slot, key: t.tone, descriptors: t.descriptors)
            let auto = presets.match(arrangement: arrangement, slot: t.slot, key: t.tone, descriptors: t.descriptors,
                                     overrides: false)
            return ToneRow(slot: t.slot, key: t.tone, descriptors: t.descriptors, category: m.category,
                           preset: m.preset, reason: m.reason, automatic: auto.category)
        }
    }

    /// Mapping changed: refresh the rows, and switch if the active tone's category changed.
    private func remap(reason: String) {
        tones = rows()
        guard let a = active else { return }
        let m = presets.match(arrangement: arrangement, slot: a.slot, key: a.key, descriptors: a.descriptors)
        activeCategory = m.category
        send(m.category, reason: "\(a.key) (\(reason))")
    }

    /// Sends only when the category changes: many devices drop unsaved edits on every preset
    /// change, so the same category is never sent twice in a row.
    private func send(_ category: Category, reason: String) {
        guard category != sentCategory else { return }
        guard !paused else {
            record("paused: would send PC \(settings.program(for: category)) (\(category.name))")
            return
        }
        let program = settings.program(for: category)
        midi.programChange(program, channel: settings.channel)
        sentCategory = category
        let clock = Date().formatted(date: .omitted, time: .standard)
        lastMIDI = "PC \(program) ch \(settings.channel) (\(category.name)) · \(clock)"
        record("MIDI PC \(program) ch \(settings.channel) (\(category.name)) for \(reason)")
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
