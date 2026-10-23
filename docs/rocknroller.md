# RockNRoller

RockNRoller (`com.mintricksai.rocknroller`, by Mintricks AI) is a Rocksmith chart player
for macOS: it plays the songs of a Rocksmith library (`songs.psarc`, `dlc/`, Rocksmith 1 packs)
with their audio and note charts, but has no amps or tones of its own. RS Companion follows it as
it follows Rocksmith, so the same presets, Program Changes and song tone messages work while you
play along in RockNRoller.

Found on RockNRoller 0.2.3 (arm64, ad-hoc signed, no hardened runtime).

## How it gets in

Nothing is installed into RockNRoller. RS Companion opens it (**Open RockNRoller**, or **Restart
RockNRoller** if it runs) with `DYLD_INSERT_LIBRARIES` set to its bundled
`librnrcompanion.dylib` and `RS_COMPANION_DATA` to its data folder. The library removes the
variable at once, so programs RockNRoller starts don't load it. Opened another way (Dock, Finder),
RockNRoller runs without it, and RS Companion says so after 5 s.

This works because RockNRoller is not built with the hardened runtime; a version that is would
ignore the variable (and the library would then never load, which RS Companion also shows).

## What the library reads

RockNRoller keeps its symbol table, so everything is found by name with `dlsym`, never by address
([native/rnrcompanion.c](../native/rnrcompanion.c)):

| Name | What it is | Used for |
|---|---|---|
| `play_session_live()` | true while the play screen is open | song on / off |
| `g_chart_session` | starts with the song's archive path: `…/x_m.psarc`, or `…/pack_m.psarc#songkey` for one song of a pack | which song (read from the archive itself) |
| `g_chart_layout` | `{int template; {int source, variant} cell[4]; int ncells}` | which part: the first panel showing one |
| `g_pa`, `play_audio_time_played(&g_pa)` | the song position in seconds (a field read, no locks) | the tone at that time |

The position is song time at any playback speed (measured: 0.50 s/s at 50 %, 1.26 s/s at 125 %),
so tone changes stay on their cues. The library measures the speed from the position each second
and scales the lead time by it, so it stays real time.

A panel's `source`: 1 Lead, 2 Rhythm, 3 Bass, 4 Lyrics, 5 Combo, −1 empty; 10 + 3 × kind + n is
the nth bonus part of a kind (0 Lead, 1 Rhythm, 2 Bass, 3 Combo). The library maps them to the
song's arrangements the way RockNRoller assigns them (`rnr_arr_kind_from_path`,
`rnr_arr_parse_manifest`, `rnr_arr_assign`):

- **kind**: the manifest's `ArrangementName`, else the file name's last word without its digits
  (`x_combo2` → Combo). The path flags (`pathLead` …) don't count, so in Rocksmith 1 packs the
  `combo1`–`combo3` parts are Combo and LEAD is `x_lead`;
- **main part** of a kind: not `bonusArr`, `represent` first, then by name;
- **bonus slots**: the kind's other arrangements, bonus ones first, each group by name.

With several panels, the first one that shows a part is followed; lyrics-only falls back to the
song's lead, then rhythm, then bass.

## Events

The same as from Rocksmith ([how-it-works.md](how-it-works.md#events-dylib--app)), with
`"game": "rocknroller"` in each heartbeat; `timer_locked` is true whenever a part is followed.
There are no `stats` events (RockNRoller keeps no note statistics), so stream overlays show the
song and tone only. The library logs to `DATA_DIR/rnrcompanion.log`.

## When RockNRoller updates

If a name is renamed or removed, the log says `RockNRoller's <name> not found` and the library
stays idle (RS Companion then shows RockNRoller as running without the companion). Find the new
name with `nm -gU /Applications/RockNRoller.app/Contents/MacOS/RockNRoller`, update `bind_names()`
and this table. If `g_chart_layout` changes shape, panels map to the wrong part: check it with
lldb (`x/10wx &g_chart_layout`) against the panel headers. `tests/run_rnr_test.sh` runs the
library against a stand-in that exports the same names.
