// Stand-in for Rocksmith used by tests/run_dylib_test.sh to test the in-game dylib
// (native/rscompanion.c), which is loaded into it with DYLD_INSERT_LIBRARIES. Imitates:
//   - the game's file reads: at 1 s it reads Self Trap's rhythm .sng entry from the game's own
//     songs.psarc (argv[1] at offset argv[2]), at 4 s audio (offset argv[3]),
//   - arrangement description objects: the selected selftrap_rhythm twice, selftrap_bass once,
//     and a stale duplicate pair from an earlier song (boysdontcry_combo),
//   - a double song timer that starts at e = 20 s, at song time 30 s (like the game's),
//   - a menu clock and a clock that keeps resetting every 8 s (decoys that also tick at 1 s/s),
//   - the game's tone banners "<Song> - <Tone>" at Self Trap (Rhythm)'s tone changes
//     40.164 s (Distortion) and 63.023 s (Clean).
// With a 4th argument "notones": Self Trap's bass (no tone changes, so no banners) is selected,
// the song starts at e = 5 s (timer from 0), a clock starts when the song is picked (e = 3 s,
// like the game's), and the game's play record "Play_SelfTrap" holds the song position, next
// to a stale record from an earlier play and the preview's "Play_SelfTrap_Preview". While that
// song plays, the note-stats and Score Attack objects count one hit per second (score +100 each),
// next to a freed note-stats copy (marker kept, type pointer gone).
// Built as x86_64, so it runs under Rosetta like the real game.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define ARRANGEMENT_VTABLE 0x1017F8C20ULL
#define NOTE_STATS_VTABLE 0x1017F92C0ULL
#define SCORE_ATTACK_VTABLE 0x10180A388ULL

// Objects kept here so the compiler cannot drop allocations nothing else reads.
void *volatile g_objects[16];

// A note-stats or Score Attack object: type pointer at +0, the int32 111000 at +0xC.
static int32_t *stats_object(uint64_t vtable) {
    int32_t *o = calloc(1, 0x200);
    memcpy(o, &vtable, 8);
    o[3] = 111000;
    return o;
}

// A play record: the event name as an inline 32-byte string, then the position as float
// seconds (+0x20) and int32 milliseconds (+0x24).
static uint8_t *play_record(const char *name, double pos) {
    uint8_t *r = calloc(1, 0x40);
    strcpy((char *)r, name);
    uint64_t end = (uint64_t)r + strlen(name);
    memcpy(r + 0x10, &end, 8);
    float f = (float)pos;
    int32_t ms = (int32_t)(pos * 1000);
    memcpy(r + 0x20, &f, 4);
    memcpy(r + 0x24, &ms, 4);
    return r;
}

// An arrangement description object: type pointer at +0, name at +0x18 as a 32-byte
// small-buffer string {char buf[16] | char *ptr; char *end; char *cap}.
static void *arrangement(uint64_t vtable, const char *name) {
    uint8_t *o = calloc(1, 0x200);
    memcpy(o, &vtable, 8);
    size_t len = strlen(name);
    uint64_t text;
    if (len < 16) {
        strcpy((char *)o + 0x18, name);          // inline: the end pointer points into the field
        text = (uint64_t)(o + 0x18);
    } else {
        text = (uint64_t)strdup(name);           // on the heap: the first word points to it
        memcpy(o + 0x18, &text, 8);
    }
    uint64_t end = text + len;
    memcpy(o + 0x18 + 16, &end, 8);
    return o;
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: rs-standin-dylib <archive> <sng offset> <audio offset> [notones]\n");
        return 2;
    }
    int notones = argc == 5 && !strcmp(argv[4], "notones");
    uint64_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i)->filetype == MH_EXECUTE) slide = (uint64_t)_dyld_get_image_vmaddr_slide(i);
    uint64_t vt = ARRANGEMENT_VTABLE + slide;
    g_objects[0] = arrangement(vt, "boysdontcry_combo");
    g_objects[1] = arrangement(vt, "boysdontcry_combo");

    volatile double *menu = malloc(8), *loop = malloc(8), *song = malloc(8), *picked = malloc(8);
    uint8_t *rec = NULL;
    int32_t *note = NULL, *sa = NULL;
    if (notones) {
        g_objects[7] = play_record("Play_SelfTrap", 61.25);  // stale, from an earlier play
        g_objects[8] = play_record("Play_SelfTrap_Preview", 0);
        int32_t *freed = stats_object(0);  // freed: the allocator overwrote the type pointer
        freed[0x40 / 4] = 999;
        g_objects[10] = freed;
    }
    volatile double *dd = malloc(2000000 * 8);
    for (int i = 0; i < 2000000; i++) dd[i] = 0.5 + (i % 99991) * 0.01;
    static char buf[65536];
    FILE *f = NULL;
    char *b1 = NULL, *b2 = NULL;
    int read_sng = 0, read_audio = 0;
    struct timespec s, n;
    clock_gettime(CLOCK_MONOTONIC, &s);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &n);
        double e = (n.tv_sec - s.tv_sec) + (n.tv_nsec - s.tv_nsec) / 1e9;
        if (!read_sng && e >= 1) {
            f = fopen(argv[1], "rb");
            fread(buf, 1, sizeof buf, f);  // header + table of contents
            fseeko(f, atoll(argv[2]), SEEK_SET);
            fread(buf, 1, sizeof buf, f);
            read_sng = 1;
        }
        if (!g_objects[2] && e >= 3) {
            g_objects[2] = arrangement(vt, "selftrap_rhythm");
            g_objects[3] = arrangement(vt, "selftrap_bass");
            g_objects[4] = arrangement(vt, notones ? "selftrap_bass" : "selftrap_rhythm");
        }
        if (!read_audio && e >= 4) {
            fseeko(f, atoll(argv[3]), SEEK_SET);
            fread(buf, 1, sizeof buf, f);
            read_audio = 1;
        }
        *menu = e + 15;
        *loop = e - 8 * (int)(e / 8);
        if (notones) {
            *picked = e < 3 ? 0.0 : e - 3;
            *song = e < 5 ? 0.0 : e - 5;
            if (!rec && e >= 5) {
                g_objects[9] = rec = play_record("Play_SelfTrap", 0);
                g_objects[11] = note = stats_object(NOTE_STATS_VTABLE + slide);
                g_objects[12] = sa = stats_object(SCORE_ATTACK_VTABLE + slide);
                sa[0x11C / 4] = sa[0x120 / 4] = 1;
            }
            if (note) {
                int hits = (int)*song;
                note[0x40 / 4] = note[0x44 / 4] = note[0x4C / 4] = note[0x5C / 4] = hits;
                sa[0x68 / 4] = sa[0x58 / 4] = sa[0x60 / 4] = hits;
                sa[0x118 / 4] = hits * 100;
            }
            if (rec) {
                float f = (float)*song;
                int32_t ms = (int32_t)(*song * 1000);
                memcpy(rec + 0x20, &f, 4);
                memcpy(rec + 0x24, &ms, 4);
            }
            usleep(16000);
            continue;
        }
        *song = e < 20 ? 0.0 : e - 20 + 30;
        if (!b1 && *song >= 40.164) g_objects[5] = b1 = strdup("Self Trap - Distortion");
        if (!b2 && *song >= 63.023) g_objects[6] = b2 = strdup("Self Trap - Clean");
        usleep(16000);
    }
}
