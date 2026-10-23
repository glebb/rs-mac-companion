// rscore: what the in-game libraries share (see rscore.c). Everything here is hidden: a library
// exports nothing to the app it runs in.
#ifndef RSCORE_H
#define RSCORE_H

#include <stddef.h>
#include <stdio.h>

#include "rsfile.h"

#pragma GCC visibility push(hidden)

// ================================================================ songs (from files)

#define MAX_TONES 16
#define MAX_CHANGES 512
#define MAX_ARRS 16

typedef struct {
    char name[128];                 // e.g. "skid18an_lead"
    char song_key[128];             // manifest SongKey, e.g. "Skid18an" (names the play record)
    char archive[1024];             // the .psarc the game loaded it from
    char song[256], artist[256];
    char slots[5][128];             // tone keys for Base, A..D ("" if unused)
    rs_tone_def tones[MAX_TONES];
    int ntones;
    rs_tone_change ch[MAX_CHANGES];
    int nch;
} arrangement;

typedef struct {
    char key[128];                  // file name prefix, e.g. "skid18an"
    arrangement arr[MAX_ARRS];
    int narr;
} song;

extern const char *const SLOT_NAMES[5];   // "Base", "A".."D"

// The data folder (DATA_DIR): ~/Library/Application Support/rs-mac-companion, or
// $RS_COMPANION_DATA. 0 without a home folder.
int data_dir(char *out, size_t outlen);
// Opens DATA_DIR/name as the log (appended, unbuffered).
void log_open(const char *dir, const char *name);
extern FILE *g_logf;
void logline(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
double now_s(void);
int ends_with(const char *s, const char *suffix);

rs_psarc *archive(const char *path);      // opened once, cached
const char *short_path(const char *path); // the part from "Rocksmith2014/" on, for the log
song *load_song(rs_psarc *p, const char *key);  // every arrangement of song key (file prefix); free()

// ================================================================ tones of an arrangement

int slot_at(const arrangement *a, double t);      // the slot playing at t (s): 0 = Base, 1..4 = A..D
const char *tone_key(const arrangement *a, int slot);
const rs_tone_def *tone_def(const arrangement *a, int slot);

// ================================================================ events (see rscore.c)

#define PROTOCOL 1

extern int g_last_slot;             // the slot and tone of the last tone event
extern char g_last_tone[128];
extern int g_lead_ms;               // see config_poll()

void events_open(const char *data_dir);
void send_event(const char *json, int log);
void json_str(char *out, size_t outlen, const char *s);
void emit_tone(const arrangement *a, int slot, const char *source, double time_s);
void emit_song(const arrangement *a, const char *parts);
void emit_state(const arrangement *a, const char *parts, int locked, double time_s);
void build_parts(const song *s, char *out, size_t size);

// Settings (DATA_DIR/rscompanion.json), re-read by config_poll() when the file changes.
extern char g_config_file[1024];
extern volatile int g_overlay;
void config_poll(void);

#pragma GCC visibility pop

#endif
