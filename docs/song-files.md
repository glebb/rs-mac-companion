# Rocksmith 2014 song files (macOS)

How tone information is stored in the game's song archives, and how
[native/rsfile.c](../native/rsfile.c) reads it with only macOS system libraries (CommonCrypto,
zlib). The `.sng` record layout follows [Rocksmith2014.NET](https://github.com/iminashi/Rocksmith2014.NET)
(MIT). Checked against an independent reader on a whole library: all ~10,500 arrangements' tone
slots, tags, gear and timelines identical.

## Where the songs are

In the game folder (`~/Library/Application Support/Steam/steamapps/common/Rocksmith2014`):

- `songs.psarc`: the songs that come with the game (~1 GB, 278 arrangements).
- `dlc/**/*_m.psarc`: downloadable and custom songs for Mac. `*_p.psarc` are the PC versions.
- One archive can hold one song (`dlc/fredgoin_m.psarc`) or many (`dlc/rs1compatibilitydisc_m.psarc`,
  ~150 songs; custom packs).
- File names don't reliably name the song: only ~14% of DLC arrangements have the song key in the
  file name. Read the archive's table of contents, or watch which file the game reads
  ([game-memory.md](game-memory.md#9-what-the-game-does-with-its-files)).

## .psarc archives

```
Header (32 bytes, big-endian)
  "PSAR" | u32 version | "zlib" | u32 toc_length | u32 toc_entry_size (30) | u32 entry_count
  | u32 block_size (65536) | u32 flags (4 = table of contents encrypted)
Table of contents (toc_length − 32 bytes), AES-256-CFB (128-bit feedback) with a fixed key/IV
  entry_count × 30 bytes:  MD5 of path (16) | u32 first block | u40 length | u40 offset
  then u16 block sizes (compressed size of each block; 0 = stored uncompressed, full block)
Entry data: from offset, blocks of up to block_size uncompressed bytes, each zlib-compressed
  unless its block size is 0
Entry 0: the newline-separated paths of entries 1..n
```

Reading one entry costs one seek and its compressed bytes; reading the table of contents of all
~2,400 archives of a library takes ~4 s. `rstool toc <archive>` lists entries with their byte
ranges (`start end length path`), which maps a file offset to an entry.

Paths that matter, per arrangement `<key>_<part>` (e.g. `skid18an_lead`):

| Path | Content |
|---|---|
| `manifests/songs_dlc_<key>/<key>_<part>.json` | the arrangement's manifest (below) |
| `songs/bin/macos/<key>_<part>.sng` | the arrangement's notes and **tone timeline** (below) |
| `audio/mac/song_<key>.bnk`, `…_preview.bnk` | Wwise sound banks |
| `audio/mac/<number>.wem` | the audio streams |
| `gfxassets/album_art/…`, `gamexblocks/nsongs/<key>.xblock`, `<key>_aggregategraph.nt` | art, catalog |

## Manifest (JSON)

`Entries.<id>.Attributes` holds, among much else:

| Key | Example |
|---|---|
| `SongName`, `ArtistName` | `18 And Life`, `Skid Row` |
| `SongKey` | `Skid18an` (case varies; file names use lower case) |
| `ArrangementName` | `Lead`, `Rhythm`, `Bass`, `Combo`, `Vocals` |
| `Tone_Base`, `Tone_A` … `Tone_D` | tone keys per slot, e.g. `skid18an_clean` (empty if unused) |
| `Tones[]` | per tone: `Key`, `Name`, `ToneDescriptors` (e.g. `"$[35720]CLEAN"`), `GearList` (amp, cabinet, pedals, racks), `NameSeparator` |

`ToneDescriptors` are the tone's tags; strip the `$[id]` prefix. Seen tags: CLEAN, DISTORTION,
OVERDRIVE, LEAD, BASS, ACOUSTIC, CHORUS, REVERB, TREMOLO, PHASER, FLANGER, ECHO, DELAY, FILTER,
OCTAVE, FUZZ, HIGH GAIN, LOW OUTPUT, SPECIAL EFFECT, PROCESSED. The game's on-screen tone banner
shows them title-cased.

Tone keys are almost always specific to one song (97% of the 7,177 keys in a library of
~2,400 archives), shared between the parts of that song (38% are used by more than one part). The 3% used
by several songs are generic names in custom songs (`bass`, `lead`, `distortion`, `clean`, …).

## .sng (Mac)

```
u32 0x4A | u32 flags | 16-byte IV | AES-256-CTR (fixed Mac key, big-endian counter) over:
    u32 plain length (little-endian) | zlib stream | unused trailing bytes
```

The plain SNG is a sequence of arrays, each `i32 count` + records, little-endian. The tone
timeline is the 13th; everything before it has fixed-size records except one:

| # | Array | Record bytes |
|---|---|---|
| 1 | beats | 16 |
| 2 | phrases | 44 |
| 3 | chords | 72 |
| 4 | chord notes | 2376 |
| 5 | vocals | 60 |
| 6–8 | symbol headers, textures, definitions (**only if vocals > 0**) | 32, 144, 44 |
| 9 | phrase iterations | 24 |
| 10 | phrase extra info | 16 |
| 11 | new linked difficulties | variable: `i32 level break` + `i32 count` + count × i32 |
| 12 | actions | 260 |
| 13 | events | 260 |
| 14 | **tones** | 8: `f32 time` (s) + `i32 tone id` |

Tone id 0..3 = slots A..D. Before the first change the **Base** tone is active. A change into a
slot whose tone key equals the current one is no audible change.

`rs_sng_tones()` decrypts, inflates and walks to the tones; for a typical arrangement it takes
1–2 ms. Sizes read from files are capped (64 MB), so a corrupt file fails fast instead of
allocating gigabytes.

## Known bad files

- `dlc/draghigh_m.psarc` has a block that isn't valid zlib; `rsfile.c` keeps such blocks as
  stored data (as other readers do) and reads the archive.
- Some custom songs have `.sng` entries that no reader decodes (corrupt files). `rs_sng_tones()`
  returns −1 for them quickly; the arrangement is then treated as having no tone changes.
