# When the game updates

Background for all of this: [game-memory.md](game-memory.md) (what is where in memory and how it
was found) and [song-files.md](song-files.md).

## With the in-game dylib (RS Companion)

**Steam replaced the executable** (an update, "Verify integrity of game files", a reinstall):
the load command for the library is gone. RS Companion notices and says *Not installed in
Rocksmith. Steam may have updated the game.*: quit Rocksmith and click **Install**. It backs up the
new executable (replacing the old `Rocksmith2014.orig`) and patches it. Also re-apply the CDLC
patch if you use custom songs (a separate load command for `libRSBypass.dylib`; the order of the
two doesn't matter).

**The game itself changed** (detection stops working although the dylib loads): the values are the
same as below, but the dylib has its own copy of them as `#define`s at the top of
[native/rscompanion.c](../native/rscompanion.c) (`IMAGE_BASE`, `ARRANGEMENT_VTABLE`, `ARR_NAME`).
Find the new values with the steps below (they use `rsprobe` from outside, which needs Developer
Mode), put them in both `game_profile.json` and `rscompanion.c`, rebuild the app
(`app/build.sh`) and click **Update** in it. What the dylib log says, step by step:

| Step below | Dylib log line when it works |
|---|---|
| 2. song detected | `song <key> loaded by the game from …` and `selected arrangement <name>` |
| 3. timer | `timer search (…): … ticking, +N candidates` |
| 4. banners | `banner seen: "<Tags>"` and `song timer is the double at …` |
| 5. song files | per arrangement `<name>: Base=… changes: …` after the song line |

If the game's memory layout changed, also delete `rscompanion_tags.txt` from the data folder, so
the dylib learns again where its data lives (it falls back to full scans regularly anyway).

`tests/run_dylib_test.sh` must still pass after any change to the dylib (it runs against a
stand-in, not the game).

## With rstone.py

Rocksmith 2014 hasn't been updated in years, but Steam, macOS or a reinstall can still change the
executable. rstone hashes it at start and compares with `executable_sha256` in
[game_profile.json](../game_profile.json). If they differ, the live window and `rstone.log` show:

> Rocksmith's executable has changed since game_profile.json was made.

A different hash doesn't always mean breakage (re-applying the CDLC patch, or the dylib patch, changes
the file too).
Work through the checks below in order; each says what to fix if it fails.

Before you start: `./build.sh`, then `./tests/run_standin_test.sh` should print `PASS`. If it
doesn't, the problem is in this project or your tools, not the game.

For the manual checks, start the reader yourself (stop rstone first):

```bash
build/rsprobe $(pgrep -x Rocksmith2014) &
cd tools/discovery
```

### 1. Does rstone attach?

Log: `attached to Rocksmith pid …` and `image slide 0x…`.

- **`cannot attach` / task_for_pid fails**: the game may now be signed with the hardened runtime,
  which blocks other processes from reading it. Check with
  `codesign -dv --verbose …/Rocksmith2014.app` (look for `flags=0x10000(runtime)`). Also check
  Developer Mode and `DevToolsSecurity -status`. Re-sign rsprobe with `./build.sh`.
- **`image not found`**: the executable no longer loads near `0x100000000` (for example a native
  arm64 build with a different layout). Look at `vmmap <pid> | head -40` for the `__TEXT` of
  `Rocksmith2014` and adjust `image_base`.

### 2. Is the selected song detected?

Log: `arrangement <name> slots [...]` within ~5 s of picking a song.

If not, the arrangement object moved. Select a song in the game (the song's menu is enough), find
its arrangement name in `songs.csv` (column `arrangement`, e.g. `skid18an_lead`), then:

```bash
python3 find_arrangement_layout.py skid18an_lead
```

It finds the name and the tone keys in memory, the object around them, and prints new
`arrangement_*` values, most likely layout first. The first one should show two objects (the
selected arrangement and its copy) and about as many objects of that type as the song has
arrangements. Put the values into `game_profile.json`, update `executable_sha256`
(`shasum -a 256 <executable>`), restart rstone.

If it finds nothing: the strings may no longer be 32-byte small-buffer strings. Look manually:

```bash
python3 ctx.py skid18an_lead              # where the name is, with surrounding text
python3 dump.py <hexaddr> 512             # the memory around it, as 8-byte words
python3 probe.py findptr <hexaddr>        # who points at an address
```

If the selected arrangement no longer appears twice, `current_arrangement()` in `rstone.py`
needs another way to tell which one is selected.

The `note_stats_*` and `score_attack_*` values are not used by rstone or the dylib yet. To
re-derive them, play a song and look for the int32 111000 (`probe.py findhex 98b10100`): the
type pointer is the 8-byte word 0xC before it ([game-memory.md § 8](game-memory.md#8-note-statistics)).

### 3. Is the song timer found?

Log, while a song plays: `timer candidates +N`, and at the first tone change
`banner '…': song timer is f64@…`.

If no candidates appear, play a song (Rocksmith in front, not paused) and run:

```bash
python3 findtimer.py 2     # doubles in seconds (current game)
python3 findtimer.py 0     # floats in seconds, ints in milliseconds
python3 findtimer.py 1     # floats/doubles in milliseconds
```

The song timer is the value that matches the song position, restarts near 0 for a new song and
stops when paused. If it's in another form, extend `snap_timers()` / `tread()` in
`native/rsprobe.c` and `TIMER_FORMATS` / `GROUP_ORDER` in `rstone.py`.

### 4. Are banners seen?

Log: `banner seen: '<Song> - <Tone>'` at tone changes. Without them the timer can't be confirmed
and the first change of a session isn't reported.

```bash
python3 ctx.py "18 And Life - "     # during or after a tone change in that song
```

If the text format changed (separator, order, casing), update `BannerWatch` and
`banner_matches()` in `rstone.py`.

### 5. Do song files still read?

`index_songs.py` reports `FAILED` archives. Many failures mean the archive or SNG format or
encryption changed: fix it in `native/rsfile.c` (see [song-files.md](song-files.md)), rebuild,
and delete `index_cache.json` in the data folder to re-read everything. The in-game library uses
the same reader.

### Last resort: find the tone slot by snapshots

The game also keeps the active tone slot as a small integer (A/B/C = 1/2/3 in the session where
it was found; Base presumably 0), but not at a stable place. To find it in a running session, pause on a known
tone each time:

```bash
python3 probe.py snapi 1 2          # paused on a tone in slot B (value 2) or A (value 1)
python3 probe.py filteri s 0        # still paused: drop anything that changes
# play on to another tone and pause; keep values that moved by the slot difference:
python3 probe.py filteri d 1        # e.g. B -> C
python3 probe.py icands 50
```

Then `ptrchain.py <address> <data-lo> <data-hi>` looks for pointer chains from the game's global
data to it. Check any chain after restarting the game; last time none survived.
