// rsfile: read Rocksmith 2014 song files (Mac, and Windows for Learn & Play): .psarc archives, the tone timeline in .sng
// arrangements, and fields of the JSON manifests. Uses only macOS system libraries
// (CommonCrypto, zlib). Formats: docs/song-files.md and rsfile.c.
#ifndef RSFILE_H
#define RSFILE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    char *path;          // e.g. "songs/bin/macos/boysdontcry_combo.sng"
    uint64_t offset;     // where the entry's (compressed) data starts in the archive
    uint64_t end;        // where it ends
    uint64_t length;     // uncompressed length
    uint32_t zindex;     // first block in the block-size table
} rs_entry;

typedef struct {
    FILE *f;
    uint32_t block;      // block size (64 KiB)
    uint16_t *bs;        // compressed size of each block (0 = stored uncompressed)
    uint32_t nbs;
    uint64_t toc_end;    // end of the header + table of contents
    rs_entry *e;         // entries, excluding the path list
    uint32_t n;
} rs_psarc;

typedef struct {
    float time;          // seconds from song start
    int32_t id;          // 0..3 = tone slots A..D (before the first change, Base is active)
} rs_tone_change;

// Open an archive and read its table of contents. NULL on failure.
rs_psarc *rs_psarc_open(const char *path);
void rs_psarc_close(rs_psarc *p);

// The entry whose data contains the archive offset, or NULL (header, padding, past the end).
const rs_entry *rs_psarc_entry_at(const rs_psarc *p, uint64_t offset);

// The entry with this exact path, or NULL.
const rs_entry *rs_psarc_find(const rs_psarc *p, const char *path);

// Read and decompress an entry. Returns a malloc'ed buffer with a 0 byte appended (handy for
// JSON), or NULL. *len gets the entry's length.
uint8_t *rs_psarc_read(rs_psarc *p, const rs_entry *e, size_t *len);

// Decrypt (Mac or Windows key; an unencrypted file as it is) and unpack a .sng: the plain SNG (malloc'ed; free it),
// its length in *plain_len, or NULL if the data isn't a valid SNG. Its arrays: docs/song-files.md (an RS Extended
// Range chart's start with an 8-byte "SNXR" header: rsfile.c).
uint8_t *rs_sng_plain(const uint8_t *sng, size_t len, size_t *plain_len);

// Decrypt and unpack a .sng (also an RS Extended Range chart) and return its tone changes in *out (malloc'ed; free it).
// Returns the number of changes, or -1 if the data isn't a valid SNG.
int rs_sng_tones(const uint8_t *sng, size_t len, rs_tone_change **out);

// Copy the string value of the first "key": "value" in a JSON text into out. Returns 1 if
// found, 0 if not (out is then ""). Handles the escapes used in manifests.
int rs_json_str(const char *json, const char *key, char *out, size_t outlen);

// The number value of the first "key": number in a JSON text into *out. Returns 1 if found.
int rs_json_num(const char *json, const char *key, double *out);

// An arrangement's tuning from its manifest's Tuning and CentOffset (bass: an arrangement named "Bass"). A stock
// arrangement has string0..string5 (bass: the first 4 count), low string first, each an offset from E standard. An RS
// Extended Range chart ("ExtendedRange" in its manifest) with 7 or 8 guitar strings or 5 or 6 bass strings has
// string0..string{N-1}, thickest first, each an offset from that string's own standard pitch (guitar 8: F#1 B1 E2 A2
// D3 G3 B3 E4, guitar 7 from B1; bass 6: B0 E1 A1 D2 G2 C3, bass 5 to G2). One with 6 (guitar) or 4 (bass) is stock.
#define RS_MAX_STRINGS 8
typedef struct {
    int strings;                        // N: 6 or 4 for a stock arrangement, 7-8 or 5-6 for an extended one
    int extended;                       // 1: an extended chart, positional holds its N offsets
    double stock[6];                    // the stock strings, low string first, offsets from E standard: guitar the
                                        // top six of an extended chart, bass its four after the low B, then the
                                        // rest (a 6-string's high C) and 0
    double positional[RS_MAX_STRINGS];  // an extended chart's N offsets, thickest string first
    double low;                         // the lowest string's pitch in semitones from the stock low string (E2,
                                        // bass E1), with the cent offset: B standard 7-string -5, F# 8-string -10
    char name[32];                      // "E standard", "Drop D", "custom", "B standard (7-string)", "Drop A
                                        // (5-string)", "custom (8-string)"
} rs_tuning;

// Read an arrangement's tuning (see rs_tuning) from a manifest's JSON text. Returns 1, or 0 if it has no Tuning (or
// one this can't read: too few strings, or more than an extended chart has).
int rs_json_tuning(const char *json, int bass, rs_tuning *out);

// A tone definition from a manifest's "Tones" array: its key, name, name separator and its
// ToneDescriptors without the "$[id]" prefix (e.g. "CLEAN", "CHORUS"); the game's tone banner
// shows these tags. amp is the GearList's amp key (e.g. "Amp_HG500", "" if none) and gain its
// gain knob, 0-100 (the Plexi has two volume knobs instead: the higher counts), or -1 if unknown.
#define RS_MAX_DESC 6
typedef struct {
    char key[128];
    char name[128];
    char separator[8];
    char desc[RS_MAX_DESC][32];
    int ndesc;
    char amp[64];
    float gain;
} rs_tone_def;

// Parse a manifest's "Tones" array into out (at most max). Returns the number of tones.
int rs_json_tones(const char *json, rs_tone_def *out, int max);

// Like rs_json_tones, and also each tone's GearList as "Slot=Key" entries separated by ';'
// (e.g. "Amp=Amp_AT20;Cabinet=Cab_EN212C_57_Cone") into gear[i] (gear_size bytes each), and as
// a JSON object with every item's knobs, named without the key's prefix, into rig[i] (rig_size
// bytes each): {"Amp": {"key": "Amp_AT20", "knobs": {"Gain": 14, "Bass": 45, ...}}, ...}.
// gear or rig may be NULL.
int rs_json_tones_gear(const char *json, rs_tone_def *out, char *gear, size_t gear_size, char *rig, size_t rig_size,
                       int max);

#endif
