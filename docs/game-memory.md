# Reading Rocksmith 2014's memory (macOS)

Everything this project knows about the running game: what is where in memory, how to find it,
how to read it safely, what the game does with its files, and what did not work. Written so it
can be reused for other features (or other tools) without re-doing the investigation.

All of it was found by reading **data** only. The game's code section is encrypted on disk (copy
protection) and was never decrypted, disassembled or patched; nothing here depends on it.

Measured on Rocksmith 2014 Remastered, Steam, macOS, the build described in
[game_profile.json](../game_profile.json) (x86_64 slice, running under Rosetta on an Apple Silicon
Mac), with a library of ~2,400 song archives (official DLC and custom songs). Numbers (sizes,
times) are from that setup and will differ somewhat elsewhere.

Contents:
1. [The process](#1-the-process)
2. [Two ways in: from outside, from inside](#2-two-ways-in-from-outside-from-inside)
3. [Scanning memory](#3-scanning-memory)
4. [Strings: the 32-byte small-buffer string](#4-strings-the-32-byte-small-buffer-string)
5. [Arrangement description objects (which song and part)](#5-arrangement-description-objects)
6. [The song timer](#6-the-song-timer)
7. [Tone banners](#7-tone-banners)
8. [Note statistics (hits, streaks, score)](#8-note-statistics)
9. [Where things live: memory tags](#9-where-things-live-memory-tags)
10. [What the game does with its files](#10-what-the-game-does-with-its-files)
11. [What did not work](#11-what-did-not-work)
12. [Finding something new](#12-finding-something-new)
13. [Ideas not explored yet](#13-ideas-not-explored-yet)

## 1. The process

| Fact | Detail |
|---|---|
| Executable | `Rocksmith2014.app/Contents/MacOS/Rocksmith2014`, a universal **i386 + x86_64** Mach-O. On Apple Silicon the x86_64 slice runs under **Rosetta**; anything loaded into the game must be x86_64. |
| Signature | **Not code signed**, no hardened runtime. That is what lets another process read it (`task_for_pid`) and lets it load an extra library. |
| Image base | `__TEXT` at `0x100000000` unslid. ASLR adds a **slide** (multiples of 0x1000; seen 0x64a000 … 0x4dea000). Every address in this document is **unslid**: add the slide. |
| Slide | In-process: `_dyld_get_image_vmaddr_slide(i)` for the image with `filetype == MH_EXECUTE`. From outside: scan pages from `0x100000000` for the Mach-O magic `0xFEEDFACF` with `filetype == 2` (`find_slide()` in `rstone.py`); slide = address − `0x100000000`. |
| Code | `__TEXT,__text` is **encrypted on disk** (static analysis shows noise); strings and data are readable. |
| Libraries | Loads `libsteam_api.dylib`, `libBink2Macx64.dylib`, Cg, system frameworks, and, in a custom-song (CDLC) setup, `libRSBypass.dylib` via an extra `LC_LOAD_DYLIB` with an absolute path. This project adds `librscompanion.dylib` the same way (`@executable_path/librscompanion.dylib`; the app's installer, [how-it-works.md](how-it-works.md#installing-into-the-game)). |
| libRSBypass | The usual CDLC signature-check bypass: an ObjC `+load` that pattern-scans the game's (by then decrypted) code and patches it with `mprotect`. Shows that an extra library loaded by a load command survives the game's startup checks. |
| Memory | ~1.0–1.2 GB resident while playing; ~2.5 GB of readable+writable, non-executable regions. |
| Header space | The x86_64 slice has 1,648 bytes free between the load commands and the first section: room for ~20 more `LC_LOAD_DYLIB` entries ([tools/add_load_dylib.py](../tools/add_load_dylib.py)). |

## 2. Two ways in: from outside, from inside

| | From outside (`rsprobe`) | From inside (`librscompanion` dylib) |
|---|---|---|
| Code | [native/rsprobe.c](../native/rsprobe.c), driven by [rstone.py](../rstone.py) | [native/rscompanion.c](../native/rscompanion.c) |
| Access | `task_for_pid` + `mach_vm_read_overwrite` on the game's task | `mach_vm_read_overwrite` on **our own** task (`mach_task_self()`) |
| Needs | the `com.apple.security.cs.debugger` entitlement and Developer Mode / `_developer` group (or an admin prompt) | the game patched to load the dylib (Section 1); no permissions at all |
| Cost | every byte is copied across processes (~2.5 GB per full scan, 1–2 s) | same copy but in-process (~0.8–1.2 s full, ~0.2 s narrow) |
| Risk | none to the game | a crash in the dylib crashes the game: keep it defensive |
| Game files | separate reader (`index_songs.py` + `rstool`) | sees the game's own file reads (Section 10) |

Why `mach_vm_read_overwrite` even in-process: the game frees and unmaps memory while we scan. A
plain pointer dereference into a page unmapped a moment ago would crash the game; the Mach call
returns an error instead. Every read in the dylib goes through `safe_read()`.

## 3. Scanning memory

Both readers enumerate regions with `mach_vm_region` and scan only regions that are **readable
and writable and not executable** (data, never code), in 1 MB chunks copied into a buffer.

The dylib uses `VM_REGION_EXTENDED_INFO`, which also gives each region's **user tag** (what kind
of memory it is, Section 9) and resident/swapped page counts. It skips:

- regions with no resident or swapped pages (reserved but never touched),
- **its own memory**, so it never finds copies of what it searches for:
  - its working buffers, allocated with `mmap(… VM_MAKE_TAG(250) …)` (tag 250 is in the
    application range 240–255) and skipped by tag,
  - its own image (`__DATA` etc., located with `dladdr` on one of its functions),
  - thread stacks (tag `VM_MEMORY_STACK` = 30), since log lines and search patterns pass
    through them,
- and it writes its log unbuffered (`setvbuf(_IONBF)`) so no log text sits in a heap buffer.

Searches are 8-byte-aligned word compares (pointers, doubles) or `memmem` (text). A pattern that
straddles a 1 MB chunk boundary is missed; with values repeated in several copies this has not
mattered.

Costs measured on that setup: full scan ~2.5 GB in 0.8–1.2 s (in-process); narrow scan (tags
2 + 7) ~390–500 MB in 0.17–0.26 s.

## 4. Strings: the 32-byte small-buffer string

The game's strings (arrangement names, tone keys, sound bank names) are 32-byte objects:

```
+0x00  union { char buf[16]; char *ptr; }
+0x10  char *end      // one past the last character
+0x18  char *cap
```

- **Inline** (text shorter than 16 bytes): `end` points into the field itself
  (`addr <= end <= addr + 16`); the text starts at `addr`.
- **Heap**: otherwise the first word is the pointer to the text; length = `end − ptr`.

Reading: `read_sso()` in `rscompanion.c`, `sso()` in `rstone.py`. Treat lengths ≥ 256 as garbage.

## 5. Arrangement description objects

The game keeps one object per arrangement (Lead, Rhythm, Bass, Combo, Vocals, …) of the loaded
song. Its type pointer (vtable) identifies it:

| Offset | Content |
|---|---|
| `+0x000` | type pointer = **`0x1017F8C20`** + slide (into `__DATA,__const`) |
| `+0x018` | arrangement name, e.g. `skid18an_lead` (string, Section 4) |
| `+0x158` | sound bank, e.g. `song_skid18an.bnk` |
| `+0x178 + i·0x20` | tone keys for slots Base, A, B, C, D (i = 0..4; empty string if unused) |

**Which arrangement is selected**: the selected one's object exists **twice** (the game keeps a
working copy). Find all 8-byte words equal to the type pointer, read each name, and take the name
that appears twice. For *18 And Life* this finds 7 objects: its 6 arrangements plus the copy.

Caveats:
- The copy **stays after leaving the song**, so it is "last selected", not "selected now". The
  dylib therefore only accepts a duplicate whose name starts with the key of the song the game
  has just loaded (`<songkey>_…`, Section 10); a stale pair from the previous song is ignored.
- RS1-compatibility songs have a `*_combo` arrangement; picking "Lead" selects
  `boysdontcry_combo`, not `boysdontcry_lead` (same tone data).
- The objects are in memory tagged 2 and 7 (Section 9).
- The name is also the key into the song files: `songs/bin/macos/<name>.sng` and
  `manifests/…/<name>.json` (see [song-files.md](song-files.md)).

## 6. The song timer

The position in the playing song, which with the song file's tone timeline tells the active tone.

| Fact | Detail |
|---|---|
| Type | **double, seconds** (a float search never finds it) |
| Where | a heap object (tag 2) that lives for the **whole game session**: the same address for every song. Once found, keep it until it is unreadable or the game restarts. |
| Behavior | advances only while a song plays; stops when paused, including when Rocksmith loses focus; restarts near 0 for each song (and jumps back to 0 when leaving a song). |
| Decoys | menu and animation clocks also tick at 1 s/s; some reset every few seconds and can be smaller than the song timer. Never guess: confirm (below). |

**Finding candidates (rate search)**:
1. Snapshot every 8-byte-aligned double in [0.5, 1000] with the time it was read
   (~185,000 values in the game's tag-2/7 memory).
2. Three times, one second apart, keep values that advanced at 0.97–1.03 s per second, each
   compared against **its own** read time (a pass over hundreds of thousands of values takes long
   enough to skew a shared timestamp).
3. ~16–21 candidates survive per round while a song plays. Pool them (up to 64).

**Confirming which candidate is the song timer**: at a tone change the game shows a banner
(Section 7). For each pool candidate, `value_now − (now − banner_seen) − change_time` is how far
it is from the song position at the banner; the song timer gives a small lag (the scan delay). The
dylib accepts −0.5…+5.0 s (rstone −0.5…+3.5 s) and takes the candidate with the smallest lag.
Measured lags 0.2–3.1 s (higher on the first session, when scans are still full).

**Verifying later**: when a banner appears for a confirmed timer, the timer's tone at
`value − 0…5 s` must be the banner's tone; if not, drop it and search again.

**Use**: tone = slot active at `timer + lead` per the song's timeline, checked every 50 ms.
Reported changes came 73–90 ms before the song file's change time with a 100 ms lead.

Other forms tried (`rsprobe` "groups" 0 and 1: float seconds, int32 ms, float/double ms) never
held the song timer; they remain in `rsprobe` as a fallback for a future game build.

## 7. Tone banners

At each tone change the game creates the on-screen text **`"<SongName> - <Tags>"`**:

- `SongName` exactly as in the manifest (`SongName`), e.g. `18 And Life`, `Boys Don't Cry`.
- `Tags` = the tone's `ToneDescriptors` without their `$[id]` prefix, title-cased, joined with a
  space: CLEAN + CHORUS → `Clean Chorus`; DISTORTION → `Distortion`.
- Each change creates **new copies** (usually 3) of the string; older copies linger until the
  memory is reused, so only **addresses not seen before** count as new banners. Note the
  addresses present when a song starts and ignore them.
- Found in memory tagged 2 (Section 9). They come from the game's `LASToneChangeNotification`
  UI notification.
- A banner can be found up to ~1 s after the change (scan interval + scan time).

Matching a banner to a tone slot (`banner_matches()`): the banner's words equal the tone's tag
words (order-insensitive), or the text equals one tag, or the text appears in the tone key.

Banners are the only event that comes from the game itself rather than from a timeline, so they
also catch tone changes a timeline would miss, but they are late and need a search. Use them to
confirm the timer, then rely on the timer. To keep scanning cheap once confirmed, the dylib only
looks for banners just after each expected change (0.3–3 s after it) and every 15 s.

## 8. Note statistics

The game counts hits, misses and streaks in two typed objects, the same ones RockSniffer
([kokolihapihvi/RockSnifferLib](https://github.com/kokolihapihvi/RockSnifferLib),
`LearnASongNoteData` / `ScoreAttackNoteData`) reads on Windows. Its pointer chains don't carry
over, but its struct layouts do: the fields come in the same order, shifted because pointers are
8 bytes here. Both objects hold the int32 **`111000`** at `+0x0C` (RockSniffer's validity check,
`+0x08` on Windows), which is how they were found: snapshot every 111000 in memory every 3 s
while playing, and compare.

Both are **created when a song starts and freed when it is left**; at the menu neither exists.
After freeing, the 111000 lingers in the freed memory for a while: find the objects by **type
pointer** (`findptr`), never by the marker alone. All int32.

**Note stats** (Learn a Song **and** Score Attack), type pointer **`0x1017F92C0`** + slide:

| Offset | Content | Windows |
|---|---|---|
| `+0x00` | type pointer | `+0x00` |
| `+0x0C` | `111000` | `+0x08` |
| `+0x40` | notes hit | `+0x30` |
| `+0x44` | current hit streak | `+0x34` |
| `+0x48` | unknown (1 in every song seen) | `+0x38` |
| `+0x4C` | highest hit streak | `+0x3C` |
| `+0x50` | notes missed | `+0x40` |
| `+0x54` | current miss streak | `+0x44` |
| `+0x5C` | notes hit (again) | |

Accuracy = hit / (hit + missed), as RockSniffer computes it. Seen in three songs (two Learn a
Song, one Score Attack), found by type pointer in two of them: hits rose while playing cleanly,
the streak fell to 0–2 while missing on purpose and the highest streak held, misses rose only
while missing. Further counters at `+0x140…+0x160` grew slowly (phrase or section statistics?);
not identified.

**Score Attack stats** (only in Score Attack, alongside the note stats), type pointer
**`0x10180A388`** + slide:

| Offset | Content | Windows | Seen at the end |
|---|---|---|---|
| `+0x00` | type pointer | `+0x00` | |
| `+0x0C` | `111000` | `+0x08` | |
| `+0x58` / `+0x5C` | current hit / miss streak | `+0x3C` / `+0x40` | 36 / 0 |
| `+0x60` / `+0x64` | highest hit / miss streak | `+0x44` / `+0x48` | 38 / 4 |
| `+0x68` / `+0x6C` | notes hit / missed | `+0x4C` / `+0x50` | 239 / 38 |
| `+0x70` / `+0x74` | current hit / miss streak (again) | `+0x54` / `+0x58` | |
| `+0x90` / `+0x94` | current perfect-hit streak / perfect hits | `+0x74` / `+0x78` | 0 / 57 |
| `+0x98` / `+0x9C` | current late-hit streak / late hits | `+0x7C` / `+0x80` | 1 / 8 |
| `+0xA0…+0xAC` | perfect, good, passed, failed phrases | `+0x84…+0x90` | 3, 6, 0, 1 |
| `+0xB0…+0xBC` | current phrase streaks (same order) | `+0x94…+0xA0` | 2, 0, 0, 0 |
| `+0xC0…+0xCC` | highest phrase streaks (same order) | `+0xA4…+0xB0` | 2, 5, 0, 1 |
| `+0x118` | score | `+0xE4` | 80,856 |
| `+0x11C` / `+0x120` | current / highest multiplier | `+0xE8` / `+0xEC` | 8 / 8 |

The hit/miss fields matched the note stats object at every snapshot. The phrase counts add up to
10, which also appears at `+0x148` and `+0x1D8`. Seen in one Score Attack song, found by the
marker (the type pointer was read from that object afterwards, not yet searched for); the perfect,
late, phrase and score fields follow RockSniffer's layout and give plausible values, but were not
compared with the screen. RockSniffer's arrangement path string (`+0x1D0`) was not looked for.

## 9. Where things live: memory tags

`mach_vm_region` reports a **user tag** per region (`<mach/vm_statistics.h>`). Measured:

| What | Tag(s) |
|---|---|
| arrangement objects | **2** (`VM_MEMORY_MALLOC_SMALL`), **7** (`VM_MEMORY_MALLOC_TINY`) |
| song timer | **2** |
| tone banners | **2** |

Scanning only tags 2 + 7 is ~400–500 MB instead of ~2.5 GB, 4–5× faster. The dylib does not
hard-code these: each search starts with full scans, learns the tags of what it finds, saves them
(`rscompanion_tags.txt` in the data folder) and from then on scans only those, with a full scan
every 5th try (every 10th banner scan until the timer is confirmed) in case something moved.

## 10. What the game does with its files

Seen by interposing the libc file calls inside the game (Section 2; `my_fopen`, `my_fread` … in
`rscompanion.c`). The game uses **`fopen` + `fseeko` + `fread`** (64 KB reads), not `mmap` or
`pread`.

| When | What the game does |
|---|---|
| Launch | Opens and keeps open the base archives: `cache.psarc`, `audio.psarc`, `songs.psarc` (the on-disc songs), `static.psarc`, `gears.psarc`, `guitars.psarc`, `video.psarc`, venues, `base/*.psarc`, … |
| ~0–2 min after launch | **Scans every DLC archive** (all ~2,400), opening each about 12 times; reads the header + table of contents (offset 0, 64 KB), the last 6 bytes (`appid.appid`) and the catalog entries. In this phase "a DLC file was opened" says nothing about the song being played. |
| Browsing songs | Short bursts of reads on the highlighted song's archive (previews). |
| **Loading a song** | Reads the song's `song_<key>.bnk`, **every arrangement's `.sng`** (`songs/bin/macos/<key>_<arrangement>.sng`) and `<key>_showlights.xml` from its archive, **~3.3 s before the audio starts**. |
| Playing | Opens the archive again on a new descriptor for the audio (`audio/mac/<id>.wem`) and **holds it open for the whole song**; closes it when the song ends or is left. |

So the song being loaded is identified exactly by the first read whose offset falls in a
`.sng` entry (map offsets to entries with the archive's table of contents:
`build/rstool toc <archive>`). This works for single-song DLC, packs (the RS1 compatibility
pack holds ~150 songs in one file; a custom pack held 586 arrangements) and `songs.psarc` alike.
The reads are 64 KB, so one read can overlap the next song's entries; use the entry that contains
the read's **start** offset. Which arrangement is played is not in the reads (all are read
together): that comes from memory (Section 5).

The DLC startup scan reads no `.sng` entries, so it never triggers a false song detection.

## 11. What did not work

| Tried | Result |
|---|---|
| Static analysis of the executable to find the tone-change code | The code section is encrypted on disk; only data is readable. |
| Loading a helper library with `DYLD_INSERT_LIBRARIES` | Steam can't set environment variables in launch options ("OS Error 260"); via a wrapper script it loaded, but the game crashed in its startup checks. A load command in the executable (like libRSBypass) works. |
| A pointer chain from a global to a "current tone slot" integer | Found an int that tracked the slot within one session, in a generic list; after a game restart neither the chain nor the list held. |
| Song timer as a float | It's a double. |
| Picking the "smallest ticking value" as the song timer | Menu/animation clocks reset often and can be smaller; replaced by banner confirmation. |
| Reading the selected arrangement every 5–10 s | Works, but costs ~12% of a core; re-checking only when the game loads a song is enough. |
| A song reader without size limits on a corrupt custom song | An earlier reader allocated until the Mac ran out of memory. `rsfile.c` caps sizes taken from files (64 MB). |

## 12. Finding something new

The discovery tools work against the game from outside through `rsprobe`, so the investigation
never risks the game. Start the reader (Developer Mode needed), then use the tools:

```bash
build/rsprobe $(pgrep -x Rocksmith2014) &
cd tools/discovery
```

| Tool | Use |
|---|---|
| `probe.py <command>` | raw `rsprobe` commands: `read`, `findstr`, `findhex`, `findptr` (who points here?), `findrange` (who points into this range?), `snapi`/`filteri`/`icands` (int snapshots: keep values that changed / stayed / moved by n), `snapt`/`ratet`/`tlist` (timer search) |
| `ctx.py <text>` | every copy of a text with printable context around it |
| `dump.py <hexaddr> [len]` | memory as 8-byte words and text |
| `find_arrangement_layout.py <arrangement>` | re-derives the arrangement object's type pointer and offsets (after a game update) |
| `findtimer.py [group]` | values ticking at 1 s/s, printed live (play a song) |
| `ptrchain.py <target> <lo> <hi>` | pointer chains from static data to an address |

Typical method:
1. **Find a value you can see**: a text from the screen (`ctx.py`), a number you can change in
   the game (snapshots with `snapi`/`filteri`, changing it between steps), a clock (`findtimer.py`).
2. **Find the object around it**: `dump.py` the area; look for a type pointer (a value in the
   game's `__DATA,__const`, `0x1017…` + slide) at the start of the object.
3. **Find it again reliably**: search for the type pointer (`findptr`) instead of the value, as
   the arrangement objects are found. Check after a game restart: addresses change, type pointers
   and offsets do not.
4. **Write the values down** in [game_profile.json](../game_profile.json) (and the `#define`s at
   the top of `rscompanion.c`) and in this document.

To try a finding inside the game, add it to the dylib and test it first against the stand-in
([tests/standin_dylib.c](../tests/standin_dylib.c), `tests/run_dylib_test.sh`), which imitates
the game's file reads, arrangement objects, timer, decoy clocks and banners.

## 13. Ideas not explored yet

- **Tones switched by hand** in the game are not seen (the timeline doesn't know them). The
  banner appears for those too, so a banner that disagrees with the timeline at a moment with no
  timeline change could be reported as a manual switch.
- **Pause / end of song**: the timer stops when paused and jumps to 0 when the song is left;
  both could become events (e.g. "song stopped").
- **The active tone slot directly**: the per-session int from Section 11 might be reachable
  from the arrangement object or another typed object; search for its address near objects
  found by type pointer (step 3 above) rather than from globals.
- **Section, riff repeater state**: likely in typed objects like the arrangement and note stats
  objects (Section 8); the method in Section 12 applies.
- **More of RockSniffer's values**: its game stage string (which screen the game is on) and its
  `Play_<songid>_Preview` sound event text (the highlighted song) are plain text; `ctx.py` finds
  them.
- **The game's audio position** (Wwise) as a second timer source.
