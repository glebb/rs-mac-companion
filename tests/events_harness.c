// For tests/run_events_test.sh: builds songs in memory (no game, no files) and has native/rscore.c
// send their song, tone and state events to a socket this program binds, then prints each event
// it got, one per line. Song "small": 3 ordinary arrangements. Song "huge": 16 arrangements whose
// names, tone keys, tags, song, artist and archive are as long as the reader allows, with quotes and
// backslashes to escape, so the parts can't all fit.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../native/rscore.h"

static void fill(char *out, size_t size, const char *stem, int i) {
    // as long as the field allows, with characters JSON must escape
    snprintf(out, size, "%s%d_", stem, i);
    for (size_t n = strlen(out); n + 1 < size; n++) out[n] = "a\"b\\c"[n % 5];
    out[size - 1] = 0;
}

static song *make(const char *which) {
    song *s = calloc(1, sizeof *s);
    int huge = !strcmp(which, "huge");
    s->narr = huge ? MAX_ARRS : 3;
    snprintf(s->key, sizeof s->key, "%s", which);
    for (int i = 0; i < s->narr; i++) {
        arrangement *a = &s->arr[i];
        if (huge) {
            fill(a->name, sizeof a->name, "huge_part", i);
            fill(a->song, sizeof a->song, "Song", i);
            fill(a->artist, sizeof a->artist, "Artist", i);
            fill(a->archive, sizeof a->archive, "/archive", i);
            for (int k = 0; k < 5; k++) fill(a->slots[k], sizeof a->slots[k], "Tone", k);
            a->ntones = 5;
            for (int k = 0; k < 5; k++) {
                rs_tone_def *t = &a->tones[k];
                snprintf(t->key, sizeof t->key, "%s", a->slots[k]);
                t->ndesc = RS_MAX_DESC;
                for (int d = 0; d < RS_MAX_DESC; d++) fill(t->desc[d], sizeof t->desc[d], "TAG", d);
                fill(t->amp, sizeof t->amp, "Amp_", k);
                t->gain = 55;
            }
        } else {
            snprintf(a->name, sizeof a->name, "small_%s", (const char *[]){"lead", "rhythm", "bass"}[i]);
            snprintf(a->song, sizeof a->song, "Small Song");
            snprintf(a->artist, sizeof a->artist, "Band");
            snprintf(a->archive, sizeof a->archive, "/dlc/small_m.psarc");
            snprintf(a->slots[0], sizeof a->slots[0], "small_clean");
            snprintf(a->slots[1], sizeof a->slots[1], "small_dist");
        }
        a->ch[0] = (rs_tone_change){1.0f, 0};
        a->nch = 1;
    }
    return s;
}

int main(int argc, char **argv) {
    const char *dir = argv[1];
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s/events.sock", dir);
    int r = socket(AF_UNIX, SOCK_DGRAM, 0), size = 1 << 18;
    setsockopt(r, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
    if (bind(r, (struct sockaddr *)&sa, sizeof sa)) return perror("bind"), 1;
    log_open(dir, "events_harness.log");
    events_open(dir);
    static char parts[8192];  // as g_parts in rscompanion.c and parts in rnrcompanion.c
    for (int i = 2; i < argc; i++) {
        song *s = make(argv[i]);
        build_parts(s, parts, sizeof parts);
        emit_song(&s->arr[0], parts);
        emit_tone(&s->arr[0], 1, "timer", 1.0);
        emit_state(&s->arr[0], parts, 1, 2.5);
        free(s);
    }
    static char buf[65536];
    struct timeval tv = {1, 0};
    setsockopt(r, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    ssize_t n;
    while ((n = recv(r, buf, sizeof buf - 1, 0)) > 0) {
        buf[n] = 0;
        printf("%s\n", buf);
    }
    return 0;
}
