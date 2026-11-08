# HX Stomp presets for RS Companion

Three presets for `profiles/hx-stomp.json`: Soft (01A), Classic Rock (01B), Metal (01C). They were
built for firmware 3.80 and HX Edit 3.82. **None of this has been on a real Stomp yet, and nothing
here has been heard.** The settings are starting points from Line 6's own data and forum reports.

## Import

1. In HX Edit, select **01A** in the Presets panel and use **Import Preset**. Confirm the overwrite
   and pick `Soft.hlx`.
2. Do the same with `Classic Rock.hlx` into **01B** and `Metal.hlx` into **01C**.
3. Check one preset in the **Bypass/Controller Assign** tab. It should list MIDI In 21–25 on chorus,
   phaser, tremolo, delay and reverb, and MIDI In 20 on Ch Vol. If those rows are missing, see
   [Not verified](#not-verified).

On the Stomp, keep USB MIDI on, MIDI PC Rx on and base channel 1 (see `docs/device-profiles.md`).

## The presets

The chain is the same in all three: Input gate, Compressor, Drive, Amp+Cab, Phaser, Tremolo, Chorus,
Delay, Reverb, Output. Phaser and tremolo are mono. Chorus and delay are stereo, and everything after
the first stereo block stays stereo, so nothing collapses to mono.

Values are as shown in HX Edit. Ch Vol is the snapshot level with CC 20 at 0, then at 127.

| | Soft | Classic Rock | Metal |
|---|---|---|---|
| Amp | US Deluxe Nrm | Brit 2203 | Cali IV Lead |
| Cab | 1x12 US Deluxe, 57 Dynamic | 4x12 Greenback 25, 57 Dynamic | 4x12 Cali V30, 57 Dynamic |
| Cab low/high cut | 80 Hz / 9 kHz | 80 Hz / 9 kHz | 90 Hz / 8 kHz |
| Master | 10 | 5 | 5 |
| Ch Vol (CC 20) | 7.0 → 9.9 | 4.5 → 6.4 | 7.0 → 9.9 |
| Output block | +3 dB | 0 dB | 0 dB |
| Input gate | -70 dB, 0.15 decay | -60 dB, 0.10 decay | -50 dB, 0.05 decay |
| Drive block | Teemah!: Gain 3.0, Level 5.8 | Minotaur: Gain 2.0, Level 6.5 | Scream 808: Gain 1.0, Level 7.0 |
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

Lead is snapshot 3 with CC 20 at 127. Chorus, phaser, tremolo, delay and reverb are off in every
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

Nothing could be measured, so the levels are reasoned. They sounded right in the first test on a
real Stomp.

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
- **Lead lift.** Every preset raises Ch Vol by a factor of about 1.41, which is +3 dB if Ch Vol is
  linear. That figure is inferred: those same factory presets only make sense if it is near linear,
  but no source states the taper.

**To check by ear:** with one steady strum, compare snapshots against Classic Rock Crunch. Change Cab
Level per snapshot and the Output block per preset, and leave Ch Vol alone. If Lead is too much or too
little, change the Max of Ch Vol's MIDI In assignment.

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
- **Ch Vol's taper** is inferred, so the +3 dB lead lift is too.
- **Timing after a preset change.** A forum thread warns that CCs sent right after a Program Change
  can be lost while a unit loads a preset (reported on an HX One), so `profiles/hx-stomp.json` waits
  500 ms after each `pc` step. If the first tone of a song is wrong, raise that wait.

## A preset per amp

`amps/` has one preset per Helix amp, for the profile **HX Stomp by amp**. The song's amp picks the
preset, and the tone's settings arrive by MIDI, so a song plays closer to its Rocksmith tone than the
three presets above can. `tools/make_stomp_presets.py` makes them from `amps.json`, with Line 6's
defaults read from the HX Edit install.

Import each file into the slot its name starts with, as above. This overwrites what's in those slots,
so export your presets first. The chain is Classic Rock's with another amp and its default cab. All 35
fit, at 64.02 DSP at most, by the same estimate as above.

| CC | Sets | Range |
|---|---|---|
| 20 | Ch Vol, for Lead | about +3 dB |
| 21–25 | Bypass, as above | |
| 26 | The amp's gain, from the tone's drive | per amp, from `calibration.json` |
| 27–30 | Bass, Mid, Treble, Presence | full range. An amp without one ignores it |
| 31 | Delay time | 0–2 s |
| 33, 34 | Delay feedback, mix | full range |
| 35 | Reverb mix | full range |
| 36 | Chorus mix | full range |
| 37 | The cab's Level, from the tone's drive | per amp, from `calibration.json` |

CC 32 is left out: it's MIDI's Bank Select, and Helix Native picks a setlist with it. Snapshots still set
the compressor and the drive block.

### Calibration

Amps differ too much for one range. For the same distortion Brit 2204 needs Drive 0.5 and US Deluxe 5.4,
and an amp can get 35 dB louder with Drive. So `calibration.json` gives each amp its own range of gain,
and CC 37 follows the tone's drive to hold its level, with the output block taking what the cab's +6 dB
can't.

`tools/calibrate_stomp.py` measures this in Helix Native, offline, through the saved states of rs-tonehost
(`tools/measure_helix.m`). The Stomp has the same models, and Native needs no guitar. Run it again after
a change of amps, then `tools/make_stomp_presets.py`.

- **Dirt** is how far in dB a guitar sits above the level where an amp starts to compress. The presets
  aim at -10 dB for Clean, 0 for Crunch and +10 for Heavy, at the middle of each category.
- **The scale** comes from US Deluxe and Brit 2203 in the presets above, which sounded right. A guitar's
  peaks are taken as -18 dB, from tonehost's logs of playing at about -14 to -20.
- **The level** is that of Classic Rock's Crunch, -26.5 dB in these terms, with the cab at +2 dB.

The middle 80% of the 35 amps, for a tone in the middle of its category:

| | Level before | Level after | Dirt before | Dirt after |
|---|---|---|---|---|
| Clean | -40.7 to -24.2 dB | -27.5 to -26.5 dB | -18.0 to +6.2 dB | -10.3 to -2.1 dB |
| Crunch | -27.7 to -21.9 dB | -26.3 to -25.1 dB | -7.2 to +17.4 dB | -1.6 to +5.9 dB |
| Heavy | -24.2 to -17.5 dB | -27.5 to -26.8 dB | +2.9 to +33.3 dB | +9.0 to +10.8 dB |

These are computed from the measurements, not measured on a Stomp. A straight line of levels misses the
amp's real curve by 1.4 dB in the median amp and 4.3 dB at worst, on Matchstick Ch2, which falls silent
below Drive 1.

All 35 were imported, and with a guitar through Brit 2204, Cali Rectifire and US Deluxe, each at clean,
crunch and heavy, the amps sounded well matched (7 November 2026). The other amps haven't been heard.
On the Stomp, CC 26 on Fullerton and Agua Sledge reached exactly their calibrated maximum.

**What it leaves out:**

- The amp and cab alone are measured. The compressor in Clean and the drive block in Heavy add level and
  distortion on top, so those two may sit a little high.
- Native's cab runs full range, while the presets cut below 80 Hz and above 9 kHz.
- Ch Vol is taken as linear, as above, on amps whose default it had to lower.

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
