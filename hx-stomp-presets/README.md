# HX Stomp presets for RS Companion

Three presets for `profiles/hx-stomp.json`: Soft (01A), Classic Rock (01B), Metal (01C). They were
built for firmware 3.80 and HX Edit 3.82. The settings are starting points from Line 6's own data and
forum reports. They have since been played on a real Stomp through RS Companion and sounded right; see
[Not verified](#not-verified) for what that listening test didn't check.

## Import

1. In HX Edit, select **01A** in the Presets panel and use **Import Preset**. Confirm the overwrite
   and pick `Soft.hlx`.
2. Do the same with `Classic Rock.hlx` into **01B** and `Metal.hlx` into **01C**.
3. Check one preset in the **Bypass/Controller Assign** tab. It should list MIDI In 21–25 on chorus,
   phaser, tremolo, delay and reverb, MIDI In 20 on Ch Vol and MIDI In 38 on the drive block's Gain.
   If those rows are missing, see [Not verified](#not-verified).

On the Stomp, keep USB MIDI on, MIDI PC Rx on and base channel 1 (see `docs/device-profiles.md`).

## The presets

The chain is the same in all three: Input gate, Compressor, Drive, Amp+Cab, Phaser, Tremolo, Chorus,
Delay, Reverb, Output. Phaser and tremolo are mono. Chorus and delay are stereo, and everything after
the first stereo block stays stereo, so nothing collapses to mono.

Values are as shown in HX Edit. Ch Vol is the snapshot level with CC 20 at 0, then at 127, and the drive
block's Gain is with CC 38 at 0, then at 127.

| | Soft | Classic Rock | Metal |
|---|---|---|---|
| Amp | US Deluxe Nrm | Brit 2203 | Cali IV Lead |
| Cab | 1x12 US Deluxe, 57 Dynamic | 4x12 Greenback 25, 57 Dynamic | 4x12 Cali V30, 57 Dynamic |
| Cab low/high cut | 80 Hz / 9 kHz | 80 Hz / 9 kHz | 90 Hz / 8 kHz |
| Master | 10 | 5 | 5 |
| Ch Vol (CC 20) | 7.0 → 8.05 | 4.5 → 5.17 | 7.0 → 8.05 |
| Output block | 0 dB | -3 dB | -3 dB |
| Input gate | -70 dB, 0.15 decay | -60 dB, 0.10 decay | -50 dB, 0.05 decay |
| Drive block | Teemah!: Gain 3.0 → 6.5, Level 5.8 | Minotaur: Gain 2.0 → 6.5, Level 6.5 | Scream 808: Gain 1.0 → 4.5, Level 7.0 |
| Compressor | Deluxe Comp, 70% mix | same | same |
| Phaser | Script Mod Phase | same | same |
| Tremolo | Optical Trem | same | same |
| Chorus | Chorus, stereo, 40% mix | 35% mix | 30% mix |
| Delay | Simple Delay, stereo, 400 ms, 30% feedback, 20% mix | 28%, 18% | 25%, 14% |
| Reverb | Plate, decay 4.0, 22% mix | Plate, decay 3.5, 18% mix | Room, decay 3.5, 15% mix |

**What each snapshot changes.** Bass, Mid, Treble and Presence also change, and the exact values are
in the files. Cab level is the level trim.

| Preset | Snapshot | Amp gain | Compressor | Drive | Cab level |
|---|---|---|---|---|---|
| Soft | 1 Clean | Drive 3.0 | on | off | +2 dB |
| | 2 Crunch | Drive 5.0 | on | off | 0 dB |
| | 3 Heavy | Drive 6.2 | off | on | -2 dB |
| Classic Rock | 1 Clean | Drive 1.8 | on | off | +4.5 dB |
| | 2 Crunch | Drive 5.0 | off | off | +2 dB |
| | 3 Heavy | Drive 7.0 | off | on | -0.5 dB |
| Metal | 1 Clean | Lead Gain 1.2, Lead Drive 2.0 | on | off | +5 dB |
| | 2 Crunch | Lead Gain 4.5, Lead Drive 4.5 | off | off | +2 dB |
| | 3 Heavy | Lead Gain 7.2, Lead Drive 6.0 | off | on | +0.5 dB |

Lead is snapshot 3 with CC 20 and CC 38 at 127, and a delay if the song's lead has none of its own (see
[Lead](#lead)). A clean lead, whose drive is in the clean band, is snapshot 1 with CC 20 at 127 and no delay. Chorus, phaser, tremolo, delay and reverb are off in every
snapshot and belong to MIDI alone. Their **Snapshot Bypass** is off, so a snapshot change doesn't
switch them off for the moment before their CC arrives. Delay and reverb have Trails on.

## Why these models

- **US Deluxe Nrm** (Fender Deluxe Reverb) is a light amp at 22.22 units that goes from clean to
  breakup. A forum report says it stops being clean past about 40% Drive, so Clean sits at 3.0.
  A30 Fawn Nrm is lighter (19.3) if you want a brighter, chimier base.
- **Brit 2203** (JCM800) was chosen over Brit 2204, which forum users found hard to clean up. The 2203
  is described as sparkling on clean settings while still delivering dirt. It is the heaviest amp here.
- **Cali IV Lead** (Mark IV lead channel) is reported by one forum user to cover clean, crunch and
  lead in one amp. In the forum threads found, Cali Rectifire and PV Panama drew more complaints about
  tightness. This rests on a few users' opinions, so it is the least certain amp choice.
- **Drives** double as the boost, since there is no boost block. A Line 6 support reply recommends
  Teemah! for edge of breakup, a forum user picks Minotaur as a classic-rock boost, and low gain with
  high level on Scream 808 is the usual way to tighten a high-gain amp.
- **Effects** are the light, plain models. Deluxe Comp is the lightest compressor and appears in 24
  factory Stomp presets. Plate and Room are among the cheapest reverbs, and low mix values keep them
  neutral across songs. Delay is fixed at 400 ms because the song's tempo isn't available to it.
- **Cabs** use the factory IR-based models at 2.5 units each, against 7.2 for the older cabs.

## Levels

Nothing could be measured at first, so the levels are reasoned. They sounded right in the first test
on a real Stomp. After more playing, every preset was a little loud, so each output block went down
3 dB (8 November 2026), the presets per amp too.

- **One controller per parameter.** Ch Vol belongs to CC 20, so snapshots can't also set it. Snapshot
  levels are trimmed with the cab's Level in dB, which factory Stomp presets also do (DIR:TexasJS,
  DIR:Seared GuyJS).
- **Between presets.** Each amp starts from Line 6's own settings: DIR:Relief for US Deluxe Nrm
  (Ch Vol 7.1, Output +3 dB), DIR:Brit 2203 for Brit 2203 (Ch Vol 4.8), and the catalog default for
  Cali IV Lead (Ch Vol 8.8). This assumes Line 6 balanced those presets against each other.
- **Between snapshots.** Line 6's snapshot presets lower Ch Vol as gain rises: DIR:The DocterGD goes
  7.0, 5.0, 4.5 as Drive goes 2.0, 6.2, 10. Read as linear amplitude, that is about 3 dB from clean to
  crunch and 1 dB to 1.5 dB from crunch to heavy. The trims follow that, with a little more taken off
  Heavy in Soft and Classic Rock, where the drive block adds level.
- **Lead lift.** Every preset raises Ch Vol by a factor of 1.15, which is +1.2 dB if Ch Vol is
  linear. That taper is inferred: those same factory presets only make sense if it is near linear,
  but no source states it. The first lift, 1.41 or +3 dB, was too loud on a Stomp.

**To check by ear:** with one steady strum, compare snapshots against Classic Rock Crunch. Change Cab
Level per snapshot and the Output block per preset, and leave Ch Vol alone. If Lead is too much or too
little, change the Max of Ch Vol's MIDI In assignment. For more or less gain on Lead, change the Max
of the drive block Gain's.

## DSP

**This is an estimate, not a measurement.** It adds up the `load` figures in HX Edit's model files,
using the stereo figure for stereo blocks.

| Preset | Load | Spare, against 75.0 |
|---|---|---|
| Soft | 53.99 | 21.01 |
| Classic Rock | 62.77 | 12.23 |
| Metal | 59.22 | 15.78 |

- TonePush measured a Helix Floor path at exactly 75.0 of these units. It did not measure the Stomp.
- Summed the same way, the 126 factory Stomp presets reach a maximum of 75.0 (DIR:Feedbacker). Those
  presets must fit, so the Stomp's budget is at least about 75.0. 32 of them are at or above Classic
  Rock's total, including 8-block presets at 74.55.
- Bypassed blocks still count, and these totals include them.

**If a preset doesn't fit**, for example if the import fails or a block is refused, save DSP in this
order:

1. Classic Rock only: swap Minotaur for Scream 808 (saves 3.05).
2. Make Chorus mono (saves 2.11), then Simple Delay mono (saves 1.23).
3. Remove Tremolo (1.71), then Phaser (2.30). RS Companion's messages for a missing block do nothing.

## Not verified

The presets were played on a real Stomp through RS Companion and sounded right (5 November 2026).
That was a listening test, so the points below weren't checked one by one.

- **The two MIDI forms came from HX Edit's code, not from a real file.** They have since worked on a
  Stomp, in the [presets per amp](#a-preset-per-amp):
  - MIDI-only bypass: `"@fs_index": 19` with `"@cc": N` in `footswitch`. The nearest real file has
    `@cc` alongside a real footswitch index.
  - Ch Vol on CC 20: `"@controller": 8` with `"@cc": 20` in `controller`.

  If the rows from step 3 are missing, set them by hand in the Bypass/Controller Assign tab using the
  tables above. Everything else in the preset still applies.
- **Snapshot Bypass off** is `@no_snapshot_bypass: true`. Line 6's guide documents the option, but no
  factory preset uses it. To go back, turn Snapshot Bypass on for the five blocks; the CCs still
  decide the state.
- **The Stomp's DSP budget** is inferred from factory presets.
- **Metal's Clean** is the weakest tone, since it comes from a lead channel turned down. No factory
  Stomp preset uses Cali IV Lead, so its level has no factory anchor.
- **Ch Vol's taper** is inferred, so the +1.2 dB lead lift is too.
- **CC 38**, the lead push on the drive block of the presets by style, is new (8 November 2026) and
  hasn't been played on a Stomp. Its amount is a guess on Soft and Metal.
- **The presets per amp as they are now** (8 November 2026) haven't been played on a Stomp: the input
  stage, the Swedish Chainsaw and CCs 39–44 are new. See [A preset per amp](#a-preset-per-amp).
- **Timing after a preset change.** A forum thread warns that CCs sent right after a Program Change
  can be lost while a unit loads a preset (reported on an HX One), so `profiles/hx-stomp.json` waits
  500 ms after each `pc` step. If the first tone of a song is wrong, raise that wait.

## A preset per amp

`amps/` has one preset per Helix amp, for the profile **HX Stomp by amp**. The song's amp picks the preset,
and each tone is set by MIDI the way [rs-tonehost](https://github.com/glebb/rearmed-mods) sets it in Helix
Native, which plays the game's tones closely: the same amp and cab, driven as hard, with the same stand-ins
for the song's drive pedals, and the same level for every tone. `tools/make_stomp_presets.py` makes them from
`amps.json` and `calibration.json`, with Line 6's defaults read from the HX Edit install.

Import each file into the slot its name starts with, as above. This overwrites what's in those slots, so
export your presets first. All 35 fit, at 67.81 DSP at most, by the same estimate as above.

The chain, in order:

| Block | Plays | |
|---|---|---|
| Deluxe Comp | the amp's input | with its threshold at 0 dB it never compresses a guitar: only its Level counts, as tonehost's Master Input. Measured in Native, it leaves the level alone to 0.01 dB |
| Swedish Chainsaw | a distortion, metal or fuzz pedal | tonehost's metal pedal; fuzzes play here too |
| Minotaur | a boost or overdrive pedal | tonehost's drive pedal, at its default Level |
| Amp and cab | the amp | Line 6's defaults, and the cab at its defaults, as tonehost has them |
| Phaser, Chorus, Delay, Reverb | the song's effects | as above. The tremolo made room for the Chainsaw: 1.6% of the game's guitar tones use one, 6.3% a distortion, metal or fuzz pedal |

| CC | Sets | Range |
|---|---|---|
| 20 | Ch Vol, for Lead | ×1.15, about +1.2 dB |
| 21, 22, 24, 25 | Bypass: chorus, phaser, delay, reverb | |
| 26 | The amp's Drive, from the game's gain knob | 0–9.3, or 0–6 on Cali Rectifire, Das Benzin Mega, Mandarin Rocker and Solo Lead OD |
| 27–30 | Bass, Mid, Treble, Presence | full range. An amp without one ignores it |
| 31, 33, 34 | Delay time, feedback, mix | 0–2 s, full range |
| 35, 36 | Reverb mix, chorus mix | full range |
| 37 | The cab's Level: the tone's level | -60 to +6 dB, from a formula per amp: see below |
| 39 | The input, from the game's gain knob | -8 dB, up 28 dB to gain 100, or 39.5 dB with a boost pedal; 18 dB on the four amps above |
| 40, 41, 42 | The Minotaur: bypass, Gain, Tone | from the boost pedal's gain (×0.98) and tone |
| 43, 44 | The Chainsaw: bypass, Drive | from the pedal's gain (×0.98) |

CC 32 is left out: it's MIDI's Bank Select, and Helix Native picks a setlist with it. CC 23 and CC 38 do
nothing on these presets. The three snapshots play alike, as tonehost has no categories: a tone's category
changes only a lead, which gets CC 20's lift, and a delay if it's a crunch or heavy one (see [Lead](#lead)).

### How hard

tonehost raises the guitar 6 dB, then the amp's input by its Master Input: -14 dB at gain 0, up 28 dB to gain
100, or 39.5 dB when the tone has a boost pedal, and 18 dB on the four amps with gain enough of their own. The
Stomp's guitar isn't raised first, so its input stage starts at -8 dB and climbs the same way. The amp's Drive
is the gain times 0.93, or 0.6 on those four. That runs the amps far harder than these presets did before:
measured on 728 of the game's guitar tones, the distortion of a crunch tone is a median 38 dB past where the
amp starts to compress, and a heavy one's 44, where the presets aimed at 5 and 15.

The tone's drive and category play no part in this. Big City Nights' Bluesbreaker at gain 73 with a
SuperDrive, which came out clean before, now gets its input raised 20.8 dB, Drive 6.8 and the Minotaur, as
in tonehost.

### Level

tonehost plays its probe, a low plucked string, through each tone as it loads, and sets the tone's output so
that every tone comes out alike. Across those 728 tones that undoes a spread of 17 dB (the middle 80%). The
Stomp can't measure, so RS Companion sets the cab's Level from a formula per amp, in the profile's
`amp_knobs` ([Sums](../docs/device-profiles.md#sums)): the tone's gain through the amp's measured curve, a
term for a boost and for a distortion pedal, and one per tone knob.

`tools/calibrate_stomp.py` measures the formulas in Helix Native, offline, through tonehost's saved states
set as the Stomp plays a tone (`tools/measure_helix.m`): each amp at 11 gains, alone and with each pedal, and
each tone knob at both ends. The Stomp has the same models, and Native needs no guitar. Run it again after a
change of amps or of tonehost's rules, then `tools/make_stomp_presets.py`.

Checked on 672 guitar tones from a library, picked at random: each measured in Native as the Stomp plays it
through its own amp's preset, with the formula worked out as RS Companion does it, to the CC step. The
middle 80% come out within -1.5 to +1.1 dB of the target, the middle half within -0.7 to +0.3 dB. 42 tones
(6%) are off by more than 3 dB, 29 of them clean tones at a gain under 20, mostly with the tone knobs near 0,
where the knobs together take away more than the sum the formula has. The worst is 23 dB too quiet: Islands'
clean tone, at gain 1 with Bass, Mid and Treble at 1. These are computed from Native, not measured on a Stomp.

The distortion is tonehost's by construction for the amp, its input, the gain, the tone knobs and a boost
pedal. It differs for a fuzz, which the Chainsaw plays, and where tonehost has a compressor, octave, wah or
acoustic emulator.

**What it leaves out:**

- tonehost's compressor, octaves, wah, acoustic emulator, flanger and tremolo aren't on the Stomp, so tones
  with them sound different, and the formula doesn't count them.
- A tone knob's effect depends on how hard the amp is driven, and the formula takes its average: it misses
  by 2 to 3 dB on most amps at a knob's end, and up to 8 dB on bass amps such as Agua Sledge. The probe is a
  low note, which hears the Bass knob more than a guitar does; tonehost has the same bias.
- At gain 0 some amps fall nearly silent (Brit 2203 measures 93 dB down). tonehost raises them all the way;
  the Stomp can raise a tone by 26 dB at most (the output block's +20 and the cab's +6), so those stay quieter.
- Ch Vol is taken as linear on amps whose default it had to lower for the lead lift.

### Lead

A lead plays as any tone of its amp does, with two additions:

- **A little louder.** CC 20 raises Ch Vol by 1.15, about +1.2 dB if Ch Vol is linear. The first lift,
  1.41, was too loud on a Stomp.
- **A delay** when the song's lead tone has none of its own, which is most of them (`add_delay` in the
  profile, [docs/device-profiles.md](../docs/device-profiles.md#an-added-delay)): a dotted eighth of the
  song's tempo, mix 20% and feedback 20%, the commonest settings of the game's own lead delays. Only for a
  crunch or heavy lead: a clean one, such as the intro of Losing My Religion, gets none. The presets by style
  have no delay knobs, so there it plays as the preset has it, 400 ms.

On the presets by style, a lead is the Heavy snapshot with the drive pedal pushed by CC 38, and a clean lead
the Clean snapshot, lifted.

An arrangement's amp is the one it plays longest. Its other amps play through that preset, so about a
quarter of arrangements lose an amp for part of the song. DI amps, used for acoustic parts, never pick
the preset. A song with no preset for its amp uses the preset of its style.

**Checked on a Stomp (7 November 2026, firmware as in HX Edit 3.82):** the three presets imported and
loaded with every block, and HX Edit lists all their MIDI rows, so the two MIDI forms under
[Not verified](#not-verified) work. CCs sent to the Stomp set the amp, delay and reverb exactly as the
table says, with the song load's Program Change, 500 ms wait and a 17-message burst. This was read from
HX Edit, not heard.

**The order matters.** A CC sent just before a snapshot change, in the same burst, is lost. After the
change it arrives. So keep the `category` steps first in a tone's messages, as the app does.

**Heard on a Stomp:** a jump from clean to heavy by CC, with a guitar through 02A, sounded smooth. 


## Sources

Local files:

- Real files: `Factory_HxStomp.hls` and the other factory sets in Helix Native, your own
  `JazzPlacater.hlx`, and TonePush's `DIR_Relief.hlx` export.
- HX Edit 3.82: `HelixModelDefs.bin`, the `.models` files, the Pilot's Guide, and a static read of the
  program itself.
- TonePush: `PROTOCOL.md`.

Web:

- [Model inspirations list](https://www.guitarchalk.com/line-6-helix-effects-list/)
- [One amp for clean, crunch and lead](https://line6.com/support/topic/67998-preset-with-34-snapshots-for-clean-crunch-lead-sounds-which-amp)
- [High-gain model feedback](https://line6.com/support/topic/28200-high-gain-amp-model-feedback/)
- [Amps that won't clean up](https://line6.com/support/topic/50537-amps-won%E2%80%99t-clean-up-on-helix/)
- [Patch normalization methods](https://line6.com/support/topic/23132-patch-normalization-methods-and-guidelines/)
- [CCs after a Program Change](https://line6.com/support/topic/68228-hx-one-feedbacker-controlled-via-midi-and-momentary)
