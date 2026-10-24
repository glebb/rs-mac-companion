# Song tone messages

With **Describe each song's tones** on (Settings › Song tone messages, `"song_tones": true` in
`rscompanion.json`), RS Companion tells MIDI listeners about a song's tones as it loads, so a
tool can prepare a sound for each one. It then plays those sounds with Program Changes during
the song. The message describes the tones in Rocksmith's own terms and makes no assumptions
about the receiving device: each receiver maps it to its own gear.
[Bandbox Stagehand](https://github.com/glebb/bandbox-stagehand) is one receiver, for the JBL
BandBox Trio. The format is meant to be just as usable by a modeller, a DAW script, a plugin
host or a logger.

The setting is off by default. With it off, RS Companion sends only the category Program
Changes, as described in the [README](../README.md#use).

## On the wire

- **Source:** the virtual MIDI source **Rocksmith Companion**. SysEx has no channel. The Program
  Changes go on the channel set in Settings.
- **Message:** one System Exclusive message. Its first byte after F0 is `0x7D`, the
  manufacturer ID set aside for non-commercial use, and the rest is JSON text (UTF-8, with
  anything outside 7-bit ASCII written as `\u` escapes, so every byte is under 0x80).
  It's sent as MIDI 1.0 UMP SysEx7 packets, 6 bytes each. A typical message is 300–600 bytes.
- **Telling it apart:** check for `0x7D`, then that the JSON has `"kind": "song-tones"`, then
  check `"v"`. Ignore any other kind or version.
- **The first second after RS Companion starts:** everything it sends in that second is held
  and then sent in order. That gives a listener time to connect to the new source when
  RS Companion starts while a song is already loaded.

## When it's sent

- **When an arrangement loads.** RS Companion reads the song's files about 3.3 s before its
  audio starts ([game-memory.md](game-memory.md)), and the message follows within
  milliseconds. A receiver has that much time to get ready. The first tone's Program Change
  comes right after the message, so a receiver should either handle it once it's ready or
  play a fallback until then.
- **Again for the same song** when the mapping in `presets.json` changes (a tone's category
  can change), when the first program changes, or when RS Companion starts while a song is
  loaded.

## Version 2

For example (the effect values are illustrative):

```json
{"v": 2, "kind": "song-tones",
 "song": "18 And Life", "artist": "Skid Row", "arrangement": "skid18an_lead",
 "heaviness": 0.72, "tempo": 92.4, "low_string": 0,
 "style": "Classic rock", "styles": ["Soft", "Classic rock", "Metal"],
 "tones": [
   {"program": 8, "key": "skid18an_clean", "category": "Clean",
    "effects": {"modulation": {"kind": "chorus", "gear": "Pedal_Chorus", "mix": 60, "rate": 2.5},
                "reverb": {"gear": "Rack_StudioVerb", "mix": 25}}},
   {"program": 9, "key": "skid18an_dist", "category": "Heavy", "effects": {}},
   {"program": 10, "key": "skid18an_lead", "category": "Lead",
    "effects": {"delay": {"kind": "analog", "gear": "Pedal_AnalogueDelay",
                          "time_ms": 316, "mix": 25, "feedback": 30}}}
 ]}
```

### The song

| Field | | |
|---|---|---|
| `song`, `artist` | text | as the game shows them |
| `arrangement` | text | the part being played, e.g. `skid18an_lead` |
| `heaviness` | 0–1, may be missing | how heavy the song is: the drive of the tone its rhythm part (else combo, else lead) plays longest, plus 0.1 when the low string is tuned to C or lower. The same score as `songs.csv` |
| `tempo` | beats per minute, may be missing | the arrangement's average tempo, e.g. for a delay with no time of its own |
| `low_string` | semitones, may be missing | the low string's tuning relative to E standard, with its cent offset (−2 = D standard or drop D) |
| `style` | text | a label for the song, picked from its heaviness (see [Styles](#styles)) |
| `styles` | list of text | every label a song can get, so a receiver can prepare for each in advance |

### The tones

`tones` lists up to five tones (an arrangement's Base and A–D), in the order the song first
plays them, so the first one is needed first.

| Field | | |
|---|---|---|
| `program` | 0–127 | the Program Change that plays this tone during the song |
| `key` | text | Rocksmith's name for the tone, e.g. `skid18an_dist` |
| `category` | Clean, Crunch, Heavy or Lead | what RS Companion maps the tone to (`presets.json`, overrides included). It's the same category the tone gets when it plays |
| `effects` | object | the tone's time-based and modulation effects, as below. An effect that's missing means the tone doesn't have one |

`effects` describes what the song's gear has, with Rocksmith's knob values: no caps, no
conversions. If a tone has more than one effect of a kind, the one with the most mix is used.

| Effect | Fields |
|---|---|
| `delay` | `kind`: `tape`, `analog`, `modulated` or `digital`; `gear` (the Rocksmith pedal or rack, e.g. `Pedal_TapeEcho`); `time_ms`, `mix` (0–100) and `feedback` (0–100), each when the gear has it |
| `modulation` | `kind`: `chorus`, `flanger`, `phaser`, `tremolo` or `vibe`; `gear`; `mix` and `rate` when the gear has them |
| `reverb` | `gear`; `mix` when the gear has it |

Amp, cabinet and drive settings aren't included. They're tuned to Rocksmith's own amp models
and don't carry over to other gear well; the `category` (and the `style`) tell a receiver how
driven the tone should be.

### Program Changes

During the song, tone *i* plays on Program Change `program` (by default 8 + *i*, so 8–12).
Settings › Song tone messages sets the first number. As always, a Program Change is sent only
when the program changes.

With **Play them with Program Changes** off (`"song_tone_programs": false`), the message is
still sent, but the four category Program Changes go on as usual. Use that when the message
is only for information (a logger, a display), or when the device that receives the Program
Changes doesn't know about song tones.

### Styles

`style` is a label for the song, set in `presets.json`:

```json
"styles": [{"name": "Soft"}, {"name": "Classic rock", "from": 0.4}, {"name": "Metal", "from": 0.75}],
"song_styles": {"AC/DC": "Classic rock", "skid18an": "Metal"}
```

The label is the last entry in `styles` whose `from` the song's heaviness reaches. A song key
or an artist listed in `song_styles` gets the label named there (the song key is checked
first), then one listed in the `song_styles` of `ai_suggestions.json`, the AI suggestions
from `classify_songs.py`. Without these sections, the labels and thresholds are the ones shown above. The
labels mean nothing to RS Companion itself: a receiver decides what to do with them. Stagehand
uses the label as the name of a set of four tones (a bank).

(`banks`/`song_banks`, the names these sections had at first, are still read.)

## Version 1

The first version was written for Stagehand alone. It named the BandBox's models and knobs
(`"set": {"FX": {"model": "Chorus", "Mix": 35}}`), a `base` slot per tone and a `bank`.
RS Companion now sends version 2 only. Stagehand still reads both.

## Receiving it

1. Connect to the source **Rocksmith Companion** (or to every source).
2. Put the SysEx back together from its packets. Each UMP SysEx7 packet carries up to 6 bytes
   and is marked complete, start, continue or end.
3. Check for `0x7D` and parse the rest as JSON. Ignore the message unless `kind` is
   `song-tones` and you know its `v`.
4. Prepare a sound per tone, then map each tone's `program` to it. Until a sound is ready,
   play something close, such as a preset for its `category`.

To watch the messages without a receiver, run `build/midi_monitor`
(`swiftc -O tools/midi_monitor.swift -o build/midi_monitor`). `tests/run_song_tones_test.sh`
checks the message end to end with a stand-in game. The code is in `app/Sources/SongTones.swift`.
