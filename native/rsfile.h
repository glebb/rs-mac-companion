// rsfile: read Rocksmith 2014 (Mac) song files: .psarc archives, the tone timeline in .sng
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

// Decrypt and unpack a Mac .sng: the plain SNG (malloc'ed; free it), its length in *plain_len,
// or NULL if the data isn't a valid SNG. Its arrays: docs/song-files.md.
uint8_t *rs_sng_plain(const uint8_t *sng, size_t len, size_t *plain_len);

// Decrypt and unpack a Mac .sng and return its tone changes in *out (malloc'ed; free it).
// Returns the number of changes, or -1 if the data isn't a valid SNG.
int rs_sng_tones(const uint8_t *sng, size_t len, rs_tone_change **out);

// Copy the string value of the first "key": "value" in a JSON text into out. Returns 1 if
// found, 0 if not (out is then ""). Handles the escapes used in manifests.
int rs_json_str(const char *json, const char *key, char *out, size_t outlen);

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
// (e.g. "Amp=Amp_AT20;Cabinet=Cab_EN212C_57_Cone") into gear[i] (gear_size bytes each).
int rs_json_tones_gear(const char *json, rs_tone_def *out, char *gear, size_t gear_size, int max);

#endif
