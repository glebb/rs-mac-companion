# Device profiles

A device profile says what RS Companion sends over MIDI and where. RS Companion knows what
Rocksmith is doing; a profile knows the gear. Adding a device is adding a JSON file, not changing
the app.

Choose one in Settings › MIDI output. **Show Profiles** opens the folder, `profiles/` in the data
folder. A new file there appears in the list, and edits apply within a couple of seconds. If a
file can't be used, Settings says why and the last good version stays in use.

Four come with the app, and are copied to the folder if they're missing, so you can edit them.
To get the app's current version of one, delete the file and restart the app.

| Profile | For |
|---|---|
| `program-changes.json` | Any amp, speaker or app that listens to MIDI: Program Change 0–3 per category, from the virtual source |
| `stagehand.json` | [Bandbox Stagehand](https://github.com/glebb/bandbox-stagehand): song tone messages, and Program Change 8–12 for the song's tones |
| `hx-stomp.json` | A Line 6 HX Stomp, sent straight to it over USB: see [below](#hx-stomp) |
| `hx-stomp-amps.json` | The same with a preset per amp, and the tone's settings by CC: see [the presets](../hx-stomp-presets/README.md#a-preset-per-amp) |

If `rscompanion.json` has no `"profile"` yet, RS Companion turns its older MIDI settings
(`midi_channel`, `programs`, `song_tones`, `song_tone_programs`, `song_tone_first_program`) into a
profile once: one of the above if it sends the same, else a new `migrated.json`. After that those
settings are ignored.

## The file

```json
{
  "name": "HX Stomp",
  "destination": "HX Stomp",
  "channel": 1,
  "song_load": {
    "Soft":  [{"pc": 0}],
    "Metal": [{"pc": 2}],
    "*":     [{"pc": 1}]
  },
  "category": {
    "Clean":  [{"cc": 69, "value": 0}, {"cc": 20, "value": 0}],
    "Lead":   [{"cc": 69, "value": 2}, {"cc": 20, "value": 127}]
  },
  "effects": {"chorus": 21, "flanger": 21, "delay": 24}
}
```

| Key | | |
|---|---|---|
| `name` | required | shown in Settings |
| `comment` | optional | for you; the app ignores it |
| `destination` | default `"virtual"` | `"virtual"` sends from the virtual source **Rocksmith Companion**, for apps that listen to it. Any other text is the name of a MIDI destination, as Audio MIDI Setup shows it: sent straight there |
| `channel` | default 1 | 1–16, for `pc` and `cc` steps |
| `song_load` | optional | a sequence per song style, run as a song loads, about 3.3 s before its audio. `"*"` is any style without its own. Styles are in [presets.json](song-tone-messages.md#styles) |
| `amp_load` | optional | a sequence per game amp (`"Amp_CA100"`, as `tone_catalog.csv` names them), run in place of `song_load`. Of the amps listed, the one the arrangement plays longest counts, amps with the same sequence adding up. A song with none of them uses `song_load` |
| `song_load_again` | default `false` | also run it when the song is described anew: its mapping changed, or an AI answer arrived a few seconds in. Off, a song's load sequence runs once, so a device isn't switched during the song. The catch: a late change of style only applies the next time the song loads |
| `category` | optional | a sequence per category (Clean, Crunch, Heavy, Lead), run when the active tone changes |
| `tone_first_program` | optional | song tone *i* plays on this Program Change + *i*, instead of its category's sequence. The song tone message names these numbers |
| `effects` | optional | effect → CC. After each tone's sequence, every CC listed here goes out: 127 if the tone has that effect, else 0. Kinds: `delay`, `reverb`, `chorus`, `flanger`, `phaser`, `tremolo`, `vibe`. Kinds that share a CC count as one switch |
| `knobs` | optional | CCs that follow the tone's settings: see [Knobs](#knobs) |

Keys are checked: a misspelt one is an error rather than something that silently does nothing.

### Sequences

A sequence is a list of steps, sent in order. A later sequence waits for an earlier one to finish.

| Step | |
|---|---|
| `{"pc": 3}` | Program Change |
| `{"cc": 69, "value": 2}` | Control Change |
| `{"wait_ms": 50}` | a pause, up to 5000 |
| `{"bytes": "F0 7E 7F 06 01 F7"}` | one MIDI message in hex, sent as it is, on the channel it names |
| `{"song_tones_message": true}` | the [song tone message](song-tone-messages.md); use it in `song_load` |

### Knobs

A knob is a CC that follows one of the tone's settings, so a device can do more than switch between
fixed sounds:

```json
"knobs": [
  {"cc": 30, "from": "drive"},
  {"cc": 31, "from": "delay_time", "range": [0, 1000]},
  {"cc": 32, "from": "reverb_mix", "default": 0}
]
```

| Key | | |
|---|---|---|
| `cc` | required | 0–127. Not one used in `effects` or by another knob |
| `from` | required | one of the settings below |
| `range` | default below | the setting's value at CC 0, then at CC 127. Values outside it stop at the end. High to low turns it round |
| `default` | optional | 0–127, sent for a tone without the setting. Without it nothing is sent, and the device keeps the last value |

| `from` | Default range | |
|---|---|---|
| `drive` | 0–1 | how distorted the tone should sound: see below |
| `gain` | 0–100 | the amp's gain knob, as the song sets it |
| `bass`, `mid`, `treble`, `presence` | 0–100 | the amp's knobs. Not every amp has them all |
| `delay_time` | 0–2000 | in ms |
| `delay_mix`, `delay_feedback` | 0–100 | |
| `reverb_mix` | 0–100 | |
| `modulation_mix` | 0–100 | |
| `modulation_rate` | 0–100 | as the pedal has it, which is 0–10 on some |

`drive` takes the amp, its gain and the song's pedals (`drive` in `tone_catalog.csv`), so it means the
same on every amp. The song's AI `gain_offset` lowers it for a distorted tone. It then stays in the
band of the tone's category: Clean up to 1/3, Crunch up to 2/3, Heavy above, and Lead anywhere. So
changing a tone's category also changes its drive. `gain` is the knob as it stands, with none of this.

Knobs go out after the category's steps and before the effect CCs, so an effect comes on already set.
That order matters on an HX Stomp, which loses a CC sent just before a snapshot change.
A tone the song's files don't list has no settings, so only knobs with a `default` go out for it.

### When things are sent

- A tone's messages go out only when they change: many devices drop unsaved edits on a preset
  change, so the same thing is never sent twice in a row. A `song_load` sequence that sends more
  than the song tone message counts as resetting the device, so the first tone goes out anyway.
- Song load sequences, `tone_first_program`, `effects` and `knobs` need the song's gear, read from its
  files. A tone the song's files don't list has its effects off.
- **Pause MIDI** holds everything. On resume, the song's load sequence runs if it was missed, then
  the tone.
- If `destination` isn't connected, the window says so and nothing is sent. When it appears, the
  song load sequence and the current tone go out.

## HX Stomp

`hx-stomp.json` uses a preset per style, a snapshot per category and block on/off by MIDI. Snapshot
changes are seamless and keep delay and reverb tails; preset changes have a gap, so they happen
only while a song loads.

On the Stomp, keep **Global Settings › MIDI/Tempo**: USB MIDI on, MIDI PC Rx on and the same base
channel as the profile. Set **MIDI PC Tx** to Off if Bandbox Stagehand may be running: it listens to
every source and would take the Stomp's Program Changes as tone changes.

[hx-stomp-presets](../hx-stomp-presets/README.md) has three ready-made presets to import with HX Edit.
To make your own, each of the three needs:

| Part | Setup |
|---|---|
| Slot | PC 0, 1, 2 for Soft, Classic rock, Metal. The Play view shows a preset's PC number; change `song_load` to use other slots |
| Snapshots | 1 Clean, 2 Crunch, 3 Heavy, setting the amp's gain and the drive and compressor blocks |
| CC 20 | Controller on the amp's channel volume, for Lead. 0 is normal, 127 the lift |
| CC 21–25 | Bypass by MIDI In: chorus, phaser, tremolo, delay, reverb. Flanger plays on chorus, vibe on phaser |
| Trails | On for delay and reverb, so tails ring out when the block turns off |

Lead has no snapshot of its own: the Stomp has only three, so it's the Heavy snapshot with the CC 20
lift. A snapshot normally recalls every block's on/off state, so the effect CCs always follow it. The
presets in [hx-stomp-presets](../hx-stomp-presets/README.md) go further and turn Snapshot Bypass off on
the five effect blocks, so a snapshot change can't switch one off for a moment before its CC arrives.

The first tone comes right after a song's load sequence, while the Stomp may still be loading the
preset, and CCs sent then can be lost. So each `song_load` ends with `{"wait_ms": 500}`. It's free:
the song's audio is about 3.3 s away.

The Stomp's eight blocks are limited by DSP, and the Amp+Cab block uses the most. If a preset
doesn't fit, leave out a block and its CC; messages for it do nothing.

Rocksmith needs the dry guitar, not the processed sound, and the guitar turned down to zero in its
mixer. On macOS, route USB 5 to a virtual device named **Rocksmith USB Guitar Adapter** with
Loopback or an aggregate device, and keep the Stomp as the default output.

## A new device

Copy a profile, give the file a new name, and change `name`, `destination` and the sequences. To find
a destination's exact name, look in Audio MIDI Setup, or run `build/midi_monitor`. To see what a
profile sends without the gear, run `build/midi_monitor --device "Test"` with
`"destination": "Test"`.
