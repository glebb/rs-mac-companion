# rs-mac-companion

Real-time tone changes from **Rocksmith 2014 Remastered on macOS**: while you play, it knows which
song and arrangement you're on, which in-game tone is active, and which of *your* presets that tone
maps to, so it can drive your own equipment. The **RS Companion** menu-bar app switches presets
over MIDI to whatever plays your guitar sound (an amp, a speaker or an app that listens to MIDI),
in four categories: Clean, Crunch, Heavy and Lead.

It reads the game's memory (read-only, data only) and its song files. It never touches the game's
code; it only adds one library load to the game executable (like the usual custom-song patch).

## What do you need?

| You want | You need | Section |
|---|---|---|
| **MIDI preset switching while you play** (most people) | the **RS Companion app**. It contains everything, including the part that goes into the game. | [RS Companion](#rs-companion-the-in-game-version) |
| Tone changes as JSON / UDP / a web page, without changing the game | the **external mode** (`rstone.py`), which reads the game from outside | [External mode](#external-mode-rstonepy) |
| To work on this project, investigate the game, run the tests | the **developer tools** | [Developer tools](#developer-tools) |

The two ways to run detect the same things the same way; the difference is where:

| | RS Companion (in-game) | External mode |
|---|---|---|
| Runs | a small library inside the game, plus the menu-bar app | `rstone.py` + `rsprobe`, outside the game |
| Output | MIDI Program Change (and a window) | JSON lines, UDP, live web window |
| Song data | read live from the song the game loads | an index of all songs, built at start |
| Changes the game | adds one library load (with a backup; uninstallable) | no |
| Needs at run time | nothing else | Python 3, Developer Mode |

Both need Rocksmith 2014 Remastered from Steam on macOS (it runs under Rosetta on Apple Silicon).

## RS Companion (the in-game version)

### What you need

- Rocksmith 2014 Remastered (Steam, macOS)
- To build the app: Apple's **Command Line Tools** (`xcode-select --install`; they include
  `clang` and `swiftc`). Nothing else: no Python, no `build.sh`, no Developer Mode.

### Build and install

```bash
app/build.sh --install
```

builds `RS Companion.app`, copies it to /Applications and starts it: a guitar icon appears in the
menu bar. (`app/build.sh --run` builds and starts it from `app/build/` instead.)

Then quit Rocksmith and click **Install** in RS Companion (in the notice in its window, or in
Settings › Rocksmith). It adds the companion library to the game and keeps a backup of the game
executable as `Rocksmith2014.orig` ([what exactly it does](docs/how-it-works.md#installing-into-the-game)).
If your game isn't in Steam's default folder, choose it under Settings › Rocksmith first.

The app tells you when something needs doing:
- **Not installed** (also after a Steam update replaced the game executable): click Install.
- **Update**: a newer library comes with the app; click Update (with Rocksmith closed).
- **Rocksmith is running without the companion**: restart Rocksmith.

**Uninstall** (Settings › Rocksmith) removes only the companion; the rest of the game, including a
custom-song patch, stays as it is.

### Use

Start RS Companion and Rocksmith (any order) and pick a song. The menu-bar window shows:

- whether Rocksmith is connected, and whether the song timer is synced (it syncs within a few
  seconds of each song starting, from the game's own record of the playing song; a tone change
  before that comes from the game's on-screen tone text, up to ~1 s late; after that every change
  is on time, slightly early);
- the song, artist and part, and every tone of the part with its tags and category (Clean,
  Crunch, Heavy, Lead) and the Program Change it sends; the active tone is highlighted;
- the last MIDI message, **Pause MIDI** and **Resend**.

MIDI comes from a virtual source named **Rocksmith Companion**; most MIDI apps and devices see it
without setup. A Program Change is sent only when the category changes.

**Changing a tone's category**: click its badge and pick one. It applies to that tone in every
part of the song, is saved in your [presets](#presets) and switches at once if the tone is playing.
Changed tones show a pencil and what they'd be automatically; ↺ puts them back to automatic.

**Settings** (gear icon):
- what to send: Program Change 0–3 or 4–7 for Clean, Crunch, Heavy, Lead, or your own number per
  category; the MIDI channel;
- how early to switch, to cover the time your gear needs (the game picks it up within a second);
- the Rocksmith folder, install / update / uninstall;
- stream overlays (below);
- open at login (install the app in /Applications first).

### Stream overlays (RockSniffer compatible)

For streaming with OBS, RS Companion can stand in for
[RockSniffer](https://github.com/kokolihapihvi/RockSniffer) (Windows only): turn on **Serve
overlays** in Settings. The app then:

- serves RockSniffer's overlay pages ("addons": current song, timeline, note streaks, accuracy
  chart, vocals, arcade, song logger, ...), bundled with the app, at
  `http://127.0.0.1:9938/addons/`. Add one to OBS as a **Browser** source; **Overlay pages for
  OBS** in Settings copies their URLs;
- answers RockSniffer's addon API on the same port, so addons written for RockSniffer work as
  they are;
- writes RockSniffer's text files to the data folder's `output/` for OBS **Text** sources
  (`song_details.txt`, `album_details.txt`, `song_timer.txt`, `notes.txt`, `accuracy.txt`,
  `streaks.txt`) and `album_cover.jpeg` for an **Image** source (**Show Text Files**).

The notes, streaks and accuracy come from the game's own statistics (Learn a Song and Score
Attack), song and arrangement details from the song's files. When it's off, nothing listens and
the game doesn't look for the statistics.

Not like RockSniffer: no Discord status, no custom text formats (`output.json`), and new songs
aren't added to the game while it runs. Its states "song starting" and "song ending" are
inferred, and the game stage is only reported at the song review. Multiplayer isn't supported.
Overlays that tell songs apart by `psarcFileHash` (song logger) see different values than on
Windows, because the Mac archives are different files.

The overlay pages and everything this mode reports are RockSniffer's design: thanks to
kokolihapihvi and RockSniffer's contributors (see [Credits](#credits)).

## External mode (rstone.py)

Reads the game from outside, without changing it, and reports tone changes as JSON lines on
stdout, optionally UDP, and in a live web window. No MIDI.

### What you need

- Python 3.10+ (standard library only)
- Command Line Tools, to build `rsprobe` (memory reader) and `rstool` (song file reader):
  `./build.sh`
- Developer Mode, with your user in the `_developer` group (`DevToolsSecurity -status`), so
  `rsprobe` may read another program's memory. No admin rights are needed at run time.

### Run

```bash
./build.sh
python3 rstone.py
```

1. On start it refreshes the song index (first time ~10 s for ~2,400 archives; later only new or
   changed song files are read) and opens the live window at <http://localhost:8765>.
2. It waits for Rocksmith and attaches by itself, also after the game restarts.
3. Pick a song: the window shows **Artist – Song**, the **in-game tone** and the **mapped preset**.

Stop it with Ctrl+C. Options:

| Option | Default | |
|---|---|---|
| `--lead-ms N` | 100 | report tone changes N ms early (covers polling/display; raise it if your gear is slow to switch) |
| `--udp HOST:PORT` | off | also send each event as a JSON UDP datagram |
| `--port N` | 8765 | live window port |
| `--no-open` | | don't open the browser |
| `--no-index-refresh` | | use the song index as is |
| `--log FILE` | data folder | diagnostic log |

Each event is printed as one JSON line, e.g.

```json
{"event": "tone", "song": "18 And Life", "artist": "Skid Row", "arrangement": "skid18an_lead",
 "slot": "B", "tone": "skid18an_dist", "descriptors": ["DISTORTION"], "preset": "Distortion",
 "preset_reason": "tags DISTORTION", "source": "timer", "time": 41.03}
```

`source` tells where the change came from:

- **song-start**: the arrangement's starting tone, as soon as you pick a song;
- **banner**: the game's on-screen tone text; used only until the song timer is locked (normally
  just the first change after starting), up to ~1 s late;
- **timer**: the song timer plus the song file's tone timeline; on time.

It works whether or not RS Companion is installed in the game; running both just detects
everything twice.

## Presets

Your mapping lives in the data folder as `presets.json` (created from
[presets.default.json](presets.default.json) on first run). RS Companion and rstone share it and
re-read it while running. First match wins:

1. `songs`: per arrangement and slot, e.g. `{"skid18an_lead": {"C": "Heavy"}}` (the app's
   changes go here)
2. `tones`: per tone key, e.g. `{"skid18an_dist": "Crunch"}`
3. `rules`: by the game's tone tags (CLEAN, DISTORTION, LEAD, OVERDRIVE, ACOUSTIC, BASS, ...), the
   tone's amp and its gain setting, and then by words in the tone's name
4. `default`

Then `artists` can change what the rules gave for a whole band, e.g.
`{"Bon Jovi": {"Heavy": "Crunch"}}` (overrides from 1 and 2 still win).

RS Companion reads preset names as categories: Clean, Crunch, Heavy and Lead directly, others
through `categories` (Distortion → Heavy, Acoustic → Clean, Bass → Clean, Bass Drive → Crunch).

### How tones are mapped

**New songs need no setup.** Every Rocksmith tone carries tags describing its sound (the same
ones the game's tone banner shows, e.g. "Clean Chorus"). RS Companion's in-game library reads
them from the song's own archive when you load it, so a song you have never played, official or
custom, is mapped by the rules straight away. (External mode finds new songs by refreshing its
song index at startup, and again when a song isn't in it.)

**Rules** are checked top to bottom; the first that matches wins. A rule has a `preset` and:

- `any`: matches if the tone has at least one of these tags;
- `all`: every one of these tags is required for the rule to be considered (combine it with
  `any`, e.g. `{"preset": "Bass Drive", "all": ["BASS"], "any": ["DISTORTION", "FUZZ"]}`);
- `name`: matches if one of these words is a whole word in the tone key (`skid18an_dist` has
  the words `skid`, `an`, `dist`), or, for words of 4+ letters, appears anywhere in it;
- `amp`: required: the tone's amp is one of these (`"HG500"` or `"Amp_HG500"`; the amp keys are
  in `tone_catalog.csv`);
- `gain`: required: the amp's gain knob (0–100, as set in the tone) is at least this.

A rule matches when all its required conditions hold and, if it has `any` or `name`, one of
those matches too.

Write tags in capitals, as the game does (`"HIGH GAIN"`, not `"high gain"`); tone keys and
`name` words are compared in lower case.

**The default rules**, in order: bass tones with drive tags → Bass Drive; other bass → Bass;
ACOUSTIC → Acoustic; LEAD → Lead; HIGH GAIN → Distortion (Heavy); DISTORTION / FUZZ on a
high-gain amp → Distortion (Heavy); other DISTORTION / FUZZ / OVERDRIVE → Crunch; clean and
effect tags (CLEAN, CHORUS, REVERB, DELAY, ...) → Clean. Only
then the tone's name is tried (`lead`, `solo`, `dist`, `metal`, `crunch`, `od`, `clean`, ...),
and anything left goes to `default` (Clean). Order matters: a tone tagged LEAD + DISTORTION
becomes Lead because the LEAD rule comes first.

**Where it can go wrong:**
- Custom songs sometimes have missing or generic tags; such tones fall back to their name and
  then to Clean.
- Tags describe the kind of sound, not how much gain: a light crunch and a heavy rhythm tone
  are both tagged DISTORTION. The amp rules tell them apart: modern high-gain amps (HG500,
  JVM410H, JCM800, Rockerverb, and CA100, GB50, Tiny Terror, DSL100H above a gain setting) are
  Heavy; amps used for both (GB100, HG100, HG180, CA85, EN50) only with gain 95 or more; vintage
  and low-gain amps (TW, EN30, AT, BT, CA38, Plexi, JTM45, Bluesbreaker, ...) Crunch. Expect
  about one band in four on the wrong side, e.g. Bon Jovi on Heavy or some Metallica on Crunch:
  fix those with `artists`.
- Everything ends up as one of four categories, so close tones share a preset.

**Tuning it:**
- One song wrong: change the tone's category in the window (saved under `songs`).
- The same tone key wrong everywhere: add it under `tones`.
- A whole band wrong: add it under `artists`, mapping what the rules give to what you want,
  e.g. `{"Bon Jovi": {"Heavy": "Crunch"}, "Metallica": {"Crunch": "Heavy"}}`. The keys are a
  preset or category name; the artist is compared as the game shows it, ignoring case.
- The same kind of mistake across many songs: reorder or add `rules` (e.g. move the
  Distortion rule above Lead if you want distorted leads on Heavy). This fixes every song at
  once, and overrides you've set still win.
- To see why a tone got its category, look in `rs-companion-app.log` (or `rstone.log`): each
  tone line ends with the preset and the reason, e.g.
  `→ Heavy (Distortion, tags DISTORTION, amp hg500 gain 88)`; the reason is `song override`,
  `tone override`, `tags ...`, `name` or `default`, with `, artist ...` added when `artists`
  changed it.

## Data folder

Everything generated on your machine is kept in
`~/Library/Application Support/rs-mac-companion/` (override with `RS_COMPANION_DATA`; the game's
library and the app honour it too, which the tests use):

| File | Used by | |
|---|---|---|
| `presets.json` | both | your preset mapping |
| `rscompanion.json` | RS Companion | settings: lead time and overlays (read by the game's library), MIDI, Rocksmith folder |
| `events.sock` | RS Companion | the app's socket; the game's library sends events to it |
| `rscompanion.log` | RS Companion | the game library's log: songs, arrangement, timer, tone events |
| `rscompanion_tags.txt` | RS Companion | memory areas the library learned to scan (delete to relearn) |
| `rs-companion-app.log` | RS Companion | the app's log: songs, tones, mapping, MIDI sent, installs |
| `output/`, `addon_storage/` | RS Companion | stream overlays: text files and album art for OBS; values overlay pages keep |
| `tones_index.jsonl`, `index_cache.json` | external mode | song index and its cache |
| `rstone.log` | external mode | diagnostic log |
| `tone_catalog.csv`, `songs.csv` | developer tools | catalog from `make_catalog.py` |

The game folder defaults to Steam's location; the external mode and the tools take `RS_GAME_DIR`,
RS Companion its Settings.

## When the game updates

See [docs/when-the-game-updates.md](docs/when-the-game-updates.md). For RS Companion it is usually
just clicking Install again after Steam replaced the executable; if the game itself changed, a few
values have to be found again with the discovery tools.

## Developer tools

Build with `./build.sh` (Command Line Tools only): `build/rsprobe`, `build/rstool` and
`build/librscompanion.dylib` (the in-game library, for the tests; the app builds its own copy).

| Tool | |
|---|---|
| `python3 make_catalog.py` | `tone_catalog.csv` (every tone: tags, preset, how it matched, amp, pedals, drive 0–1 with clean / crunch / heavy, its delay, reverb and modulation, how many songs use it) and `songs.csv` (every arrangement with its tuning, tempo, the song's heaviness, its tones, presets and drives), from the song index; the scores come from `rig.py` |
| `build/rstool toc\|tones <archive.psarc>` | list an archive's entries with their byte ranges / print its arrangements' tone data as JSON |
| `python3 tools/event_listener.py` | print the events the game's library sends (quit RS Companion first: only one can listen) |
| `build/midi_monitor` | print MIDI from the "Rocksmith Companion" source (`swiftc -O tools/midi_monitor.swift -o build/midi_monitor`) |
| `tools/add_load_dylib.py` | add a library load to an executable by hand (the app's installer does the same) |
| `"RS Companion.app/Contents/MacOS/RSCompanion" --game-status \| --install-game \| --uninstall-game [folder]` | the app's installer without its window |
| `tools/discovery/` | investigating the game's memory through `rsprobe` (needs Developer Mode); see [game-memory.md](docs/game-memory.md#12-finding-something-new) |

Tests (none touch your data; they need the game installed, and use the song *Self Trap* that comes
with it):

```bash
./tests/run_dylib_test.sh     # the game library in a stand-in game (~2 min)
./tests/run_app_test.sh       # stand-in → library → app → MIDI (~70 s; quit RS Companion first)
./tests/run_installer_test.sh # the app's installer on a copy of the game executable (seconds)
./tests/run_standin_test.sh   # rstone.py + rsprobe in a stand-in game (~70 s)
```

The stand-ins imitate what the game does: file reads, arrangement objects, a song timer, decoy
clocks and tone banners.

Documentation: [how it works](docs/how-it-works.md), [the game's memory](docs/game-memory.md)
(everything known about reading the running game), [song files](docs/song-files.md),
[when the game updates](docs/when-the-game-updates.md).

## Project layout

| Path | Part of | |
|---|---|---|
| `app/` | RS Companion | the menu-bar app (Swift) and its installer; `app/build.sh` |
| `native/rscompanion.c` | RS Companion | the in-game library: song from file reads, arrangement and timer from memory, events |
| `native/rsfile.c`, `rsfile.h` | both | song file reader (PSARC, SNG tone timeline, manifests) in C |
| `presets.default.json` | both | default tone → preset mapping |
| `third_party/rocksniffer-addons/` | RS Companion | RockSniffer's overlay pages (MIT), served by the app |
| `rstone.py`, `ui.html` | external mode | the companion and its live window |
| `native/rsprobe.c` | external mode | the memory reader |
| `native/rstool.c`, `index_songs.py` | external mode | song file reader front end and the song index |
| `presets.py`, `paths.py`, `game_profile.json` | external mode | mapping, where things live, values tied to one game build |
| `make_catalog.py`, `rig.py`, `tools/`, `tests/` | developer tools | see above; `rig.py` scores what a tone's gear does |
| `docs/` | | documentation |

## Dependencies

None beyond macOS: the in-game library, the app and `rstool` use only system libraries
(CoreMIDI, CommonCrypto, zlib); the Python parts use only the standard library. The app bundles
RockSniffer's overlay pages (below).

## Credits

- **[RockSniffer](https://github.com/kokolihapihvi/RockSniffer)** and
  **[RockSnifferLib](https://github.com/kokolihapihvi/RockSnifferLib)** by kokolihapihvi and
  contributors (MIT), the Windows tool streamers use with Rocksmith 2014. RS Companion's stream
  overlays are built on their work:
  - the overlay pages in `third_party/rocksniffer-addons/` are RockSniffer's own, bundled
    unchanged (MIT, see its [LICENSE](third_party/rocksniffer-addons/LICENSE) and
    [SOURCE.md](third_party/rocksniffer-addons/SOURCE.md));
  - the addon API, its JSON fields, states and modes, the text files and their formats, the
    tuning names and how song details are read from a song's files follow RockSniffer, so its
    addons work unchanged;
  - the note statistics: RockSnifferLib's layouts of the game's note-stats and Score Attack
    objects and their `111000` check value are how they were found in the Mac game
    ([game-memory.md § 8](docs/game-memory.md#8-note-statistics));
  - its reading of the game's `Play_<song>_Preview` sound event to tell the highlighted song led
    to the play record (`Play_<SongKey>`) that syncs the song timer
    ([game-memory.md § 6](docs/game-memory.md#6-the-song-timer)).
- **[Rocksmith2014.NET](https://github.com/iminashi/Rocksmith2014.NET)** by iminashi (MIT): the
  `.sng` record layout in `native/rsfile.c`.

## Limitations

- Tones you switch by hand in the game are not seen; changes come from the song's tone timeline.
- A tone change in the first few seconds of a song, before the song timer is synced, comes from
  the on-screen banner, up to ~1 s late (in external mode: every change until the first banner
  of a game session).
- MIDI is one-way: switching presets on the receiving side isn't seen by the app.
- RS Companion has to be installed into the game again after Steam replaces the game executable
  (the app tells you).
