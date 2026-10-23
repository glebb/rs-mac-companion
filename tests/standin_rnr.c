// Stand-in for RockNRoller, for tests/run_rnr_test.sh: exports the names librnrcompanion reads
// (docs/rocknroller.md) and plays a script on them, so the library can be tested without the app.
// Built as an executable named RockNRoller (the library checks the program name).
//
// Usage: RockNRoller <archive path as RockNRoller has it, e.g. …/songs.psarc#selftrap>
// Script (seconds from start):
//    0  catalog (no play session)
//    1  plays the song in one panel showing RHYTHM, from 37 s (a change at 40.16 s, 3 s later)
//    7  seeks to 60 s (the next change at 63.02 s)
//   12  the panel switches to BASS
//   15  back to the catalog; exits at 18
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int template_id;
    struct { int source, variant; } cell[4];
    int ncells;
} rnr_layout;

char g_pa[64];
char g_chart_session[8104];
rnr_layout g_chart_layout = {0, {{-1, 0}, {-1, 0}, {-1, 0}, {-1, 0}}, 1};

static volatile bool live;
static volatile double pos_at_start, started;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

bool play_session_live(void) { return live; }

float play_audio_time_played(void *pa) {
    return pa == g_pa && live ? (float)(pos_at_start + now() - started) : 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return fprintf(stderr, "usage: RockNRoller <archive path>\n"), 2;
    sleep(1);
    snprintf(g_chart_session, sizeof g_chart_session, "%s", argv[1]);
    g_chart_layout.cell[0].source = 2;   // RHYTHM
    pos_at_start = 37, started = now();
    live = true;
    sleep(6);
    pos_at_start = 60, started = now();
    sleep(5);
    g_chart_layout.cell[0].source = 3;   // BASS
    sleep(3);
    live = false;
    memset(g_chart_session, 0, sizeof g_chart_session);
    sleep(3);
    return 0;
}
