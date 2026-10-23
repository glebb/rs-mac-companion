# Song-tones plan: song-made tones on the JBL BandBox

The companion today sends one of four Program Changes (Clean, Crunch, Heavy, Lead) and Stagehand
([bandbox-stagehand](https://github.com/glebb/bandbox-stagehand)) switches the speaker to the
tone in that slot. This plan makes the tones fit each song: while a song loads, the
companion has Stagehand fill five **scratch tones** on the speaker and save them, then switches
between them during the song with a Program Change, as now.

## Decisions

- **Scratch tones, saved at load.** Five user tones in Stagehand, the
  scratch tones, are written only by the companion. They are filled and saved when a song loads, so a tone
  change during the song is one Program Change. The player's own tones are never changed.
  (Not chosen: re-sending tweaks after every switch, which costs writes in the middle of a song;
  saving into the player's tones, which carries one song's sound into the next.)
- **Banks in Stagehand.** A bank is a named set of the four tone slots (the word floor
  multi-effects use for a set of 4 patches; "rig" here means a Rocksmith tone's gear). With one
  bank Stagehand looks as it did; the footer names the bank once there are more. CC 90 picks a
  bank by its value, so PC 0–3 / 4–7 keep their meaning. Hand-made banks ("Soft", "Classic
  rock", "Metal") are the starting points the scratch tones are built from.
- **Template + song details.** Each scratch tone starts as a copy of a tone slot in a hand-made bank
  (picked by the song's heaviness and tuning, and the tone's category), then takes what the
  song's tone does: delay on/off with a time from the song's tempo, reverb amount, chorus /
  phaser / flanger / tremolo. Rocksmith's amp settings are tuned to Rocksmith's amp models, so
  they are not copied knob for knob.
- **Levels come from the templates.** The player sets each template tone's level by ear (Lead a
  little louder). A scratch tone never changes the template's gate, compressor, distortion, amp
  or cab, models or knobs: Volume means something different on each amp model, and Drive
  changes the level too. So the level stays the template's, the same in every song. How
  distorted a song is comes from which template it gets (its bank and category), not from
  turning knobs. The song details change only time and modulation effects, whose level change
  is small; delay and reverb Mix are capped (about 35) so a wet tone doesn't swell. Banks are
  levelled against each other once, by ear, like the tones inside a bank.
- **Who decides what.** The companion knows Rocksmith: it decides the bank, the template per
  tone and the details. Stagehand knows the speaker: it turns that into model changes, knob
  sets and saves, writing only what differs from the template.
- **One wire: MIDI.** Both apps already share it. The load message is a SysEx (non-commercial ID
  0x7D, then a JSON text, which is 7-bit clean), so no new connection is needed and Stagehand
  keeps working with any other MIDI source.

## The load message

```json
{"v": 1, "song": "18 And Life", "bank": "Classic rock", "banks": ["Soft", "Classic rock", "Metal"],
 "tones": [
   {"base": "Clean", "set": {"FX": {"model": "Chorus", "Mix": 40}, "Reverb": {"Mix": 30}}},
   {"base": "Heavy", "set": {"Delay": {"on": false}}},
   {"base": "Lead",  "set": {"Delay": {"on": true, "Time": 316, "Mix": 25}}}
 ]}
```

`tones[i]` becomes scratch tone *i*; during the song PC 8 + *i* plays
it. Order = order of first use in the song, so the tone needed first is written first. Only
FX, Delay and Reverb may be set; Stagehand refuses anything else, which keeps the template's
level. Names are Stagehand's (the JBL app's) model and knob names.

## Timing

The game reads the song files ~3.3 s before the audio starts
([game-memory.md](docs/game-memory.md)); that is the budget. Rocksmith's first tone plays at
0 s, the next change usually comes much later, so the first scratch tone has to be ready at
once and the rest can follow. If the message cannot be acted on in time (Stagehand not running,
speaker away), the companion falls back to the template bank's own four slots.

An arrangement has at most five distinct tones (slots Base and A–D; 31 of 8,065 in the test
library use all five, the Base tone then playing only until the first change), so there are
**five scratch tones** and every song tone gets its own. They are picked with **PC 8–12**:
PC 0–3 and 4–7 are already the two channels' tone slots, and the scratch tones need no
slots (Stagehand shows the playing tone's name). The template banks keep four slots.

## Steps

1. **Companion: the whole rig in the index** (this repo). rstool writes every gear item's knob
   values, the tuning, cent offset and average tempo; index format 3.
2. **Companion: heaviness score and effect details** per tone and per song, shown in the
   catalog to check the thresholds against a real library.
3. **Stagehand: probe the speaker** (done 2026-10-22/23, `ScratchProbe.app`; details in
   Stagehand's protocol-notes.md). Any tone can be read without switching to it, but **edits
   always go to the playing tone** (heard), and saving into another tone copies the playing
   tone there with its edits and name. So a scratch tone is filled audibly but simply: select
   its template slot, send only the song's pedal changes, save into the scratch tone, rename
   it, drop the template's edits. No full copies: ~0.5 s per tone (a write ~60 ms, select and
   save ~50 ms each), all five within the 3.3 s load, before the song's audio. The channel
   jumps between template slots while the song loads. Save as also switches the channel to
   the new tone. 69 user tones fit, but the tone library reply breaks above ~60, so five
   scratch tones are fine.
4. **Stagehand: banks** (done 2026-10-23). Named sets of the four slots per channel, made
   from the slots as they are under *Banks* in the footer; CC 90 picks one by value. A song's
   tones use the bank its message names. The message also lists every bank presets.json can
   name ("banks", "song_banks"), and Stagehand makes the missing ones as copies of Main for the
   player to set up.
5. **Stagehand: the scratch tones** (done 2026-10-23: `ScratchFiller.swift`). Five scratch
   tones "RS 1"–"RS 5", made on first use; per song tone: select the template slot, write the
   changes, save into the scratch tone, rename, discard. Three tones with effects filled in
   1.7 s (11 writes), heard right, the slots unchanged. PC 8–12 play them, or their slots
   until filled. Templates come from the bank the message names (step 4).
6. **Companion: send the load message** (done: `app/Sources/SongTones.swift`, setting "song_tones") at song load, then PC 8–12 for the scratch tones; per
   artist / per song bank overrides in presets.json ("song_banks").
