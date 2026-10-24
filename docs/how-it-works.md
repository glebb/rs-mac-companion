# How it works

There are two ways to run the companion. Both detect the song, the arrangement and the active
tone the same way (details: [game-memory.md](game-memory.md), [song-files.md](song-files.md));
they differ in where the detection runs.

| | **In-game** (current) | **External** (original) |
|---|---|---|
| Detection | `librscompanion` dylib inside the game | `rstone.py` + `rsprobe` reading the game from outside |
| Song data | read live from the archive the game is loading | pre-built index of all songs (`index_songs.py`) |
| Needs | the game executable patched to load the dylib | Developer Mode, Python |
| Output | events to the **RS Companion** menu-bar app → MIDI (Program Changes; song tone messages), stream overlays | JSON lines, UDP, live web window |

## In-game: dylib + menu-bar app

RockNRoller, a Rocksmith chart player, gets a library of its own that sends the same events
(`native/rnrcompanion.c`; it reads the song, part and position by name, see
[rocknroller.md](rocknroller.md)). What both libraries share is in `native/rscore.c`.

```
Rocksmith2014 (x86_64, Rosetta)
  + librscompanion.dylib  (native/rscompanion.c + native/rsfile.c, loaded by an LC_LOAD_DYLIB)
      │ file reads → song + tone timelines     memory → arrangement, song timer, banners
      │ JSON datagrams, non-blocking
      ▼  DATA_DIR/events.sock
RS Companion.app (app/, menu bar)
      │ presets.json → category (Clean / Crunch / Heavy / Lead)   rscompanion.json → settings
      │ song's archive → each tone's effects, the song's style (song tone messages, optional)
      ▼  virtual MIDI source "Rocksmith Companion": Program Changes, song tone SysEx
your MIDI-controlled amp, speaker or app (e.g. Bandbox Stagehand for song tones)
```

### The dylib ([native/rscompanion.c](../native/rscompanion.c))

Loaded by the game at startup (constructor `init()`); five threads, so nothing ever runs on the
game's own threads except a few counters in the file-call interposers.

| Thread | Does |
|---|---|
| interposers (game threads) | `open`, `openat`, `fopen`, `close`, `fclose`, `fread`, `read`, `pread` are interposed with dyld `__interpose`. For `.psarc` files they remember the path per descriptor and queue `(path, offset)` of each read. Never block, never read files themselves. |
| **worker** | Maps queued reads to archive entries (cached tables of contents). A read in a `songs/bin/macos/<key>_<part>.sng` entry means the game is loading song `<key>`: reads every arrangement's manifest and tone timeline from that archive (1–5 ms). Reads within 10 s of the same song count as one load. |
| **searcher** | After each song load: finds the selected arrangement (object that exists twice) every second for up to 2 minutes until found. Then, once per song, finds the game's live play record (`Play_<SongKey>` with the song position) every 3 s until the song plays: confirms the timer candidate equal to its position, or checks (and if wrong, drops) a confirmed timer. On hold (see tracker), checks every 2 s: a live record of this song ends the hold; none in 5 checks while the timer runs 10 s on means another song plays whose files the game didn't read now, so the song is dropped (heartbeats without a song, no tone events until the next load). Rate-searches for timer candidates while unconfirmed: for arrangements with tone changes, and for others while the play record shows the song playing. |
| **banner watch** | Finds new `"<Song> - <Tags>"` banners: continuously until the timer is confirmed, afterwards only just after each expected change and every 15 s. |
| **tracker** | 20 times a second: emits events, confirms the timer with banners, follows the active slot at `timer + lead` (not on hold: after the timer goes back more than 2 s, or after an arrangement is picked while a timer from an earlier song is confirmed, until the play record or a banner shows this song playing), sends a heartbeat every second, re-reads settings. |
| **stats watch** | Only with `overlay_enabled` (stream overlays): while an arrangement is selected, looks for the game's note-stats and Score Attack objects by type pointer and marker ([game-memory.md § 8](game-memory.md#8-note-statistics)) every 2 s (narrow scans; a full one at most every 10 s), then reads them 4 times a second until the game frees them. |

Memory searches learn which memory tags hold what they look for and scan only those
(`rscompanion_tags.txt`); see [game-memory.md § 9](game-memory.md#9-where-things-live-memory-tags).

### Events (dylib → app)

JSON datagrams on the Unix socket `DATA_DIR/events.sock`, which **the app owns** (binds). The
dylib sends with a non-blocking `sendto`; with no app or a full queue the event is dropped, so the
game can never wait on the app. Datagrams can exceed the 2 KB system default: the dylib raises its
send buffer to 16 KB, the app its receive buffer to 256 KB. Protocol version 1.

```jsonc
// The selected arrangement changed (also when the same song is loaded again)
{"event": "song", "song": "18 And Life", "artist": "Skid Row", "arrangement": "skid18an_lead",
 "song_key": "Skid18an", "archive": "/…/dlc/skid18an_m.psarc",   // also in tone and state events
 "tones": [{"slot": "Base", "tone": "skid18an_clean", "descriptors": ["CLEAN"], "amp": "Amp_TW22", "gain": 14}, ...],   // slots in use
 "parts": [{"arrangement": "skid18an_rhythm", "slots": {"Base": "skid18an_clean", "A": "..."}}, ...]}  // all arrangements

// The tone changed
{"event": "tone", "song": "...", "artist": "...", "arrangement": "skid18an_lead", "slot": "B",
 "tone": "skid18an_dist", "descriptors": ["DISTORTION"], "amp": "Amp_HG500", "gain": 88, "source": "timer", "time": 41.01}

// Heartbeat, every second: the whole state
{"event": "state", "protocol": 1, "pid": 19972, "lead_ms": 100, "timer_locked": true,
 "song": "...", "artist": "...", "arrangement": "...", "tones": [...], "parts": [...],
 "slot": "B", "tone": "skid18an_dist", "time": 52.3}         // song fields only once a song is known

// Note statistics, 4 times a second while a song is played (only with overlay_enabled)
{"event": "stats", "mode": "las", "hits": 120, "misses": 7, "streak": 31, "best_streak": 54,
 "miss_streak": 0, "time": 63.2,
 // Score Attack ("mode": "sa") also:
 "best_miss_streak": 4, "perfect_hits": 57, "perfect_streak": 0, "late_hits": 8, "late_streak": 1,
 "phrases": [3, 6, 0, 1], "phrase_streaks": [2, 0, 0, 0], "best_phrase_streaks": [2, 5, 0, 1],  // perfect, good, passed, failed
 "score": 80856, "multiplier": 8, "best_multiplier": 8}
{"event": "stats", "live": false}                             // once, when the game frees them (song left)
```

`source`: `song-start` (the arrangement's starting Base tone, when it is selected), `banner` (the
game's on-screen tone text; used until the timer is confirmed, up to ~1 s late) or `timer` (song
timer + timeline; on time, `time` = song position). The heartbeat lets an app started mid-song
catch up, and tells it whether the game (with the dylib) is running.

`tools/event_listener.py` prints the events (instead of the app; only one can own the socket).

### The app ([app/](../app))

| File | Does |
|---|---|
| `EventSocket.swift` | binds `events.sock`, decodes events on a background queue, delivers them on the main thread |
| `Presets.swift` | the mapping in `presets.json` and the AI answers, evaluated exactly like `presets.py` (checked on all 17,542 tone slots of a library) |
| `Category.swift` | Clean, Crunch, Heavy, Lead |
| `Settings.swift` | `rscompanion.json`: MIDI channel, Program Change per category, lead time, stream overlays, song tone messages and their Program Changes, AI classification and its model |
| `AIClassifier.swift` | AI song classification: asks OpenAI's Responses API about a song (the prompt and answer schema of `classify_songs.py`), saves the answer in `ai_classified.json`; the API key in the keychain |
| `MIDIOut.swift` | a CoreMIDI virtual source "Rocksmith Companion"; Program Change and SysEx as MIDI 1.0 UMP, held for the first second so listeners can connect |
| `Rig.swift` | a song's gear read from its archive: each tone's tags, drive and effects, the song's tuning and heaviness; the same rules as `rig.py` (checked identical on all 2,768 songs of a library) |
| `SongTones.swift` | song tone messages: the SysEx (manufacturer 0x7D, then JSON, version 2) sent when a song loads, describing each tone in Rocksmith's terms for any tool, and a Program Change per tone (8–12 by default). The format: [song-tone-messages.md](song-tone-messages.md) |
| `Companion.swift` | state, mapping, overrides, when to send, AI requests and their answers, install status and warnings |
| `GameInstaller.swift`, `MachOPatcher.swift` | install, update and uninstall in the game (below) |
| `Main.swift` | starts the app, or runs an install command (`--game-status`, `--install-game`, `--uninstall-game`) |
| `App.swift`, `SettingsView.swift` | the menu-bar window (SwiftUI `MenuBarExtra`) |
| `Overlay.swift`, `OverlayServer.swift`, `SongDetails.swift` | RockSniffer-compatible stream overlays (below) |

**Mapping** a tone to a category (first match wins, like `rstone.py`):
1. `songs`: per arrangement and slot (the app's overrides go here)
2. `tones`: per tone key (hand edits)
3. `rules`: by tags (`any` / `all`), words in the tone key (`name`), the tone's amp (`amp`), its
   gain knob (`gain`, at least) and its drive band (`drive`: clean / crunch / heavy, from
   `Rig.drive` on the gear the app reads from the song's archive when the song loads)
4. `default`

then `artists` may change the result of 3 or 4 for the song's artist (`{"Bon Jovi": {"Heavy":
"Crunch"}}`), or where that has nothing for the category, an AI model (reason `, AI`, shown as
"AI"): the song's own answer in `ai_classified.json` ("crunch" turns Heavy into Crunch, "heavy"
Crunch into Heavy), or for a song without one, the artist-wide suggestions in
`ai_suggestions.json` (`classify_songs.py`); songs in `ai_rejected` get neither. The window counts
these as automatic: the badge shows no pencil for them, and reset doesn't remove them.

With the AI setting on and a key in the keychain, the app asks the model about a song the first
time it loads (`AIClassifier.swift`, the same prompt as `classify_songs.py`), in the background;
when the answer is saved the song is mapped again (and the song tone message sent again), so
the answer is in use without a click. A failed request is shown in the window and tried again
when a key is saved or the app restarts. Nothing goes online with the setting off.
**Keep as mine** writes what it changes as `songs` overrides and a `song_styles` entry; **Don't
use** adds the song to `ai_rejected`.

(Rule syntax, the default rules, their limits and how to tune them: see
[How tones are mapped](../README.md#how-tones-are-mapped).)

The matched preset name is read as a category: a category name itself, or via the `categories`
section (`Distortion` → Heavy, `Acoustic` → Clean, `Bass` → Clean, `Bass Drive` → Crunch).

**Overrides** (the badge menu in the window) set a category for a tone in **every part of the song
that uses it** (all `parts` slots with the same tone key), written to `songs`. A changed tone shows
a pencil and its automatic category; reset (↺) removes the override in all parts (and any `tones`
entry for that key). `presets.json` edits by hand are picked up within a second.

**Sending**: a Program Change only when the active tone's **category** changes (two tones mapped
to Heavy send once: many devices drop unsaved edits on every preset change). An app started
mid-song sends the current category once from the heartbeat. Changing the MIDI settings or the
active tone's mapping resends. Pause stops sending; Resend sends the current category again.

**Settings** (`rscompanion.json`, shared with the dylib):

```json
{"lead_ms": 100, "midi_channel": 1, "programs": {"Clean": 0, "Crunch": 1, "Heavy": 2, "Lead": 3}}
```

`programs` presets in the app: 0–3 (default), 4–7, or custom. `overlay_enabled` (default false)
and `overlay_port` (9938) switch the stream overlays; `song_tones` (false), `song_tone_programs`
(true) and `song_tone_first_program` (8) the song tone messages; `ai_classify` (false) and
`ai_model` (`gpt-6-luna`) the AI classification, whose API key is kept in the login keychain, not
here (the dylib reads this file too).
The dylib re-reads `lead_ms` and `overlay_enabled` within a second (no game restart).

**Stream overlays** (RockSniffer compatible). [RockSniffer](https://github.com/kokolihapihvi/RockSniffer)
by kokolihapihvi and contributors (Windows, MIT) feeds OBS overlays from a local HTTP service; the
app serves the same API, so its overlay pages ("addons", bundled unchanged from
`third_party/rocksniffer-addons`) and others written for it work unchanged. The API, field names,
states, text files, tuning names and the way song details are built all follow RockSniffer's
code ([credits](../README.md#credits)). With `overlay_enabled`:

- `OverlayServer.swift` listens on `127.0.0.1:<overlay_port>` only. `GET /` returns RockSniffer's
  `{success, currentState, memoryReadout, songDetails, Version}`; `GET`/`PUT /storage/<addon>/<key>`
  keeps addon values in `DATA_DIR/addon_storage`; `GET /addons/…` serves the addons (a folder: the
  index page; `config.js` is generated with the port). Every response allows any origin, but only
  requests to `127.0.0.1` or `localhost` (by Host header) are answered, against DNS rebinding, and a
  `PUT` from a web page needs the addons' own origin (or `null`, a page opened as a file).
- `Overlay.swift` keeps the state from the events. `memoryReadout`: `songTimer`, `songID`
  (SongKey), `arrangementID` (the selected arrangement's manifest `PersistentID`), `mode` (1 Learn
  a Song, 2 Score Attack), `noteData` (from `stats` events, in RockSniffer's field names; accuracy =
  hits / (hits + misses) × 100). `currentState`, inferred: 0 no game, 1 menus, 2 song selected,
  3 for a second after the stats objects appear, 4 playing, 5 ending (the timer stopped at the
  song's end, or for 2 s after the objects go; `gameStage` is then `las_songreview` /
  `sa_songreview`, which addons use to close the last section), then 1 until the next song.
- `SongDetails.swift` reads `songDetails` from the song's archive with `native/rsfile.c` (compiled
  into the app): from the manifests the names, album, year, length, and per arrangement its
  `PersistentID`, path type, bonus/alternate flags, tuning (RockSniffer's tuning names), sections
  and phrase iterations (numbered `"<name> <n>"`); from the `.sng` files the measures (beats) and
  the vocals; the album art (DDS, which ImageIO reads) as base64 JPEG; `toolkit.version` of custom
  songs; the archive's MD5 (`psarcFileHash`). Read once per song in the background and cached.
- Every second it writes RockSniffer's default text files to `DATA_DIR/output`
  (`song_details.txt`, `album_details.txt`, `song_timer.txt`, `notes.txt`, `accuracy.txt`,
  `streaks.txt`, same placeholders and formats) and `album_cover.jpeg` on each song.

### Installing into the game

The app installs itself into the game (`GameInstaller.swift`, `MachOPatcher.swift`); the library
is bundled in the app (`Contents/Resources/librscompanion.dylib`, built by `app/build.sh`).

**Finding the game:** the folder set in Settings, else where Steam installed it: Steam's own
library, then every library in `steamapps/libraryfolders.vdf` (Rocksmith's app ID is 221680; its
`appmanifest_221680.acf` names the folder under `steamapps/common`, normally `Rocksmith2014`),
then `/Applications`. Libraries on drives that aren't connected are skipped.

**Install / Update** (refused while that game folder's Rocksmith is running):
1. If the executable has no companion load command yet, copy it to `Rocksmith2014.orig` (the backup
   is never overwritten with a patched file).
2. Copy the library to `Rocksmith2014.app/Contents/MacOS/librscompanion.dylib` and remove the
   quarantine flag (a downloaded app's copy would otherwise not load).
3. Remove older companion load commands (`librscompanion_test.dylib` from prototype installs) and
   add `LC_LOAD_DYLIB @executable_path/librscompanion.dylib` to the **x86_64 slice**, in the free
   header space after the last load command. Nothing else in the file moves; the i386 slice is not
   touched; a fresh install changes ~48 bytes.
4. Every file is written next to its destination and renamed into place, so a starting game never
   sees a half-written file.

**Uninstall** removes the companion's load command(s) and library only: the commands after it
move up and the freed space is zeroed, which gives back the executable byte for byte as it was
before install, with anything installed alongside (the custom-song patch's `libRSBypass`) kept.
Removing a load command shifts the library ordinals of later ones; that's harmless for libraries
the game imports nothing from, which is what injected libraries like these are.

**Status** (checked whenever the game's files change): *not found*, *not installed* (also after a
Steam update replaced the executable), *update available* (older load command name, or the
installed library differs from the bundled one), *installed*. The app also warns when the game
has been running 20 s without heartbeats ("running without the companion": started before the
install, or the patch is gone).

The same, without the window: `"RS Companion.app/Contents/MacOS/RSCompanion" --game-status |
--install-game | --uninstall-game [game folder]`. `tests/run_installer_test.sh` runs it on a copy
of the game executable. `tools/add_load_dylib.py` does step 3 by hand for any executable.

## External: rstone.py + rsprobe

```
 Rocksmith2014 (x86_64 under Rosetta)
        │  memory, read-only (task_for_pid + mach_vm_read)
        ▼
 build/rsprobe ── /tmp/rsprobe.sock ──▶ rstone.py ──▶ stdout JSON, UDP, live window (ui.html)
                                           ▲
 game's .psarc song files ─▶ build/rstool ─▶ index_songs.py ─▶ tones_index.jsonl
                                           ▲
                               presets.json (your mapping)
```

- **rsprobe** (`native/rsprobe.c`) attaches to the game and answers line commands over a Unix
  socket: read bytes, search for bytes or pointers, int snapshots, a timer search. It only scans
  writable data. The discovery tools use it too ([game-memory.md § 12](game-memory.md#12-finding-something-new)).
- **rstool** (`native/rstool.c` on `native/rsfile.c`) prints each arrangement of an archive as
  one JSON line; **index_songs.py** runs it over all archives (50 per run, ~10 s for ~2,400) and
  caches results by file size and date.
- **rstone.py**: finds the image slide; every 5 s the selected arrangement (object that exists
  twice); the song timer by rate search, confirmed with banners; then the slot at
  `timer + lead_ms` every 50 ms; maps tones with `presets.py`.

## Tests

| Test | Covers |
|---|---|
| `tests/run_standin_test.sh` | rstone.py + rsprobe against `tests/standin.c` (timer, decoys, banners) |
| `tests/run_dylib_test.sh` | the dylib inside `tests/standin_dylib.c`, which reads the game's own `songs.psarc` (the song *Self Trap*) like the game and holds arrangement objects (including a stale pair), a timer, decoy clocks and banners; events checked on the socket; four runs (learning, then narrow scans with a 500 ms lead, then an arrangement without tone changes whose timer the play record locks, with stream overlays on: note-stats and Score Attack objects reported in `stats` events, then that song restarted and another song started without its files being read: dropped) |
| `tests/run_overlay_test.sh` | stand-in → dylib → app with stream overlays: RockSniffer's API (`GET /` with the song details read from `songs.psarc`, `/addons`, `/storage`), the text files and album art, the state after the game is gone |
| `tests/run_app_test.sh` | stand-in → dylib → app → MIDI (`tools/midi_monitor.swift`), with a song override, a live `presets.json` edit, custom MIDI settings and a restart catch-up |
| `tests/run_song_tones_test.sh` | stand-in → dylib → app with song tone messages on: the SysEx message at song load (style, tones in order of first use with their categories and effects) and Program Change 8 and 9 |
| `tests/run_installer_test.sh` | the installer on a copy of the game executable: fresh install, repeat, prototype migration, update, uninstall back to the original bytes, missing game, a damaged executable |
| `tests/run_events_test.sh` | `rscore.c`'s events from `tests/events_harness.c`, for an ordinary song and one with 16 arrangements and every name as long as allowed: valid JSON, only whole parts (as many as fit), the log saying how many |
| `tests/run_ai_app_test.sh` | `AIClassifier.swift` and `Presets.swift` against `tests/stub_responses.py` (a stand-in for OpenAI): the request (key, model, the script's prompt, strict schema), the saved answer, the song's remap and style, rejecting and using again, a wrong key |
| `tests/run_classify_test.sh` | `classify_songs.py` with `tests/stub_openai` for the `openai` package, on songs from your index: batches, suggestions, low-confidence answers left out, `presets.py` using them after your own entries |

The dylib and app tests read *Self Trap*, which comes with the game, from the game folder's
`songs.psarc`; the rstone test uses its index line (`tests/fixture_index.jsonl`). All use a
temporary data folder.

## Performance (measured on an Apple Silicon Mac)

- **Song load**: song detected at the game's first `.sng` read; all arrangements read in 1–5 ms;
  ~3.3 s before the audio starts.
- **Arrangement**: one narrow scan (~400–500 MB) in ~0.2 s, about 1 s after the load.
- **Timer**: rate-searched (4 s rounds) until a candidate is confirmed, normally seconds into the
  first song of a game session by the play record (or at its first banner); afterwards only the
  play record check, once per song (a narrow text scan, ~0.2–0.3 s every 3 s until the song
  plays). First-ever session: full scans (~2.5 GB, ~1 s each) while learning.
- **Steady state while playing**: the 20 Hz tracker and banner checks around tone changes;
  game memory unchanged (~1.0–1.2 GB with or without the dylib).
- **Latency**: tone changes reported 73–90 ms before the song file's change time (lead 100 ms);
  event → MIDI in the app ~1 ms.
