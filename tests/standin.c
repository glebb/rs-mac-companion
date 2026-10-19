// Stand-in for Rocksmith used by tests/run_standin_test.sh: imitates what rstone reads.
//   - a double song timer that starts at e = 20 s, at song time 30 s (like the game's),
//   - a menu clock and a clock that keeps resetting every 8 s (decoys that also tick at 1 s/s),
//   - static decoy doubles,
//   - the game's tone banners "<Song> - <Tone>" appearing at Self Trap (Rhythm)'s tone changes
//     40.164 s (Distortion) and 63.023 s (Clean); the song comes with the game, and
//     tests/fixture_index.jsonl holds its index line.
// Built as x86_64 and named rs-standin, so it runs under Rosetta like the real game.
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
int main() {
    volatile double *menu = malloc(8), *loop = malloc(8), *song = malloc(8); char *b1 = 0, *b2 = 0;
    volatile double *dd = malloc(2000000 * 8);
    for (int i = 0; i < 2000000; i++) dd[i] = 0.5 + (i % 99991) * 0.01;
    struct timespec s, n; clock_gettime(CLOCK_MONOTONIC, &s);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &n);
        double e = (n.tv_sec - s.tv_sec) + (n.tv_nsec - s.tv_nsec) / 1e9;
        *menu = e + 15; *loop = e - 8 * (int)(e / 8);
        *song = e < 20 ? 0.0 : e - 20 + 30;
        if (!b1 && *song >= 40.164) { b1 = malloc(64); strcpy(b1, "Self Trap - Distortion"); }
        if (!b2 && *song >= 63.023) { b2 = malloc(64); strcpy(b2, "Self Trap - Clean"); }
        usleep(16000);
    }
}
