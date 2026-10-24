// rscompanion (prototype): in-game dylib that reports Rocksmith 2014 tone changes in real time,
// with no pre-built index and no special permissions.
//
// 1. Song: the libc file calls are interposed (dyld __interpose) to see which .psarc archives
//    the game opens and where it reads. When the game reads an arrangement's .sng entry, a
//    worker thread opens the same archive itself (rsfile.c) and reads every arrangement of that
//    song: manifest (song, artist, tone slots, tone tags) and tone changes.
// 2. Arrangement: the selected one's description object exists twice in memory (the game keeps
//    a working copy); found by its type pointer (game_profile.json's arrangement_vtable), and
//    only names of the song just loaded count.
// 3. Song timer: a double that advances 1 s per second while the song plays. Candidates are
//    found by rate; the game's play record ("Play_<SongKey>" with the song position) picks the
//    one equal to the position, once per song (also checking a timer kept from earlier songs),
//    or, before that, the game's tone banner ("<Song> - <Tone tags>") at a tone change picks the
//    one whose value matches the song file's change time.
// 4. Tone: the slot active at timer + lead time (rscompanion.json, default 100 ms) per the
//    song's timeline, checked 20 times a second.
// 5. Events go to the companion app over a Unix datagram socket (see the events section).
//
// Memory is read in place (mach_vm_read_overwrite on our own task, so a page freed meanwhile is
// an error, not a crash). Scans skip our own memory (tagged buffers, our image, thread stacks),
// so they never find copies of what they look for. The game's code is never touched.
//
// Logs to ~/Library/Application Support/rs-mac-companion/rscompanion.log; tone events are lines
// starting with "EVENT " followed by JSON, like rstone.py's output.
// What it shares with the RockNRoller library (songs, tone timelines, events, settings): rscore.c.
// Build: see build.sh (x86_64 only: the game runs under Rosetta).
#include <ctype.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "rscore.h"

// Values tied to this Rocksmith build (unslid addresses in its x86_64 image); see
// game_profile.json and docs/when-the-game-updates.md.
#define IMAGE_BASE 0x100000000ULL
#define ARRANGEMENT_VTABLE 0x1017F8C20ULL
#define ARR_NAME 0x18
#define PLAY_POS 0x20    // play record: position, float seconds
#define PLAY_MS 0x24     // play record: position, int32 milliseconds
// Note statistics (game-memory.md section 8): Learn a Song and Score Attack objects, alive while a
// song is played. Offsets as in game_profile.json.
#define NOTE_STATS_VTABLE 0x1017F92C0ULL
#define NOTE_STATS_MARKER 0xC           // int32 111000
#define SCORE_ATTACK_VTABLE 0x10180A388ULL

#define OUR_TAG 250      // VM tag of our own buffers (application-specific tags are 240..255)
#define CHUNK (1 << 20)

// The song most recently loaded by the game, replaced by the worker; readers copy what they
// need under g_state_lock.
static song *g_song;
static unsigned g_song_gen;         // +1 per song load
static double g_song_loaded_at;

// ================================================================ file interposing

#define MAX_FDS 4096
static char *g_fd_path[MAX_FDS];
static pthread_mutex_t g_fd_lock = PTHREAD_MUTEX_INITIALIZER;

// The game loads any file in dlc/ with ".psarc" in its name, also "x_m.psarc.backup" (left by
// song tools); with two copies of a pack it may read a song from either.
static int is_archive(const char *path) {
    const char *name = strrchr(path, '/');
    return strstr(name ? name + 1 : path, ".psarc") != NULL;
}

static void track_open(const char *path, int fd) {
    if (!path || fd < 0 || fd >= MAX_FDS || !is_archive(path)) return;
    char *copy = strdup(path);
    pthread_mutex_lock(&g_fd_lock);
    free(g_fd_path[fd]);
    g_fd_path[fd] = copy;
    pthread_mutex_unlock(&g_fd_lock);
}

static void track_close(int fd) {
    if (fd < 0 || fd >= MAX_FDS || !g_fd_path[fd]) return;
    pthread_mutex_lock(&g_fd_lock);
    free(g_fd_path[fd]);
    g_fd_path[fd] = NULL;
    pthread_mutex_unlock(&g_fd_lock);
}

typedef struct { char *path; long long off; } read_event;
#define QUEUE 1024
static read_event g_q[QUEUE];
static unsigned g_qhead, g_qtail, g_dropped;
static pthread_mutex_t g_q_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_q_cond = PTHREAD_COND_INITIALIZER;

static void note_read(int fd, long long off) {
    // Offset 0 is the header + table of contents; the game reads it for every archive.
    if (off <= 0 || fd < 0 || fd >= MAX_FDS || !g_fd_path[fd]) return;
    pthread_mutex_lock(&g_fd_lock);
    char *path = g_fd_path[fd] ? strdup(g_fd_path[fd]) : NULL;
    pthread_mutex_unlock(&g_fd_lock);
    if (!path) return;
    pthread_mutex_lock(&g_q_lock);
    if (g_qtail - g_qhead < QUEUE) {
        g_q[g_qtail++ % QUEUE] = (read_event){path, off};
        pthread_cond_signal(&g_q_cond);
        path = NULL;
    } else {
        g_dropped++;
    }
    pthread_mutex_unlock(&g_q_lock);
    free(path);
}

static int my_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    int fd = open(path, flags, mode);
    track_open(path, fd);
    return fd;
}

static int my_openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    int fd = openat(dirfd, path, flags, mode);
    track_open(path, fd);
    return fd;
}

static FILE *my_fopen(const char *path, const char *mode) {
    FILE *f = fopen(path, mode);
    if (f) track_open(path, fileno(f));
    return f;
}

static int my_close(int fd) {
    track_close(fd);
    return close(fd);
}

static int my_fclose(FILE *f) {
    if (f) track_close(fileno(f));
    return fclose(f);
}

static size_t my_fread(void *buf, size_t size, size_t n, FILE *f) {
    int fd = f ? fileno(f) : -1;
    if (fd < 0 || fd >= MAX_FDS || !g_fd_path[fd]) return fread(buf, size, n, f);
    off_t at = ftello(f);
    size_t got = fread(buf, size, n, f);
    if (got) note_read(fd, at);
    return got;
}

static ssize_t my_read(int fd, void *buf, size_t len) {
    if (fd < 0 || fd >= MAX_FDS || !g_fd_path[fd]) return read(fd, buf, len);
    off_t at = lseek(fd, 0, SEEK_CUR);
    ssize_t got = read(fd, buf, len);
    if (got > 0) note_read(fd, at);
    return got;
}

static ssize_t my_pread(int fd, void *buf, size_t len, off_t off) {
    ssize_t got = pread(fd, buf, len, off);
    if (got > 0) note_read(fd, off);
    return got;
}

#define INTERPOSE(replacement, original)                                                      \
    __attribute__((used)) static const struct { const void *r; const void *o; }               \
        interpose_##original __attribute__((section("__DATA,__interpose"))) = {              \
            (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original}

INTERPOSE(my_open, open);
INTERPOSE(my_openat, openat);
INTERPOSE(my_fopen, fopen);
INTERPOSE(my_close, close);
INTERPOSE(my_fclose, fclose);
INTERPOSE(my_fread, fread);
INTERPOSE(my_read, read);
INTERPOSE(my_pread, pread);

// ================================================================ worker: load songs

static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;

static char g_last_key[256], g_last_archive[1024];
static double g_last_load;

static void handle_read(const read_event *ev) {
    rs_psarc *p = archive(ev->path);
    if (!p) return;
    const rs_entry *e = rs_psarc_entry_at(p, (uint64_t)ev->off);
    if (!e || strncmp(e->path, "songs/bin/macos/", 16) || !ends_with(e->path, ".sng")) return;
    const char *base = e->path + 16, *us = strrchr(base, '_');
    if (!us) return;
    char key[256];
    snprintf(key, sizeof key, "%.*s", (int)(us - base), base);
    // The game reads all arrangements of a song together; one load = reads within 10 s.
    double t = now_s();
    if (!strcmp(key, g_last_key) && !strcmp(ev->path, g_last_archive) && t - g_last_load < 10) {
        g_last_load = t;
        return;
    }
    snprintf(g_last_key, sizeof g_last_key, "%s", key);
    snprintf(g_last_archive, sizeof g_last_archive, "%s", ev->path);
    g_last_load = t;

    song *s = load_song(p, key);
    if (!s) return;
    for (int i = 0; i < s->narr; i++) snprintf(s->arr[i].archive, sizeof s->arr[i].archive, "%s", ev->path);
    logline("song %s loaded by the game from %s: %d arrangements read in %.0f ms", key, short_path(ev->path),
            s->narr, (now_s() - t) * 1000);
    for (int i = 0; i < s->narr; i++) {
        const arrangement *a = &s->arr[i];
        char changes[1024] = "";
        size_t at = 0;
        for (int c = 0; c < a->nch && at < sizeof changes - 32; c++)
            at += (size_t)snprintf(changes + at, sizeof changes - at, "%s%.3f->%c", c ? " " : "", a->ch[c].time,
                                   a->ch[c].id >= 0 && a->ch[c].id < 4 ? 'A' + a->ch[c].id : '?');
        logline("  %s: Base=%s A=%s B=%s C=%s D=%s; changes: %s", a->name, a->slots[0], a->slots[1], a->slots[2],
                a->slots[3], a->slots[4], a->nch ? changes : "none");
    }
    pthread_mutex_lock(&g_state_lock);
    song *old = g_song;
    g_song = s;
    g_song_gen++;
    g_song_loaded_at = t;
    pthread_mutex_unlock(&g_state_lock);
    free(old);
}

static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&g_q_lock);
        while (g_qhead == g_qtail) pthread_cond_wait(&g_q_cond, &g_q_lock);
        read_event ev = g_q[g_qhead++ % QUEUE];
        unsigned dropped = g_dropped;
        g_dropped = 0;
        pthread_mutex_unlock(&g_q_lock);
        if (dropped) logline("warning: %u read events dropped (queue full)", dropped);
        handle_read(&ev);
        free(ev.path);
    }
    return NULL;
}

// ================================================================ memory scanning

static uint64_t g_own_lo, g_own_hi;  // our own image

static void *own_alloc(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, VM_MAKE_TAG(OUR_TAG), 0);
    return p == MAP_FAILED ? NULL : p;
}

static int safe_read(uint64_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), addr, len, (mach_vm_address_t)buf, &got) == KERN_SUCCESS &&
           got == len;
}

// Memory region tags (VM_MEMORY_*: malloc zones, stacks, graphics, ...). Each search learns which
// tags hold what it looks for and then scans only those, falling back to a full scan now and
// then. What was learned is saved, so the next game session starts with narrow scans.
typedef struct { uint64_t w[4]; } tagset;

static int tags_has(const tagset *t, int tag) { return tag >= 0 && tag < 256 && (t->w[tag >> 6] >> (tag & 63) & 1); }
static int tags_empty(const tagset *t) { return !(t->w[0] | t->w[1] | t->w[2] | t->w[3]); }

static int tags_add(tagset *t, int tag) {
    if (tag < 0 || tag >= 256 || tags_has(t, tag)) return 0;
    t->w[tag >> 6] |= 1ULL << (tag & 63);
    return 1;
}

static void tags_str(const tagset *t, char *out, size_t outlen) {
    out[0] = 0;
    for (int i = 0; i < 256; i++)
        if (tags_has(t, i)) {
            char n[8];
            snprintf(n, sizeof n, " %d", i);
            strlcat(out, n, outlen);
        }
}

// Tag of the region containing addr, or -1.
static int tag_of(uint64_t addr) {
    mach_vm_address_t a = addr;
    mach_vm_size_t s = 0;
    vm_region_extended_info_data_t info;
    mach_msg_type_number_t cnt = VM_REGION_EXTENDED_INFO_COUNT;
    mach_port_t obj;
    if (mach_vm_region(mach_task_self(), &a, &s, VM_REGION_EXTENDED_INFO, (vm_region_info_t)&info, &cnt, &obj) !=
        KERN_SUCCESS)
        return -1;
    return a <= addr && addr < a + s ? (int)info.user_tag : -1;
}

enum { TAGS_ARRANGEMENT, TAGS_BANNER, TAGS_TIMER, TAGS_PLAY, TAGS_STATS, NTAGS };
static const char *TAG_NAMES[NTAGS] = {"arrangement", "banner", "timer", "play", "stats"};
static tagset g_tags[NTAGS];
static pthread_mutex_t g_tags_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_tags_file[1024];

static void tags_save(void) {
    FILE *f = fopen(g_tags_file, "w");
    if (!f) return;
    for (int k = 0; k < NTAGS; k++) {
        char s[1024];
        tags_str(&g_tags[k], s, sizeof s);
        fprintf(f, "%s%s\n", TAG_NAMES[k], s);
    }
    fclose(f);
}

static void tags_load(void) {
    FILE *f = fopen(g_tags_file, "r");
    if (!f) return;
    char line[1100];
    while (fgets(line, sizeof line, f)) {
        char *rest = strchr(line, ' ');
        if (!rest) continue;
        *rest++ = 0;
        for (int k = 0; k < NTAGS; k++)
            if (!strcmp(line, TAG_NAMES[k]))
                for (char *tok = strtok(rest, " \n"); tok; tok = strtok(NULL, " \n")) tags_add(&g_tags[k], atoi(tok));
    }
    fclose(f);
}

// Remember that `what` was found at addr; saves when this is a new tag for it.
static void tags_learn(int what, uint64_t addr) {
    int tag = tag_of(addr);
    pthread_mutex_lock(&g_tags_lock);
    int added = tags_add(&g_tags[what], tag);
    if (added) tags_save();
    pthread_mutex_unlock(&g_tags_lock);
    if (added) logline("learned: %s data lives in memory tagged %d", TAG_NAMES[what], tag);
}

// The tags to scan for `what`, or NULL (= everything) if nothing is known yet.
static const tagset *tags_for(int what, tagset *copy) {
    pthread_mutex_lock(&g_tags_lock);
    *copy = g_tags[what];
    pthread_mutex_unlock(&g_tags_lock);
    return tags_empty(copy) ? NULL : copy;
}

// Calls fn(base, data, len, ctx) for every chunk of the game's writable data (only regions with
// a tag in `only`, if given); fn returns 0 to stop. buf must be a CHUNK-sized own_alloc buffer.
// Returns the bytes scanned.
typedef int (*chunk_fn)(uint64_t base, const uint8_t *data, size_t len, void *ctx);

static uint64_t scan(uint8_t *buf, const tagset *only, chunk_fn fn, void *ctx) {
    uint64_t total = 0;
    mach_vm_address_t a = 0;
    for (;;) {
        mach_vm_size_t s = 0;
        vm_region_extended_info_data_t info;
        mach_msg_type_number_t cnt = VM_REGION_EXTENDED_INFO_COUNT;
        mach_port_t obj;
        if (mach_vm_region(mach_task_self(), &a, &s, VM_REGION_EXTENDED_INFO, (vm_region_info_t)&info, &cnt, &obj) !=
            KERN_SUCCESS)
            break;
        int rw = (info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE) &&
                 !(info.protection & VM_PROT_EXECUTE);
        int ours = info.user_tag == OUR_TAG || info.user_tag == VM_MEMORY_STACK ||
                   (a < g_own_hi && a + s > g_own_lo);
        int empty = info.pages_resident == 0 && info.pages_swapped_out == 0;
        int wanted = !only || tags_has(only, (int)info.user_tag);
        if (rw && !ours && !empty && wanted) {
            for (mach_vm_size_t off = 0; off < s; off += CHUNK) {
                size_t len = s - off < CHUNK ? (size_t)(s - off) : CHUNK;
                if (!safe_read(a + off, buf, len)) continue;
                total += len;
                if (!fn(a + off, buf, len, ctx)) return total;
            }
        }
        a += s;
    }
    return total;
}

// A 32-byte small-buffer string {char buf[16] | char *ptr; char *end; char *cap}.
static void read_sso(uint64_t addr, char *out, size_t outlen) {
    uint64_t f[4];
    out[0] = 0;
    if (!safe_read(addr, f, sizeof f)) return;
    uint64_t end = f[2], p = (addr <= end && end <= addr + 16) ? addr : f[0];
    if (end < p || end - p >= outlen || end - p >= 256) return;
    if (end > p && !safe_read(p, out, (size_t)(end - p))) return;
    out[end - p] = 0;
}

// ================================================================ arrangement detection

typedef struct { uint64_t want; uint64_t hits[512]; int n; } ptr_search;

static int find_ptr(uint64_t base, const uint8_t *d, size_t len, void *ctx) {
    ptr_search *ps = ctx;
    for (size_t i = 0; i + 8 <= len; i += 8) {
        uint64_t v;
        memcpy(&v, d + i, 8);
        if (v == ps->want) {
            ps->hits[ps->n++] = base + i;
            if (ps->n == 512) return 0;
        }
    }
    return 1;
}

static uint64_t g_slide;

// Name of the selected arrangement of song `key` (its object exists twice), or "". Scans only
// the learned memory tags when `narrow` and some are known.
static void selected_arrangement(uint8_t *buf, const char *key, int narrow, char *out, size_t outlen) {
    static ptr_search ps;  // in our image: never scanned
    ps.want = ARRANGEMENT_VTABLE + g_slide;
    ps.n = 0;
    double t0 = now_s();
    tagset tags;
    const tagset *only = narrow ? tags_for(TAGS_ARRANGEMENT, &tags) : NULL;
    uint64_t bytes = scan(buf, only, find_ptr, &ps);
    char names[512][64];
    int count[512] = {0}, distinct = 0;
    out[0] = 0;
    size_t kl = strlen(key);
    for (int i = 0; i < ps.n; i++) {
        char name[64];
        read_sso(ps.hits[i] + ARR_NAME, name, sizeof name);
        if (!name[0]) continue;
        int j = 0;
        while (j < distinct && strcmp(names[j], name)) j++;
        if (j == distinct) snprintf(names[distinct++], sizeof names[0], "%s", name);
        count[j]++;
    }
    for (int j = 0; j < distinct; j++)
        if (count[j] > 1 && !strncasecmp(names[j], key, kl) && names[j][kl] == '_')
            snprintf(out, outlen, "%s", names[j]);
    if (out[0])
        for (int i = 0; i < ps.n; i++) {
            char name[64];
            read_sso(ps.hits[i] + ARR_NAME, name, sizeof name);
            if (!strcmp(name, out)) tags_learn(TAGS_ARRANGEMENT, ps.hits[i]);
        }
    logline("arrangement scan (%s): %d objects, %d names, %.0f MB in %.0f ms -> %s", only ? "narrow" : "full", ps.n,
            distinct, bytes / 1048576.0, (now_s() - t0) * 1000, out[0] ? out : "(none for this song yet)");
}

// ================================================================ tones of an arrangement

// Lower-cased words of s, sorted, joined by one space.
static void word_set(const char *s, char *out, size_t outlen) {
    char words[16][48];
    int n = 0;
    while (*s && n < 16) {
        while (*s == ' ') s++;
        int k = 0;
        while (*s && *s != ' ') {
            if (k < 47) words[n][k++] = (char)tolower((unsigned char)*s);
            s++;
        }
        words[n][k] = 0;
        if (k) n++;
    }
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0 && strcmp(words[j - 1], words[j]) > 0; j--) {
            char t[48];
            memcpy(t, words[j], 48);
            memcpy(words[j], words[j - 1], 48);
            memcpy(words[j - 1], t, 48);
        }
    out[0] = 0;
    for (int i = 0; i < n; i++) {
        strlcat(out, i ? " " : "", outlen);
        strlcat(out, words[i], outlen);
    }
}

// The banner shows a tone's tags joined, e.g. CLEAN + CHORUS -> "Clean Chorus".
static int banner_matches(const char *text, const arrangement *a, int slot) {
    const rs_tone_def *d = tone_def(a, slot);
    char tw[256], dw[256] = "", all[256] = "";
    word_set(text, tw, sizeof tw);
    if (d) {
        for (int i = 0; i < d->ndesc; i++) {
            if (!strcasecmp(d->desc[i], text)) return 1;
            strlcat(all, " ", sizeof all);
            strlcat(all, d->desc[i], sizeof all);
        }
        word_set(all, dw, sizeof dw);
        if (tw[0] && !strcmp(tw, dw)) return 1;
    }
    return text[0] && strcasestr(tone_key(a, slot), text) != NULL;
}

static int banner_slot(const arrangement *a, const char *text) {
    for (int slot = 0; slot < 5; slot++)
        if (a->slots[slot][0] && banner_matches(text, a, slot)) return slot;
    return -1;
}

// ================================================================ shared tracking state

static arrangement g_arr;           // selected arrangement (a copy, owned here)
static char g_parts[8192];          // JSON "parts" of the song of g_arr (see build_parts)
static int g_have_arr;
static unsigned g_arr_gen;          // +1 per arrangement selection

#define POOL 64
static uint64_t g_pool[POOL];       // song timer candidates (addresses of doubles)
static int g_npool;
static uint64_t g_timer;            // the confirmed song timer, or 0
static int g_confirmed;

// Hold: no timed tone changes until the song's live play record (or a banner) shows that this
// song is the one playing. Set when the song timer goes back (a restart, a jump back, or another
// song started, whose files the game may not have read now) and when an arrangement is picked
// while a timer from an earlier song is confirmed (it still shows where that song stopped).
// g_hold_from is the timer's value after it went back (-1: not gone back yet); the searcher
// drops the song when the timer runs on from there without the play record (see searcher).
static int g_hold;
static double g_hold_from;
static int g_hold_misses;

typedef struct { double seen; char text[96]; } banner;
#define PENDING 16
static banner g_banners[PENDING];   // banners seen but not yet handled
static int g_nbanners;

static int read_timer(uint64_t addr, double *v) {
    return safe_read(addr, v, 8) && *v == *v && *v >= 0 && *v < 100000;
}

// ================================================================ searcher: arrangement + timer

// Text search: every address of pat (plen bytes) in a chunk, up to 300.
typedef struct { char pat[300]; size_t plen; uint64_t hits[300]; int n; } banner_search;

static int find_text(uint64_t base, const uint8_t *d, size_t len, void *ctx) {
    banner_search *bs = ctx;
    const uint8_t *p = d, *end = d + len;
    while (p < end && (p = memmem(p, (size_t)(end - p), bs->pat, bs->plen))) {
        bs->hits[bs->n++] = base + (uint64_t)(p - d);
        if (bs->n == 300) return 0;
        p++;
    }
    return 1;
}

// Song timer search (doubles in seconds). Each candidate keeps its value and the moment it was
// read, so a pass compares each value against its own elapsed time.
typedef struct { uint64_t *a; float *v; float *t; size_t n, cap; } tset;
static tset g_ts;

static void ts_free(void) {
    if (g_ts.a) munmap(g_ts.a, g_ts.cap * 8);
    if (g_ts.v) munmap(g_ts.v, g_ts.cap * 4);
    if (g_ts.t) munmap(g_ts.t, g_ts.cap * 4);
    memset(&g_ts, 0, sizeof g_ts);
}

static void *grow(void *old, size_t old_bytes, size_t new_bytes) {
    void *p = own_alloc(new_bytes);
    if (p && old) {
        memcpy(p, old, old_bytes);
        munmap(old, old_bytes);
    }
    return p;
}

static void ts_add(uint64_t a, double v, float when) {
    if (g_ts.n == g_ts.cap) {
        size_t cap = g_ts.cap ? g_ts.cap * 2 : 1 << 18;
        uint64_t *na = grow(g_ts.a, g_ts.cap * 8, cap * 8);
        float *nv = grow(g_ts.v, g_ts.cap * 4, cap * 4), *nt = grow(g_ts.t, g_ts.cap * 4, cap * 4);
        if (!na || !nv || !nt) return;  // out of memory: keep what we have
        g_ts.a = na, g_ts.v = nv, g_ts.t = nt, g_ts.cap = cap;
    }
    g_ts.a[g_ts.n] = a, g_ts.v[g_ts.n] = (float)v, g_ts.t[g_ts.n++] = when;
}

static int snap_doubles(uint64_t base, const uint8_t *d, size_t len, void *ctx) {
    (void)ctx;
    float when = (float)now_s();
    for (size_t i = 0; i + 8 <= len; i += 8) {
        double v;
        memcpy(&v, d + i, 8);
        if (v >= 0.5 && v <= 1000) ts_add(base + i, v, when);
    }
    return 1;
}

// Keep candidates that advanced at 0.97..1.03 s per second since they were last read.
static void rate_pass(uint8_t *win) {
    uint64_t wbase = 0, wlen = 0;
    float when = 0;
    size_t k = 0;
    for (size_t i = 0; i < g_ts.n; i++) {
        uint64_t a = g_ts.a[i];
        if (a < wbase || a + 8 > wbase + wlen) {
            wbase = a & ~(uint64_t)0xfff;
            wlen = CHUNK;
            while (wlen >= 0x1000 && !safe_read(wbase, win, wlen)) wlen /= 2;  // shorter near a region end
            if (wlen < 0x1000) wlen = 0;
            when = (float)now_s();
            if (a + 8 > wbase + wlen) continue;
        }
        double v;
        memcpy(&v, win + (a - wbase), 8);
        float dt = when - g_ts.t[i];
        if (dt < 0.2f) {
            g_ts.a[k] = a, g_ts.v[k] = g_ts.v[i], g_ts.t[k++] = g_ts.t[i];
            continue;
        }
        double rate = (v - g_ts.v[i]) / dt;
        if (rate >= 0.97 && rate <= 1.03) g_ts.a[k] = a, g_ts.v[k] = (float)v, g_ts.t[k++] = when;
    }
    g_ts.n = k;
}

static int stale(unsigned gen) {
    pthread_mutex_lock(&g_state_lock);
    int s = g_arr_gen != gen || g_confirmed;
    pthread_mutex_unlock(&g_state_lock);
    return s;
}

static void timer_search(uint8_t *buf, unsigned gen) {
    // Four rounds out of five only in the learned tags (if any), every fifth round everywhere.
    static unsigned round;
    tagset tags;
    const tagset *only = round++ % 5 != 4 ? tags_for(TAGS_TIMER, &tags) : NULL;
    double t0 = now_s();
    uint64_t bytes = scan(buf, only, snap_doubles, NULL);
    size_t snapped = g_ts.n;
    for (int pass = 1; pass <= 3 && g_ts.n; pass++) {
        for (int i = 0; i < 10 && !stale(gen); i++) usleep(100000);
        if (stale(gen)) break;
        rate_pass(buf);
    }
    int added = 0;
    pthread_mutex_lock(&g_state_lock);
    if (g_arr_gen == gen && !g_confirmed) {
        for (size_t i = 0; i < g_ts.n && i < 50; i++) {
            int dup = 0;
            for (int j = 0; j < g_npool; j++) dup |= g_pool[j] == g_ts.a[i];
            if (dup) continue;
            if (g_npool == POOL) memmove(g_pool, g_pool + 1, (POOL - 1) * 8), g_npool--;
            g_pool[g_npool++] = g_ts.a[i];
            added++;
        }
    }
    int pool = g_npool;
    pthread_mutex_unlock(&g_state_lock);
    logline("timer search (%s, %.0f MB): %zu doubles, %zu ticking, +%d candidates (pool %d) in %.1f s",
            only ? "narrow" : "full", bytes / 1048576.0, snapped, g_ts.n, added, pool, now_s() - t0);
    ts_free();
}

// ================================================================ play record

// While a song plays, the game keeps a record of its audio play event: the event name
// "Play_<SongKey>" as a 32-byte string (inline or on the heap), then the song position as float
// seconds (+PLAY_POS) and int32 milliseconds (+PLAY_MS). Copies from earlier plays linger with
// their position frozen, so only a record whose milliseconds advance counts. The song timer
// equals its position; this confirms the timer in songs without tone changes and checks it in
// every song (a confirmed timer can be freed, and a clock started with the song can pass the
// banner check).
#define PLAY_RECS 32
typedef struct { uint64_t want[PLAY_RECS], lo, hi; int nwant; uint64_t hits[PLAY_RECS]; int n; } ptrs_search;

static int find_ptrs(uint64_t base, const uint8_t *d, size_t len, void *ctx) {
    ptrs_search *ps = ctx;
    for (size_t i = 0; i + 8 <= len; i += 8) {
        uint64_t v;
        memcpy(&v, d + i, 8);
        if (v < ps->lo || v > ps->hi) continue;
        for (int j = 0; j < ps->nwant; j++)
            if (v == ps->want[j]) {
                ps->hits[ps->n++] = base + i;
                if (ps->n == PLAY_RECS) return 0;
                break;
            }
    }
    return 1;
}

// Position (ms) in the record at a whose name is the len-byte text at text, or -1.
static int32_t play_ms(uint64_t a, uint64_t text, size_t len) {
    uint8_t r[PLAY_MS + 4];
    if (!safe_read(a, r, sizeof r)) return -1;
    uint64_t first, end;
    float pos;
    int32_t ms;
    memcpy(&first, r, 8);
    memcpy(&end, r + 0x10, 8);
    memcpy(&pos, r + PLAY_POS, 4);
    memcpy(&ms, r + PLAY_MS, 4);
    if (end != text + len || (text != a && first != text)) return -1;
    double diff = pos * 1000.0 - ms;
    return ms >= 0 && ms < 100000000 && diff > -2 && diff < 2 ? ms : -1;
}

// The position of the live play record of song_key in seconds (read just now), or -1 (the song
// is not playing: not started yet, paused, or left).
static double play_position(uint8_t *buf, banner_search *bs, ptrs_search *ps, const char *song_key) {
    static unsigned round;
    snprintf(bs->pat, sizeof bs->pat, "Play_%s", song_key);
    size_t len = strlen(bs->pat);
    bs->plen = len + 1;  // with the terminating 0, so not "Play_<key>_Preview"
    bs->n = 0;
    tagset tags;
    const tagset *only = round++ % 5 != 4 ? tags_for(TAGS_PLAY, &tags) : NULL;
    scan(buf, only, find_text, bs);
    uint64_t recs[PLAY_RECS], texts[PLAY_RECS];
    int n = 0;
    ps->nwant = 0;
    for (int i = 0; i < bs->n; i++) {
        if (len < 16 && n < PLAY_RECS) recs[n] = texts[n] = bs->hits[i], n++;  // inline: the record starts with it
        else if (len >= 16 && ps->nwant < PLAY_RECS) ps->want[ps->nwant++] = bs->hits[i];
    }
    if (ps->nwant) {  // on the heap: records point to the text
        ps->lo = ~0ULL, ps->hi = 0, ps->n = 0;
        for (int j = 0; j < ps->nwant; j++) {
            if (ps->want[j] < ps->lo) ps->lo = ps->want[j];
            if (ps->want[j] > ps->hi) ps->hi = ps->want[j];
        }
        scan(buf, only, find_ptrs, ps);
        for (int i = 0; i < ps->n && n < PLAY_RECS; i++)
            if (safe_read(ps->hits[i], &texts[n], 8)) recs[n++] = ps->hits[i];
    }
    int32_t ms0[PLAY_RECS];
    for (int i = 0; i < n; i++) ms0[i] = play_ms(recs[i], texts[i], len);
    usleep(300000);
    for (int i = 0; i < n; i++) {
        int32_t ms1 = ms0[i] < 0 ? -1 : play_ms(recs[i], texts[i], len);
        if (ms1 - ms0[i] < 200 || ms1 - ms0[i] > 400) continue;
        tags_learn(TAGS_PLAY, recs[i]);
        if (texts[i] != recs[i]) tags_learn(TAGS_PLAY, texts[i]);
        return ms1 / 1000.0;
    }
    return -1;
}

// Checks the song timer against the live play record: keeps a confirmed timer that agrees,
// drops one that doesn't, and confirms a pool candidate equal to the play position.
// 1 = timer confirmed and checked, 0 = no live record, -1 = no candidate matches yet.
static int play_check(uint8_t *buf, banner_search *bs, ptrs_search *ps, unsigned gen, const char *song_key) {
    double pos = play_position(buf, bs, ps, song_key);
    if (pos < 0) return 0;
    uint64_t pool[POOL];
    pthread_mutex_lock(&g_state_lock);
    int confirmed = g_confirmed, n = g_npool;
    uint64_t timer = g_timer;
    memcpy(pool, g_pool, sizeof pool);
    pthread_mutex_unlock(&g_state_lock);
    double v;
    if (confirmed) {
        if (read_timer(timer, &v) && v - pos <= 0.1 && pos - v <= 0.1) {
            logline("song timer checked: %.2f s, the game's play position %.2f s", v, pos);
            return 1;
        }
        logline("song timer at %llx is not the song's (play position %.2f s); searching again", (unsigned long long)timer,
                pos);
        pthread_mutex_lock(&g_state_lock);
        if (g_timer == timer) g_confirmed = 0, g_timer = 0;
        pthread_mutex_unlock(&g_state_lock);
    }
    uint64_t best = 0;
    double best_d = 0.1;
    for (int c = 0; c < n; c++) {
        if (!read_timer(pool[c], &v)) continue;
        double d = v > pos ? v - pos : pos - v;
        if (d <= best_d) best_d = d, best = pool[c];
    }
    if (!best) return -1;
    pthread_mutex_lock(&g_state_lock);
    int ok = g_arr_gen == gen && !g_confirmed;
    if (ok) g_timer = best, g_confirmed = 1;
    pthread_mutex_unlock(&g_state_lock);
    if (!ok) return 0;
    logline("play record: song timer is the double at %llx (play position %.2f s, off by %.3f s)",
            (unsigned long long)best, pos, best_d);
    tags_learn(TAGS_TIMER, best);
    return 1;
}

static void *searcher(void *arg) {
    (void)arg;
    uint8_t *buf = own_alloc(CHUNK);
    banner_search *bs = own_alloc(sizeof *bs);  // patterns live in our tagged memory
    ptrs_search *ps = own_alloc(sizeof *ps);
    unsigned seen_song_gen = 0, tries_gen = 0, tries = 0, checked_gen = 0, live_gen = 0;
    double last_arr_check = 0, selected_at = 0, last_play_check = 0, live_at = 0;
    for (;;) {
        pthread_mutex_lock(&g_state_lock);
        unsigned song_gen = g_song_gen;
        double loaded_at = g_song_loaded_at;
        char key[128] = "";
        if (g_song) snprintf(key, sizeof key, "%s", g_song->key);
        int have = g_have_arr, confirmed = g_confirmed, changes = g_arr.nch, hold = g_hold;
        char cur[128], song_key[128];
        snprintf(cur, sizeof cur, "%s", g_arr.name);
        snprintf(song_key, sizeof song_key, "%s", g_arr.song_key);
        unsigned arr_gen = g_arr_gen;
        pthread_mutex_unlock(&g_state_lock);

        if (!key[0]) {
            usleep(200000);
            continue;
        }
        // Look for the selected arrangement only after the game loads a song (picking another
        // arrangement loads the song again): every second for up to 2 minutes, until found.
        // Narrow scans (cheap) first; every fifth try covers everything.
        double t = now_s();
        if (song_gen != seen_song_gen && song_gen != tries_gen) tries_gen = song_gen, tries = 0;
        if (song_gen != seen_song_gen && t - loaded_at < 120 && t - last_arr_check >= 1) {
            last_arr_check = t;
            char name[128];
            selected_arrangement(buf, key, tries++ % 5 != 4, name, sizeof name);
            if (name[0] && (song_gen != seen_song_gen || strcmp(name, cur))) {
                pthread_mutex_lock(&g_state_lock);
                const arrangement *a = NULL;
                for (int i = 0; g_song && i < g_song->narr; i++)
                    if (!strcasecmp(g_song->arr[i].name, name)) a = &g_song->arr[i];
                if (a && g_song_gen == song_gen) {
                    g_arr = *a;
                    build_parts(g_song, g_parts, sizeof g_parts);
                    g_have_arr = 1;
                    g_arr_gen++;
                    arr_gen = g_arr_gen;
                    seen_song_gen = song_gen;
                    have = 1;
                    // The song timer is one object for the whole game session: a confirmed one stays.
                    if (!g_confirmed) g_npool = 0;
                    g_nbanners = 0;
                    changes = a->nch;
                    snprintf(song_key, sizeof song_key, "%s", a->song_key);
                    selected_at = now_s();
                }
                pthread_mutex_unlock(&g_state_lock);
                if (a) {
                    logline("selected arrangement %s", name);
                } else {
                    logline("selected arrangement %s is not in the loaded song", name);
                }
            }
        }
        // Each song: check the timer against the game's play record, every 3 s from when the
        // arrangement is picked until the song plays (up to 10 minutes), and every 2 s on hold.
        t = now_s();
        if (have && song_gen == seen_song_gen && song_key[0] &&
            ((checked_gen != arr_gen && t - selected_at < 600) || hold) && t - last_play_check >= (hold ? 2 : 3)) {
            last_play_check = t;
            int r = play_check(buf, bs, ps, arr_gen, song_key);
            if (r == 1) checked_gen = arr_gen;
            if (r < 0) live_gen = arr_gen, live_at = now_s();
            // On hold, a live record of this song lets tone changes go on. With none in 5 checks
            // (one of them a full scan) while the timer ran 10 s on from where it went back,
            // another song is playing: one whose files the game didn't read now (a song played
            // earlier, or the same song in two archives), so there is nothing to follow.
            double v = 0, from = 0;
            int released = 0, dropped = 0;
            pthread_mutex_lock(&g_state_lock);
            if (hold && g_hold && g_arr_gen == arr_gen) {
                if (r != 0) {
                    g_hold = 0, released = 1;
                } else if (g_confirmed && g_hold_from >= 0 && read_timer(g_timer, &v) && ++g_hold_misses >= 5 &&
                           v - g_hold_from >= 10) {
                    g_hold = 0, g_have_arr = 0, dropped = 1, from = g_hold_from;
                }
            }
            confirmed = g_confirmed;
            pthread_mutex_unlock(&g_state_lock);
            if (released) logline("play record shows %s playing; tone changes go on", song_key);
            if (dropped) {
                logline("no live play record of %s while the song timer ran from %.2f to %.2f s: another song is "
                        "playing, loaded unseen; no tone changes until the game loads a song",
                        song_key, from, v);
                continue;
            }
        }
        // The rate search fills the candidate pool: for arrangements with tone changes (a banner
        // or the play record confirms), and for others while the play record shows the song
        // playing without a matching candidate.
        int playing = live_gen == arr_gen && now_s() - live_at < 30;
        if (have && !confirmed && (changes > 0 || playing) && song_gen == seen_song_gen) {
            timer_search(buf, arr_gen);
            continue;
        }
        usleep(500000);
    }
    return NULL;
}

// ================================================================ banner watch

// New copies of "<Song> - " in memory are the game's tone banners. The addresses already seen
// go in an open-addressing table; at half full it starts over with a new first scan (otherwise a
// full table would make the lookup loop forever).
#ifndef SEEN_CAP
#define SEEN_CAP (1 << 16)
#endif
_Static_assert(SEEN_CAP >= 64 && (SEEN_CAP & (SEEN_CAP - 1)) == 0, "SEEN_CAP: a power of two");

static void *banner_watch(void *arg) {
    (void)arg;
    uint8_t *buf = own_alloc(CHUNK);
    uint64_t *seen = own_alloc(SEEN_CAP * 8);
    banner_search *bs = own_alloc(sizeof *bs);  // the pattern lives in our tagged memory
    unsigned gen = 0, count = 0, nseen = 0;
    int first = 1, nchanges = 0;
    static float changes[MAX_CHANGES];  // change times of the arrangement (in our image: not scanned)
    double last_scan = 0;
    for (;;) {
        pthread_mutex_lock(&g_state_lock);
        int have = g_have_arr, confirmed = g_confirmed;
        unsigned arr_gen = g_arr_gen;
        uint64_t timer = g_timer;
        if (have && arr_gen != gen) {
            snprintf(bs->pat, sizeof bs->pat, "%s - ", g_arr.song);
            bs->plen = strlen(bs->pat);
            nchanges = g_arr.nch;
            for (int i = 0; i < nchanges; i++) changes[i] = g_arr.ch[i].time;
        }
        pthread_mutex_unlock(&g_state_lock);
        if (!have || bs->plen <= 3) {
            usleep(500000);
            continue;
        }
        if (arr_gen != gen) {
            gen = arr_gen;
            memset(seen, 0, SEEN_CAP * 8);
            first = 1;
            count = 0;
            nseen = 0;
        }
        if (nseen >= SEEN_CAP / 2) {
            logline("banner watch: %u addresses seen; starting over", nseen);
            memset(seen, 0, SEEN_CAP * 8);
            first = 1;
            nseen = 0;
        }
        // With a confirmed timer, banners only double-check it: scan just after each tone change
        // (when the game creates the banner), plus every 15 s in case the timer is wrong.
        if (confirmed && !first) {
            double v, t = now_s();
            int due = t - last_scan >= 15;
            if (!due && read_timer(timer, &v))
                for (int i = 0; i < nchanges && !due; i++) due = v - changes[i] >= 0.3 && v - changes[i] <= 3.0;
            if (!due || t - last_scan < 1) {
                usleep(250000);
                continue;
            }
        }
        last_scan = now_s();
        // The first scan of a song notes what is there already and covers everything, so later
        // narrow scans never mistake an old copy for a new banner. Then only the learned tags,
        // with a full scan every 10th time (about every 5 s) until the timer is confirmed.
        tagset tags;
        const tagset *only = first || (!confirmed && count % 10 == 9) ? NULL : tags_for(TAGS_BANNER, &tags);
        count++;
        bs->n = 0;
        scan(buf, only, find_text, bs);
        double t = now_s();
        for (int i = 0; i < bs->n && nseen < SEEN_CAP - 1; i++) {  // a free slot ends every lookup
            uint64_t a = bs->hits[i];
            size_t h = (size_t)((a >> 3) * 0x9E3779B97F4A7C15ULL) & (SEEN_CAP - 1);
            int known = 0;
            while (seen[h]) {
                if (seen[h] == a) {
                    known = 1;
                    break;
                }
                h = (h + 1) & (SEEN_CAP - 1);
            }
            if (known) continue;
            seen[h] = a;
            nseen++;
            if (first) continue;  // what is there already is old
            char text[128] = "";
            if (!safe_read(a, text, 96)) continue;
            text[96] = 0;
            if (strncmp(text, bs->pat, bs->plen)) continue;
            pthread_mutex_lock(&g_state_lock);
            if (g_arr_gen == gen && g_nbanners < PENDING) {
                g_banners[g_nbanners].seen = t;
                snprintf(g_banners[g_nbanners].text, sizeof g_banners[0].text, "%s", text + bs->plen);
                g_nbanners++;
            }
            pthread_mutex_unlock(&g_state_lock);
            logline("banner seen: \"%s\"", text + bs->plen);
            tags_learn(TAGS_BANNER, a);
        }
        first = 0;
        usleep(500000);
    }
    return NULL;
}

// ================================================================ tracker: tones in real time

static void *tracker(void *arg) {
    (void)arg;
    unsigned gen = 0;
    arrangement *a = own_alloc(sizeof *a);
    banner pending[PENDING];
    int npending = 0;
    double last_beat = 0, prev = -1;
    static char parts[sizeof g_parts];  // in our image: never scanned
    for (;;) {
        usleep(50000);
        banner fresh[PENDING];
        int nfresh;
        pthread_mutex_lock(&g_state_lock);
        int have = g_have_arr;
        if (have && g_arr_gen != gen) {
            gen = g_arr_gen;
            *a = g_arr;
            memcpy(parts, g_parts, sizeof g_parts);
            npending = 0;
            g_last_slot = -1;
            g_last_tone[0] = 0;
            g_hold = g_confirmed, g_hold_from = -1, g_hold_misses = 0;
            prev = -1;
            pthread_mutex_unlock(&g_state_lock);
            emit_song(a, parts);
            emit_tone(a, 0, "song-start", -1);
            continue;
        }
        nfresh = g_nbanners;
        memcpy(fresh, g_banners, sizeof fresh);
        g_nbanners = 0;
        int confirmed = g_confirmed, hold = g_hold;
        uint64_t timer = g_timer;
        int npool = g_npool;
        uint64_t pool[POOL];
        memcpy(pool, g_pool, sizeof pool);
        pthread_mutex_unlock(&g_state_lock);

        // Heartbeat (and settings check) once a second.
        double now = now_s();
        if (now - last_beat >= 1) {
            last_beat = now;
            config_poll();
            double tv = -1;
            if (have && confirmed && !read_timer(timer, &tv)) tv = -1;
            emit_state(have && gen ? a : NULL, parts, confirmed, tv);
        }
        if (!have) continue;

        // With a confirmed timer, banners only verify it.
        if (confirmed && nfresh) {
            double v;
            for (int i = 0; i < nfresh; i++) {
                int slot = banner_slot(a, fresh[i].text);
                if (slot >= 0 && hold) {  // a banner of this song: it is the one playing
                    pthread_mutex_lock(&g_state_lock);
                    g_hold = 0;
                    pthread_mutex_unlock(&g_state_lock);
                    hold = 0;
                    logline("banner \"%s\" shows %s playing; tone changes go on", fresh[i].text, a->song_key);
                }
                if (slot < 0 || !read_timer(timer, &v)) continue;
                int ok = 0;
                for (double back = 0; back <= 5; back += 0.5)
                    ok |= !strcasecmp(tone_key(a, slot_at(a, v - back)), tone_key(a, slot));
                if (!ok) {
                    logline("banner \"%s\" disagrees with the song timer at %.2f s; searching again", fresh[i].text, v);
                    pthread_mutex_lock(&g_state_lock);
                    g_confirmed = 0;
                    g_timer = 0;
                    pthread_mutex_unlock(&g_state_lock);
                    emit_tone(a, slot, "banner", -1);
                    confirmed = 0;
                }
            }
            nfresh = 0;
        }
        if (!confirmed) {
            // Banners are the event source until a timer is confirmed, and they confirm it.
            for (int i = 0; i < nfresh; i++) {
                int slot = banner_slot(a, fresh[i].text);
                if (slot < 0) logline("banner \"%s\" matches no tone of %s", fresh[i].text, a->name);
                else if (strcasecmp(tone_key(a, slot), g_last_tone)) emit_tone(a, slot, "banner", -1);
                if (npending < PENDING) pending[npending++] = fresh[i];
            }
            double t = now_s();
            int k = 0;
            for (int i = 0; i < npending; i++)
                if (t - pending[i].seen < 60) pending[k++] = pending[i];
            npending = k;
            for (int i = 0; i < npending && !confirmed; i++) {
                double best_lag = 1e9, best_ct = 0;
                uint64_t best = 0;
                for (int c = 0; c < npool; c++) {
                    double v;
                    if (!read_timer(pool[c], &v)) continue;
                    for (int j = 0; j < a->nch; j++) {
                        // Slot ids beyond D (a few songs have 5) change nothing, as in slot_at().
                        if (a->ch[j].id < 0 || a->ch[j].id >= 4 || !banner_matches(pending[i].text, a, a->ch[j].id + 1))
                            continue;
                        // Candidate's value when the banner was found, minus the change time.
                        double lag = v - (t - pending[i].seen) - a->ch[j].time;
                        if (lag >= -0.5 && lag <= 5.0 && (lag < 0 ? -lag : lag) < (best_lag < 0 ? -best_lag : best_lag))
                            best_lag = lag, best = pool[c], best_ct = a->ch[j].time;
                    }
                }
                if (best) {
                    pthread_mutex_lock(&g_state_lock);
                    g_timer = best;
                    g_confirmed = 1;
                    pthread_mutex_unlock(&g_state_lock);
                    logline("banner \"%s\": song timer is the double at %llx (change at %.1f s, lag %.2f s)",
                            pending[i].text, (unsigned long long)best, best_ct, best_lag);
                    tags_learn(TAGS_TIMER, best);
                    confirmed = 1;
                    timer = best;
                    npending = 0;
                }
            }
            if (!confirmed) continue;
        }

        double v;
        if (!read_timer(timer, &v)) {
            logline("song timer unreadable; searching again");
            pthread_mutex_lock(&g_state_lock);
            g_confirmed = 0;
            g_timer = 0;
            pthread_mutex_unlock(&g_state_lock);
            prev = -1;
            continue;
        }
        if (prev >= 0 && v < prev - 2) {
            pthread_mutex_lock(&g_state_lock);
            g_hold = 1, g_hold_from = v, g_hold_misses = 0;
            pthread_mutex_unlock(&g_state_lock);
            hold = 1;
            logline("song timer went back from %.2f to %.2f s; tone changes wait for the play record of %s", prev, v,
                    a->song_key);
        }
        prev = v;
        if (hold) continue;
        int slot = slot_at(a, v + g_lead_ms / 1000.0);
        if (slot != g_last_slot) {
            if (strcasecmp(tone_key(a, slot), g_last_tone)) emit_tone(a, slot, "timer", v);  // same tone, other slot: no change
            g_last_slot = slot;
        }
    }
    return NULL;
}

// ================================================================ note statistics

// Only with overlay_enabled (for the app's RockSniffer-compatible stream overlays): the game's
// note-stats object (every mode) and Score Attack object exist while a song is played, both
// with the int32 111000 at +0xC. They are found by type pointer (freed copies keep the marker
// but lose the type pointer), looked for every 2 s while an arrangement is selected, and read
// 4 times a second until their type pointer goes.
typedef struct { uint64_t want[2]; uint64_t hits[2][64]; int n[2]; } stats_search;

static int find_stats(uint64_t base, const uint8_t *d, size_t len, void *ctx) {
    stats_search *ss = ctx;
    for (size_t i = 0; i + 16 <= len; i += 8) {
        uint64_t v;
        memcpy(&v, d + i, 8);
        for (int k = 0; k < 2; k++)
            if (v == ss->want[k] && ss->n[k] < 64) {
                int32_t mark;
                memcpy(&mark, d + i + NOTE_STATS_MARKER, 4);
                if (mark == 111000) ss->hits[k][ss->n[k]++] = base + i;
            }
    }
    return 1;
}

// Whether the object at a is still alive (its type pointer and marker in place).
static int stats_alive(uint64_t a, uint64_t vtable) {
    uint8_t h[NOTE_STATS_MARKER + 4];
    if (!a || !safe_read(a, h, sizeof h)) return 0;
    uint64_t v;
    int32_t mark;
    memcpy(&v, h, 8);
    memcpy(&mark, h + NOTE_STATS_MARKER, 4);
    return v == vtable && mark == 111000;
}

static void add_ints(char *ev, size_t size, const char *name, const int32_t *v, int n) {
    char s[160];
    size_t at = (size_t)snprintf(s, sizeof s, ", \"%s\": [", name);
    for (int i = 0; i < n; i++) at += (size_t)snprintf(s + at, sizeof s - at, "%s%d", i ? ", " : "", v[i]);
    strlcat(s, "]", sizeof s);
    strlcat(ev, s, size);
}

// The stats event for the objects at note and sa (0 if not in Score Attack); 0 if unreadable.
static int emit_stats(uint64_t note, uint64_t sa) {
    int32_t n[8], q[0x128 / 4];
    if (!safe_read(note + 0x40, n, sizeof n)) return 0;
    if (sa && !safe_read(sa, q, sizeof q)) sa = 0;
    char ev[1024];
    snprintf(ev, sizeof ev,
             "{\"event\": \"stats\", \"mode\": \"%s\", \"hits\": %d, \"misses\": %d, \"streak\": %d, "
             "\"best_streak\": %d, \"miss_streak\": %d",
             sa ? "sa" : "las", n[0], n[4], n[1], n[3], n[5]);
    pthread_mutex_lock(&g_state_lock);
    int confirmed = g_confirmed;
    uint64_t timer = g_timer;
    pthread_mutex_unlock(&g_state_lock);
    double tv;
    if (confirmed && read_timer(timer, &tv)) {
        char t[32];
        snprintf(t, sizeof t, ", \"time\": %.3f", tv);
        strlcat(ev, t, sizeof ev);
    }
    if (sa) {
        char x[256];
        snprintf(x, sizeof x,
                 ", \"best_miss_streak\": %d, \"perfect_streak\": %d, \"perfect_hits\": %d, \"late_streak\": %d, "
                 "\"late_hits\": %d, \"score\": %d, \"multiplier\": %d, \"best_multiplier\": %d",
                 q[0x64 / 4], q[0x90 / 4], q[0x94 / 4], q[0x98 / 4], q[0x9C / 4], q[0x118 / 4], q[0x11C / 4],
                 q[0x120 / 4]);
        strlcat(ev, x, sizeof ev);
        add_ints(ev, sizeof ev, "phrases", &q[0xA0 / 4], 4);
        add_ints(ev, sizeof ev, "phrase_streaks", &q[0xB0 / 4], 4);
        add_ints(ev, sizeof ev, "best_phrase_streaks", &q[0xC0 / 4], 4);
    }
    strlcat(ev, "}", sizeof ev);
    send_event(ev, 0);
    return 1;
}

static void *stats_watch(void *arg) {
    (void)arg;
    uint8_t *buf = own_alloc(CHUNK);
    stats_search *ss = own_alloc(sizeof *ss);
    uint64_t vt[2] = {NOTE_STATS_VTABLE + g_slide, SCORE_ATTACK_VTABLE + g_slide};
    uint64_t note = 0, sa = 0;
    double last_scan = 0;
    unsigned tries = 0;
    for (;;) {
        pthread_mutex_lock(&g_state_lock);
        int have = g_have_arr;
        pthread_mutex_unlock(&g_state_lock);
        if (!g_overlay || !have) {
            if (note) send_event("{\"event\": \"stats\", \"live\": false}", 1);
            note = sa = 0;
            usleep(500000);
            continue;
        }
        if (note && !stats_alive(note, vt[0])) {
            logline("note statistics at %llx freed", (unsigned long long)note);
            send_event("{\"event\": \"stats\", \"live\": false}", 1);
            note = sa = 0;
        }
        if (sa && !stats_alive(sa, vt[1])) sa = 0;
        // Narrow scans every 2 s, a full one (everything, or nothing learned yet) at most every 10 s.
        double t = now_s();
        tagset tags;
        const tagset *only = tries % 5 != 4 ? tags_for(TAGS_STATS, &tags) : NULL;
        if (!note && t - last_scan >= (only ? 2 : 10)) {
            last_scan = t;
            tries++;
            ss->want[0] = vt[0], ss->want[1] = vt[1];
            ss->n[0] = ss->n[1] = 0;
            scan(buf, only, find_stats, ss);
            if (ss->n[0]) {
                // More than one: the newest object is most likely the last one allocated; keep
                // the one whose hits change if that ever matters (not seen so far).
                note = ss->hits[0][ss->n[0] - 1];
                sa = ss->n[1] ? ss->hits[1][ss->n[1] - 1] : 0;
                tags_learn(TAGS_STATS, note);
                if (sa) tags_learn(TAGS_STATS, sa);
                logline("note statistics at %llx (%d found)%s", (unsigned long long)note, ss->n[0],
                        sa ? ", Score Attack" : "");
            }
        }
        if (note && !emit_stats(note, sa)) note = sa = 0;
        usleep(note ? 250000 : 500000);
    }
    return NULL;
}

// ================================================================ start

static void find_images(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            g_slide = (uint64_t)_dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    Dl_info info;
    if (dladdr((void *)find_images, &info) && info.dli_fbase) {
        const struct mach_header_64 *h = info.dli_fbase;
        const struct load_command *lc = (const void *)(h + 1);
        uint64_t text_vm = 0, lo = ~0ULL, hi = 0;
        for (uint32_t i = 0; i < h->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
            if (lc->cmd != LC_SEGMENT_64) continue;
            const struct segment_command_64 *sg = (const void *)lc;
            if (!strcmp(sg->segname, "__TEXT")) text_vm = sg->vmaddr;
            if (!strcmp(sg->segname, "__PAGEZERO")) continue;
            if (sg->vmaddr < lo) lo = sg->vmaddr;
            if (sg->vmaddr + sg->vmsize > hi) hi = sg->vmaddr + sg->vmsize;
        }
        uint64_t slide = (uint64_t)info.dli_fbase - text_vm;
        g_own_lo = lo + slide, g_own_hi = hi + slide;
    }
}

__attribute__((constructor)) static void init(void) {
    char dir[1024];
    if (!data_dir(dir, sizeof dir)) return;
    log_open(dir, "rscompanion.log");
    find_images();
    logline("rscompanion prototype loaded (pid %d, image slide 0x%llx)", getpid(), (unsigned long long)g_slide);
    snprintf(g_tags_file, sizeof g_tags_file, "%s/rscompanion_tags.txt", dir);
    snprintf(g_config_file, sizeof g_config_file, "%s/rscompanion.json", dir);
    config_poll();
    logline("lead time %d ms; events to %s/events.sock", g_lead_ms, dir);
    events_open(dir);
    tags_load();
    for (int k = 0; k < NTAGS; k++) {
        char s[1024];
        tags_str(&g_tags[k], s, sizeof s);
        logline("known memory tags for %s:%s", TAG_NAMES[k], s[0] ? s : " (none yet: first scans cover everything)");
    }
    pthread_t th;
    void *(*threads[])(void *) = {worker, searcher, banner_watch, tracker, stats_watch};
    for (size_t i = 0; i < sizeof threads / sizeof threads[0]; i++)
        if (pthread_create(&th, NULL, threads[i], NULL) == 0) pthread_detach(th);
}
