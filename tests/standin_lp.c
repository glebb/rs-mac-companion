// Stand-in for RS Re-ARMed Learn & Play (tests/run_lp_test.sh): the parts of its mod interface the
// companion uses, a 4 GB guest window, and a song that plays in it.
//   standin_lp LIBRARY ARRANGEMENT KEY SECONDS
// Exports rc_target ("win-x86"), rc_hook_add_name, rc_slide and rc_guest_ptr_size, loads LIBRARY as
// Learn & Play does (only if it defines rc_mod_abi), then, as the game would:
//   - opens the arrangement's .sng through FrontEnd_OpenFile (data\songs\bin\generic\<ARRANGEMENT>.sng,
//     and the vocals' too),
//   - posts the Wwise event Play_<KEY>,
//   - keeps a song timer (a double from 3 s, ticking) and decoy clocks in the guest heap, and a play
//     record: the name "Play_<KEY>" as a 4-byte pointer, with the position (float seconds) 0x18
//     bytes after it; a stale record of the same song whose position doesn't move.
// Runs SECONDS seconds. With a 5th argument "moves", the timer's copy is freed (reads as -1) 8 s
// after the event and the timer goes on in another copy, as seen in Learn & Play.
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

typedef struct { uint64_t r[16]; } rc_regs;
typedef int (*rc_pre_fn)(rc_regs *c, void *user);

uint64_t rc_slide;
const int rc_guest_ptr_size = 4;
const char *rc_target(void) { return "win-x86"; }

static struct { const char *name; rc_pre_fn pre; void *user; } hooks[8];
static int nhooks;
int rc_hook_add_name(const char *name, rc_pre_fn pre, void *post, void *user) {
    (void)post;
    if (strcmp(name, "frontend_open_file") && strcmp(name, "ak_post_event_name")) return -1;
    hooks[nhooks].name = name, hooks[nhooks].pre = pre, hooks[nhooks++].user = user;
    return 0;
}

static void call(const char *name, uint64_t arg0, uint64_t arg1) {
    rc_regs c = {0};
    c.r[7] = arg0, c.r[6] = arg1;
    for (int i = 0; i < nhooks; i++)
        if (!strcmp(hooks[i].name, name)) hooks[i].pre(&c, hooks[i].user);
}

static double now_s(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static uint8_t *G(uint32_t g) { return (uint8_t *)(uintptr_t)(rc_slide + g); }

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: standin_lp LIBRARY ARRANGEMENT KEY SECONDS\n");
        return 2;
    }
    const char *lib = argv[1], *arr = argv[2], *key = argv[3];
    double seconds = atof(argv[4]);
    int moves = argc > 5 && !strcmp(argv[5], "moves");
    // The guest window: 4 GB reserved, a heap committed in it
    void *w = mmap(NULL, 1ULL << 32, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (w == MAP_FAILED) return 1;
    rc_slide = (uint64_t)(uintptr_t)w;
    const uint32_t heap = 0x50000000, heap_size = 16 << 20;
    if (mprotect(G(heap), heap_size, PROT_READ | PROT_WRITE)) return 1;
    memset(G(heap), 0x11, heap_size);  // resident pages
    // Learn & Play's loader: a library without rc_mod_abi is not loaded
    int fd = open(lib, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) return 1;
    void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    int marked = m != MAP_FAILED && memmem(m, (size_t)st.st_size, "_rc_mod_abi", 12) != NULL;
    close(fd);
    if (!marked) {
        printf("standin: %s is not built for every target: not loaded\n", lib);
        return 1;
    }
    if (!dlopen(lib, RTLD_NOW | RTLD_GLOBAL)) {
        printf("standin: dlopen: %s\n", dlerror());
        return 1;
    }
    printf("standin: loaded, %d hooks, slide 0x%llx\n", nhooks, (unsigned long long)rc_slide);
    fflush(stdout);
    sleep(2);
    char path[300], vocals[300];
    snprintf(path, sizeof path, "data\\songs\\bin\\generic\\%s.sng", arr);
    snprintf(vocals, sizeof vocals, "data\\songs\\bin\\generic\\%.*s_vocals.sng", (int)(strchr(arr, '_') - arr), arr);
    strcpy((char *)G(heap + 0x1000), path);
    strcpy((char *)G(heap + 0x1200), vocals);
    call("frontend_open_file", 0, (uint64_t)(uintptr_t)G(heap + 0x1200));
    call("frontend_open_file", 0, (uint64_t)(uintptr_t)G(heap + 0x1000));
    sleep(3);  // the tuner
    char ev[160];
    snprintf(ev, sizeof ev, "Play_%s", key);
    strcpy((char *)G(heap + 0x2000), ev);
    call("ak_post_event_name", (uint64_t)(uintptr_t)G(heap + 0x2000), 0);
    // The play records: name pointers at +0, position at +0x18; a stale one first
    uint32_t live = heap + 0x300000, stale = heap + 0x200000;
    memcpy(G(stale), &(uint32_t){heap + 0x2000}, 4);
    memcpy(G(stale + 0x18), &(float){12.5f}, 4);
    memcpy(G(live), &(uint32_t){heap + 0x2000}, 4);
    double t0 = now_s();
    while (now_s() - t0 < seconds) {
        double t = 3 + now_s() - t0;   // the song timer: ahead of the event, as the game's is
        double decoy = t + 0.42;         // a clock started when the song was picked
        double menu = now_s() - t0 + 50; // a clock of the whole session
        if (moves && now_s() - t0 > 8) {
            double gone = -1;
            memcpy(G(heap + 0x400008), &gone, 8);
            memcpy(G(heap + 0x480008), &t, 8);
        } else {
            memcpy(G(heap + 0x400008), &t, 8);
        }
        memcpy(G(heap + 0x400108), &decoy, 8);
        memcpy(G(heap + 0x500008), &menu, 8);
        memcpy(G(live + 0x18), &(float){(float)t}, 4);
        usleep(5000);
    }
    return 0;
}
