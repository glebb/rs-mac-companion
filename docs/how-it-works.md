# How it works

There are two ways to run the companion. Both detect the song, the arrangement and the active
tone the same way (details: [game-memory.md](game-memory.md), [song-files.md](song-files.md));
they differ in where the detection runs.

| | **In-game** (current) | **External** (original) |
|---|---|---|
| Detection | `librscompanion` dylib inside the game | `rstone.py` + `rsprobe` reading the game from outside |
| Song data | read live from the archive the game is loading | pre-built index of all songs (`index_songs.py`) |
| Needs | the game executable patched to load the dylib | Developer Mode, Python |
| Output | events to the **RS Companion** menu-bar app → MIDI | JSON lines, UDP, live web window |

## In-game: dylib + menu-bar app

```
Rocksmith2014 (x86_64, Rosetta)
  + librscompanion.dylib  (native/rscompanion.c + native/rsfile.c, loaded by an LC_LOAD_DYLIB)
      │ file reads → song + tone timelines     memory → arrangement, song timer, banners
      │ JSON datagrams, non-blocking
      ▼  DATA_DIR/events.sock
RS Companion.app (app/, menu bar)
      │ presets.json → category (Clean / Crunch / Heavy / Lead)   rscompanion.json → settings
      ▼  virtual MIDI source "Rocksmith Companion"
your MIDI-controlled amp, speaker or app
```

### The dylib ([native/rscompanion.c](../native/rscompanion.c))

Loaded by the game at startup (constructor `init()`); four threads, so nothing ever runs on the
game's own threads except a few counters in the file-call interposers.

| Thread | Does |
|---|---|
| interposers (game threads) | `open`, `openat`, `fopen`, `close`, `fclose`, `fread`, `read`, `pread` are interposed with dyld `__interpose`. For `.psarc` files they remember the path per descriptor and queue `(path, offset)` of each read. Never block, never read files themselves. |
| **worker** | Maps queued reads to archive entries (cached tables of contents). A read in a `songs/bin/macos/<key>_<part>.sng` entry means the game is loading song `<key>`: reads every arrangement's manifest and tone timeline from that archive (1–5 ms). Reads within 10 s of the same song count as one load. |
| **searcher** | After each song load: finds the selected arrangement (object that exists twice) every second for up to 2 minutes until found. Then, once per song, finds the game's live play record (`Play_<SongKey>` with the song position) every 3 s until the song plays: confirms the timer candidate equal to its position, or checks (and if wrong, drops) a confirmed timer. Rate-searches for timer candidates while unconfirmed: for arrangements with tone changes, and for others while the play record shows the song playing. |
| **banner watch** | Finds new `"<Song> - <Tags>"` banners: continuously until the timer is confirmed, afterwards only just after each expected change and every 15 s. |
| **tracker** | 20 times a second: emits events, confirms the timer with banners, follows the active slot at `timer + lead`, sends a heartbeat every second, re-reads settings. |

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
 "tones": [{"slot": "Base", "tone": "skid18an_clean", "descriptors": ["CLEAN"], "amp": "Amp_TW22", "gain": 14}, ...],   // slots in use
 "parts": [{"arrangement": "skid18an_rhythm", "slots": {"Base": "skid18an_clean", "A": "..."}}, ...]}  // all arrangements

// The tone changed
{"event": "tone", "song": "...", "artist": "...", "arrangement": "skid18an_lead", "slot": "B",
 "tone": "skid18an_dist", "descriptors": ["DISTORTION"], "amp": "Amp_HG500", "gain": 88, "source": "timer", "time": 41.01}

// Heartbeat, every second: the whole state
{"event": "state", "protocol": 1, "pid": 19972, "lead_ms": 100, "timer_locked": true,
 "song": "...", "artist": "...", "arrangement": "...", "tones": [...], "parts": [...],
 "slot": "B", "tone": "skid18an_dist", "time": 52.3}         // song fields only once a song is known
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
| `Presets.swift` | the mapping in `presets.json`, evaluated exactly like `presets.py` (checked on all 17,542 tone slots of a library) |
| `Category.swift` | Clean, Crunch, Heavy, Lead |
| `Settings.swift` | `rscompanion.json`: MIDI channel, Program Change per category, lead time |
| `MIDIOut.swift` | a CoreMIDI virtual source "Rocksmith Companion"; Program Change as MIDI 1.0 UMP |
| `Companion.swift` | state, mapping, overrides, when to send, install status and warnings |
| `GameInstaller.swift`, `MachOPatcher.swift` | install, update and uninstall in the game (below) |
| `Main.swift` | starts the app, or runs an install command (`--game-status`, `--install-game`, `--uninstall-game`) |
| `App.swift`, `SettingsView.swift` | the menu-bar window (SwiftUI `MenuBarExtra`) |

**Mapping** a tone to a category (first match wins, like `rstone.py`):
1. `songs`: per arrangement and slot (the app's overrides go here)
2. `tones`: per tone key (hand edits)
3. `rules`: by tags (`any` / `all`), words in the tone key (`name`), the tone's amp (`amp`) and its
   gain knob (`gain`, at least)
4. `default`

then `artists` may change the result of 3 or 4 for the song's artist (`{"Bon Jovi": {"Heavy":
"Crunch"}}`). The window counts that as automatic: the badge shows no pencil for it, and reset
doesn't remove it.

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

`programs` presets in the app: 0–3 (default), 4–7, or custom.
The dylib re-reads `lead_ms` within a second (no game restart).

### Installing into the game

The app installs itself into the game (`GameInstaller.swift`, `MachOPatcher.swift`); the library
is bundled in the app (`Contents/Resources/librscompanion.dylib`, built by `app/build.sh`).

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
| `tests/run_dylib_test.sh` | the dylib inside `tests/standin_dylib.c`, which reads the game's own `songs.psarc` (the song *Self Trap*) like the game and holds arrangement objects (including a stale pair), a timer, decoy clocks and banners; events checked on the socket; three runs (learning, then narrow scans with a 500 ms lead, then an arrangement without tone changes whose timer the play record locks) |
| `tests/run_app_test.sh` | stand-in → dylib → app → MIDI (`tools/midi_monitor.swift`), with a song override, a live `presets.json` edit, custom MIDI settings and a restart catch-up |
| `tests/run_installer_test.sh` | the installer on a copy of the game executable: fresh install, repeat, prototype migration, update, uninstall back to the original bytes, missing game |

The dylib and app tests read *Self Trap*, which comes with the game, from the game folder's
`songs.psarc`; the rstone test uses its index line (`tests/fixture_index.jsonl`). All use a
temporary data folder.

## Performance (measured on an Apple Silicon Mac)

- **Song load**: song detected at the game's first `.sng` read; all arrangements read in 1–5 ms;
  ~3.3 s before the audio starts.
- **Arrangement**: one narrow scan (~400–500 MB) in ~0.2 s, about 1 s after the load.
- **Timer**: searched only until the first banner of a game session (~30–60 s of 4 s rounds);
  afterwards none. First-ever session: full scans (~2.5 GB, ~1 s each) while learning.
- **Steady state while playing**: the 20 Hz tracker and banner checks around tone changes;
  game memory unchanged (~1.0–1.2 GB with or without the dylib).
- **Latency**: tone changes reported 73–90 ms before the song file's change time (lead 100 ms);
  event → MIDI in the app ~1 ms.
