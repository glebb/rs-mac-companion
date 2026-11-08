// lp_probe: a mod for RS Re-ARMed Learn & Play (the Windows game, 32-bit guest) that finds what the
// companion reads from memory there. It changes nothing in the game. Build and test: tools/lp_probe.sh.
//
// It hooks ak_post_event_name (Wwise PostEvent by name) and logs the events. When the game posts
// Play_<key> for a song it has (an archive's table of contents lists songs/bin/generic/<key>_*.sng),
// it scans the 4 GB guest window 8 s and 25 s later and logs:
//   names   the string objects holding each arrangement name <key>_<arr> (MSVC std::string: text or
//           pointer at +0, size at +16, capacity at +20), and the dwords before them that point into
//           the image's read-only data (vtable candidates), tallied by value and distance;
//   play    the string objects holding "Play_<key>", with the 48 bytes from each read twice 300 ms
//           apart (the Mac's play record has the song position after the name);
//   stats   objects with the int32 111000 at +8 and an image pointer at +0 (RockSniffer's note
//           statistics on Windows), tallied by that pointer, with their counters read twice;
//   timer   doubles that advance 1 s per second, next to the seconds since Play_<key>.
// Log: ~/Library/Application Support/rs-mac-companion/lp_probe.log, and stderr (the game's log).
#include <dirent.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>

#include "../native/rsfile.h"

#ifndef LP_PROBE_TEST
#include "rc_mod.h"
#endif

// ---------------------------------------------------------------- log

static FILE *g_log;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static double now_s(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static void logf_(const char *fmt, ...) {
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    pthread_mutex_lock(&g_log_lock);
    fprintf(stderr, "[lp_probe] %s\n", line);
    if (g_log) {
        fprintf(g_log, "%.3f %s\n", now_s(), line);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_log_lock);
}

// ---------------------------------------------------------------- the guest window

static uint64_t g_base;                  // host address of guest address 0
static uint64_t g_window = 1ULL << 32;   // its size
// The image's read-only data, where vtables are (image 0xf80000, .text ends 0x1c36bec)
static uint32_t g_rdata_lo = 0x1c37000, g_rdata_hi = 0x2000000;

static int rd(uint32_t g, void *buf, size_t n) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), g_base + g, n, (mach_vm_address_t)buf, &got) == KERN_SUCCESS &&
           got == n;
}
static uint32_t rd32(uint32_t g) {
    uint32_t v = 0;
    return rd(g, &v, 4) ? v : 0;
}
static int is_rdata(uint32_t v) { return v >= g_rdata_lo && v < g_rdata_hi; }

#define CHUNK (1u << 20)
typedef int (*chunk_fn)(uint32_t g, const uint8_t *d, size_t len, void *ctx);

// Calls fn on every readable part of the window, a chunk at a time; returns the bytes read.
static uint64_t scan(uint8_t *buf, chunk_fn fn, void *ctx) {
    uint64_t total = 0;
    mach_vm_address_t addr = g_base;
    while (addr < g_base + g_window) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count,
                           &obj) != KERN_SUCCESS)
            break;
        if (addr >= g_base + g_window) break;
        uint64_t end = addr + size < g_base + g_window ? addr + size : g_base + g_window;
        if (info.protection & VM_PROT_READ) {
            for (uint64_t a = addr; a < end; a += CHUNK) {
                size_t n = end - a < CHUNK ? (size_t)(end - a) : CHUNK;
                mach_vm_size_t got = 0;
                if (mach_vm_read_overwrite(mach_task_self(), a, n, (mach_vm_address_t)buf, &got) != KERN_SUCCESS) continue;
                total += got;
                if (!fn((uint32_t)(a - g_base), buf, (size_t)got, ctx)) return total;
            }
        }
        addr = end;
    }
    return total;
}

// ---------------------------------------------------------------- text and pointers

#define MAXHITS 256
typedef struct { const char *pat; size_t plen; uint32_t hits[MAXHITS]; int n; } text_search;

static int find_text(uint32_t g, const uint8_t *d, size_t len, void *ctx) {
    text_search *ts = ctx;
    const uint8_t *p = d, *end = d + len;
    while (p < end && (p = memmem(p, (size_t)(end - p), ts->pat, ts->plen))) {
        if (ts->n < MAXHITS) ts->hits[ts->n++] = g + (uint32_t)(p - d);
        p++;
    }
    return 1;
}

typedef struct { const uint32_t *want; int nwant; uint32_t holder[MAXHITS], value[MAXHITS]; int n; } ptr_search;

static int find_ptrs(uint32_t g, const uint8_t *d, size_t len, void *ctx) {
    ptr_search *ps = ctx;
    for (size_t i = 0; i + 4 <= len; i += 4) {
        uint32_t v;
        memcpy(&v, d + i, 4);
        for (int k = 0; k < ps->nwant; k++)
            if (v == ps->want[k] && ps->n < MAXHITS) {
                ps->holder[ps->n] = g + (uint32_t)i;
                ps->value[ps->n++] = v;
            }
    }
    return 1;
}

// String objects holding text (len bytes, without its 0): MSVC std::string, 24 bytes, the text
// inline while the capacity is under 16, else a pointer to it. Fills out[] with the objects.
static int string_objects(uint8_t *buf, const char *text, uint32_t *out, int max, int *raw_hits) {
    size_t len = strlen(text);
    static text_search ts;
    ts.pat = text, ts.plen = len + 1, ts.n = 0;
    scan(buf, find_text, &ts);
    *raw_hits = ts.n;
    int n = 0;
    for (int i = 0; i < ts.n && n < max; i++)
        if (len < 16 && rd32(ts.hits[i] + 16) == len && rd32(ts.hits[i] + 20) == 15) out[n++] = ts.hits[i];
    if (len >= 16 || n == 0) {
        static ptr_search ps;
        ps.want = ts.hits, ps.nwant = ts.n, ps.n = 0;
        if (ts.n) scan(buf, find_ptrs, &ps);
        for (int i = 0; i < ps.n && n < max; i++) {
            uint32_t size = rd32(ps.holder[i] + 16), cap = rd32(ps.holder[i] + 20);
            if (size == len && cap >= len && cap < 4096) out[n++] = ps.holder[i];
            else logf_("  pointer to \"%s\" at %08x, not a string object (size %u, capacity %u)", text, ps.holder[i], size,
                       cap);
        }
    }
    return n;
}

static void dump_bytes(const char *what, uint32_t g, const uint8_t *b, size_t n) {
    char line[1024];
    size_t at = 0;
    for (size_t i = 0; i < n; i += 4) {
        uint32_t v;
        float f;
        memcpy(&v, b + i, 4);
        memcpy(&f, b + i, 4);
        at += (size_t)snprintf(line + at, sizeof line - at, " +%02zx=%08x", i, v);
        if (f > 0.01f && f < 100000.0f) at += (size_t)snprintf(line + at, sizeof line - at, "(%.3gf)", f);
        if (at > sizeof line - 40) break;
    }
    logf_("  %s %08x:%s", what, g, line);
}

static void dump(const char *what, uint32_t g, size_t n) {
    uint8_t b[256];
    if (n <= sizeof b && rd(g, b, n)) dump_bytes(what, g, b, n);
}

// ---------------------------------------------------------------- the searches

#define MAXARR 12
typedef struct { char key[128]; char arr[MAXARR][128]; int narr; double played_at; } song_ref;

static void names_search(uint8_t *buf, const song_ref *s) {
    double t0 = now_s();
    uint32_t objs[MAXARR][32];
    int nobj[MAXARR];
    for (int a = 0; a < s->narr; a++) {
        int raw;
        nobj[a] = string_objects(buf, s->arr[a], objs[a], 32, &raw);
        char at[512] = "";
        for (int i = 0; i < nobj[a] && strlen(at) < 480; i++) snprintf(at + strlen(at), sizeof at - strlen(at), " %08x", objs[a][i]);
        logf_("names: %s: %d copies of the text, %d string objects:%s", s->arr[a], raw, nobj[a], at);
    }
    // Tally (value, distance) of image pointers before the string objects
    typedef struct { uint32_t v, o; int names, objs; uint32_t mask; } cand;
    static cand c[4096];
    int nc = 0;
    for (int a = 0; a < s->narr; a++)
        for (int i = 0; i < nobj[a]; i++)
            for (uint32_t o = 4; o <= 0x200 && o <= objs[a][i]; o += 4) {
                uint32_t v = rd32(objs[a][i] - o);
                if (!is_rdata(v)) continue;
                int k = 0;
                while (k < nc && (c[k].v != v || c[k].o != o)) k++;
                if (k == nc) {
                    if (nc == 4096) continue;
                    c[nc++] = (cand){v, o, 0, 0, 0};
                }
                c[k].objs++;
                if (!(c[k].mask & 1u << a)) c[k].mask |= 1u << a, c[k].names++;
            }
    for (int pass = 0; pass < 15; pass++) {
        int best = -1;
        for (int k = 0; k < nc; k++)
            if (c[k].names >= 0 && (best < 0 || c[k].names > c[best].names ||
                                    (c[k].names == c[best].names && c[k].objs > c[best].objs)))
                best = k;
        if (best < 0 || c[best].names < 2) break;
        logf_("names: image pointer %08x at name-0x%x: %d of %d names, %d objects", c[best].v, c[best].o, c[best].names,
              s->narr, c[best].objs);
        c[best].names = -1;
    }
    // The objects around the top candidate, for the record
    logf_("names: done in %.1f s", now_s() - t0);
}

static void play_search(uint8_t *buf, const song_ref *s) {
    char text[160];
    snprintf(text, sizeof text, "Play_%s", s->key);
    uint32_t objs[16];
    int raw, n = string_objects(buf, text, objs, 16, &raw);
    logf_("play: \"%s\": %d copies of the text, %d string objects", text, raw, n);
    uint8_t a[16][64], b[16][64];
    for (int i = 0; i < n; i++) rd(objs[i], a[i], 64);
    usleep(300000);
    for (int i = 0; i < n; i++) {
        rd(objs[i], b[i], 64);
        dump_bytes("play: first ", objs[i], a[i], 64);
        dump_bytes("play: 0.3 s ", objs[i], b[i], 64);
        char changed[256] = "";
        for (int k = 0; k < 64; k += 4)
            if (memcmp(a[i] + k, b[i] + k, 4)) snprintf(changed + strlen(changed), sizeof changed - strlen(changed), " +%02x", k);
        logf_("play: %08x changed at:%s", objs[i], changed[0] ? changed : " (nothing)");
    }
}

typedef struct { uint32_t obj[512], vt[512]; int n; } stats_search;

static int find_stats(uint32_t g, const uint8_t *d, size_t len, void *ctx) {
    stats_search *ss = ctx;
    for (size_t i = 8; i + 4 <= len; i += 4) {
        int32_t m;
        memcpy(&m, d + i, 4);
        if (m != 111000) continue;
        uint32_t vt;
        memcpy(&vt, d + i - 8, 4);
        if (is_rdata(vt) && ss->n < 512) ss->obj[ss->n] = g + (uint32_t)i - 8, ss->vt[ss->n++] = vt;
    }
    return 1;
}

static void stats_search_run(uint8_t *buf) {
    static stats_search ss;
    ss.n = 0;
    double t0 = now_s();
    uint64_t bytes = scan(buf, find_stats, &ss);
    logf_("stats: %d objects with 111000 at +8 and an image pointer at +0 (%.0f MB in %.1f s)", ss.n, bytes / 1048576.0,
          now_s() - t0);
    uint32_t seen[16];
    int nseen = 0;
    for (int i = 0; i < ss.n && nseen < 16; i++) {
        int k = 0;
        while (k < nseen && seen[k] != ss.vt[i]) k++;
        if (k < nseen) continue;
        seen[nseen++] = ss.vt[i];
        int count = 0;
        for (int j = 0; j < ss.n; j++) count += ss.vt[j] == ss.vt[i];
        logf_("stats: type %08x: %d objects", ss.vt[i], count);
        for (int j = 0, shown = 0; j < ss.n && shown < 3; j++)
            if (ss.vt[j] == ss.vt[i]) {
                dump("stats:", ss.obj[j], 0xc0);
                shown++;
            }
    }
}

// Doubles that tick 1 s per second
typedef struct { uint32_t *a; float *v; size_t n, cap; } dset;

static int snap_doubles(uint32_t g, const uint8_t *d, size_t len, void *ctx) {
    dset *ds = ctx;
    for (size_t i = 0; i + 8 <= len; i += 8) {
        double v;
        memcpy(&v, d + i, 8);
        if (!(v >= 0.5 && v <= 2000)) continue;
        if (ds->n == ds->cap) {
            size_t cap = ds->cap ? ds->cap * 2 : 1 << 20;
            uint32_t *na = mmap(NULL, cap * 4, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            float *nv = mmap(NULL, cap * 4, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (na == MAP_FAILED || nv == MAP_FAILED) return 0;
            if (ds->a) memcpy(na, ds->a, ds->n * 4), memcpy(nv, ds->v, ds->n * 4), munmap(ds->a, ds->cap * 4), munmap(ds->v, ds->cap * 4);
            ds->a = na, ds->v = nv, ds->cap = cap;
        }
        ds->a[ds->n] = g + (uint32_t)i, ds->v[ds->n++] = (float)v;
    }
    return 1;
}

static void timer_search(uint8_t *buf, const song_ref *s) {
    static dset ds;
    ds.n = 0;
    double t0 = now_s();
    uint64_t bytes = scan(buf, snap_doubles, &ds);
    size_t snapped = ds.n;
    double t_prev = now_s();
    for (int pass = 0; pass < 2; pass++) {
        usleep(1000000);
        double t = now_s(), dt = t - t_prev;
        size_t k = 0;
        uint32_t wlo = 1, whi = 0;  // the chunk in buf: [wlo, whi)
        for (size_t i = 0; i < ds.n; i++) {
            uint32_t a = ds.a[i];
            if (a < wlo || a + 8 > whi) {
                wlo = a & ~0xfffu;
                uint32_t n = CHUNK;
                while (n >= 0x1000 && !rd(wlo, buf, n)) n /= 2;  // shorter near a region's end
                whi = n >= 0x1000 ? wlo + n : wlo;
                if (a + 8 > whi) continue;
            }
            double v;
            memcpy(&v, buf + (a - wlo), 8);
            double rate = (v - ds.v[i]) / dt;
            if (rate >= 0.9 && rate <= 1.1) ds.a[k] = ds.a[i], ds.v[k++] = (float)v;
        }
        ds.n = k;
        t_prev = t;
    }
    logf_("timer: %zu doubles in %.0f MB, %zu ticking (%.1f s); %.2f s since Play_%s", snapped, bytes / 1048576.0, ds.n,
          now_s() - t0, now_s() - s->played_at, s->key);
    for (size_t i = 0; i < ds.n && i < 40; i++) {
        double v;
        if (rd(ds.a[i], &v, 8)) logf_("timer: %08x = %.3f", ds.a[i], v);
    }
}

// ---------------------------------------------------------------- songs: key -> arrangements

static char g_game_dir[1024];

// Arrangement names of key from the archives' tables of contents (songs/bin/generic/<key>_<arr>.sng)
static int song_arrangements(const char *key, song_ref *s) {
    char dir[1100];
    snprintf(dir, sizeof dir, "%s/dlc", g_game_dir);
    const char *dirs[2] = {dir, g_game_dir};
    char prefix[200];
    snprintf(prefix, sizeof prefix, "songs/bin/generic/%s_", key);
    size_t pl = strlen(prefix);
    s->narr = 0;
    for (int d = 0; d < 2 && !s->narr; d++) {
        DIR *dp = opendir(dirs[d]);
        struct dirent *e;
        while (dp && (e = readdir(dp)) && !s->narr) {
            if (!strstr(e->d_name, ".psarc")) continue;
            char path[1400];
            snprintf(path, sizeof path, "%s/%s", dirs[d], e->d_name);
            rs_psarc *p = rs_psarc_open(path);
            if (!p) continue;
            for (uint32_t i = 0; i < p->n && s->narr < MAXARR; i++) {
                const char *ep = p->e[i].path;
                size_t n = strlen(ep);
                if (strncasecmp(ep, prefix, pl) || n < 4 || strcmp(ep + n - 4, ".sng")) continue;
                snprintf(s->arr[s->narr++], sizeof s->arr[0], "%.*s", (int)(n - 4 - 18), ep + 18);
            }
            if (s->narr) logf_("song %s: %d arrangements in %s", key, s->narr, e->d_name);
            rs_psarc_close(p);
        }
        if (dp) closedir(dp);
    }
    snprintf(s->key, sizeof s->key, "%s", key);
    return s->narr;
}

// Statistics mode (built with -DLP_PROBE_STATS, tools/lp_probe.sh install stats): every second from
// Play_<key> on, the objects with 111000 at +8 and an image pointer at +0, and which of their first
// 0x200 bytes changed (int32, decimal; pointers in hex), to map their fields against the screen.
#define TRACK_BYTES 0x200
static void stats_track(uint8_t *buf, const song_ref *s, double seconds) {
    typedef struct { uint32_t obj, vt; int32_t last[TRACK_BYTES / 4]; } tracked;
    static tracked tr[8];
    int ntr = 0, ever = 0;
    double gone_since = 0;
    static stats_search ss;
    for (int tick = 0; now_s() < s->played_at + seconds; tick++) {
        while (now_s() < s->played_at + 2 + tick) usleep(20000);
        double at = now_s() - s->played_at;
        ss.n = 0;
        scan(buf, find_stats, &ss);
        for (int i = 0; i < ss.n && ntr < 8; i++) {
            int k = 0;
            while (k < ntr && tr[k].obj != ss.obj[i]) k++;
            if (k < ntr) continue;
            tr[ntr].obj = ss.obj[i], tr[ntr].vt = ss.vt[i];
            memset(tr[ntr].last, 0, sizeof tr[ntr].last);
            logf_("stats %5.1f s: new object %08x, type %08x", at, ss.obj[i], ss.vt[i]);
            ntr++, ever = 1;
        }
        for (int k = 0; k < ntr; k++) {
            int32_t now[TRACK_BYTES / 4];
            if (!rd(tr[k].obj, now, sizeof now) || (uint32_t)now[0] != tr[k].vt || now[2] != 111000) {
                logf_("stats %5.1f s: object %08x gone", at, tr[k].obj);
                tr[k--] = tr[--ntr];
                continue;
            }
            char line[2048];
            size_t len = 0;
            for (int w = 3; w < TRACK_BYTES / 4 && len < sizeof line - 32; w++) {
                if (now[w] == tr[k].last[w]) continue;
                int32_t v = now[w];
                len += (size_t)snprintf(line + len, sizeof line - len, v > -10000000 && v < 10000000 ? " +%x=%d" : " +%x=%08x",
                                        w * 4, v);
            }
            if (len) logf_("stats %5.1f s: %08x:%s", at, tr[k].obj, line);
            memcpy(tr[k].last, now, sizeof now);
        }
        if (ntr) gone_since = 0;
        else if (ever && !gone_since) gone_since = now_s();
        if (gone_since && now_s() - gone_since > 10) break;
    }
    logf_("stats: tracking done");
}

static void run_all(const song_ref *s, int round) {
    static uint8_t *buf;
    if (!buf) buf = mmap(NULL, CHUNK, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    logf_("---- round %d, %.1f s after Play_%s", round, now_s() - s->played_at, s->key);
    names_search(buf, s);
    play_search(buf, s);
    stats_search_run(buf);
    timer_search(buf, s);
    logf_("---- round %d done", round);
}

// ---------------------------------------------------------------- the event hook and its thread

static pthread_mutex_t g_ev_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_ev_cond = PTHREAD_COND_INITIALIZER;
static char g_pending[128];
static double g_pending_at;

static void *prober(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&g_ev_lock);
        while (!g_pending[0]) pthread_cond_wait(&g_ev_cond, &g_ev_lock);
        song_ref s = {0};
        snprintf(s.key, sizeof s.key, "%s", g_pending);
        s.played_at = g_pending_at;
        g_pending[0] = 0;
        pthread_mutex_unlock(&g_ev_lock);
        double t = now_s();
        if (!song_arrangements(s.key, &s)) {
            logf_("Play_%s: no archive has songs/bin/generic/%s_*.sng (%.0f ms): not a song", s.key, s.key,
                  (now_s() - t) * 1000);
            continue;
        }
        logf_("index lookup took %.0f ms", (now_s() - t) * 1000);
#ifndef LP_PROBE_TEST
        g_base = rc_slide;
#endif
#ifdef LP_PROBE_STATS
        static uint8_t *buf;
        if (!buf) buf = mmap(NULL, CHUNK, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        stats_track(buf, &s, 240);
#else
        while (now_s() < s.played_at + 8) usleep(100000);
        run_all(&s, 1);
        while (now_s() < s.played_at + 25) usleep(100000);
        run_all(&s, 2);
#endif
    }
    return NULL;
}

// Called on the game thread: cheap. Logs each event name the first time, Play_/Stop_ ones always.
static void on_event(const char *ev) {
    static char seen[512][64];
    static int nseen;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    if (!ev) return;
    int always = !strncmp(ev, "Play_", 5) || !strncmp(ev, "Stop_", 5) || !strncmp(ev, "Pause_", 6) ||
                 !strncmp(ev, "Resume_", 7);
    pthread_mutex_lock(&lock);
    int known = 0;
    for (int i = 0; i < nseen && !known; i++) known = !strncmp(seen[i], ev, 63);
    if (!known && nseen < 512) snprintf(seen[nseen++], 64, "%s", ev);
    pthread_mutex_unlock(&lock);
    if (always || !known) logf_("event: %s", ev);
    size_t n = strlen(ev);
    if (strncmp(ev, "Play_", 5) || n > 100 || (n > 8 && !strcmp(ev + n - 8, "_Preview"))) return;
    pthread_mutex_lock(&g_ev_lock);
    snprintf(g_pending, sizeof g_pending, "%s", ev + 5);
    g_pending_at = now_s();
    pthread_cond_signal(&g_ev_cond);
    pthread_mutex_unlock(&g_ev_lock);
}

static void open_log(void) {
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Application Support/rs-mac-companion/lp_probe.log", getenv("HOME"));
    g_log = fopen(path, "a");
    const char *gd = getenv("LP_GAME_DIR");
    if (gd && *gd) snprintf(g_game_dir, sizeof g_game_dir, "%s", gd);
    else snprintf(g_game_dir, sizeof g_game_dir, "%s/Library/Application Support/RS Re-ARMed/learn-play/game", getenv("HOME"));
}

#ifndef LP_PROBE_TEST
static int before_event(rc_ctx *c, void *user) {
    (void)user;
    OV_ARGS(a, c);
    on_event(OV_PTR(a, const char));
    return 0;
}

static unsigned long g_opens;
static int before_open(rc_ctx *c, void *user) {
    (void)user;
    OV_ARGS(a, c);
    (void)OV_PTR(a, void);
    const char *path = OV_PTR(a, const char);
    if (path && (++g_opens <= 40 || strstr(path, "song") || strstr(path, "psarc"))) logf_("frontend_open_file: %s", path);
    return 0;
}

__attribute__((constructor)) static void init(void) {
    open_log();
    logf_("loaded on %s, guest pointers of %d bytes, game folder %s", rc_target(), rc_guest_ptr_size, g_game_dir);
    if (rc_hook_add_name("ak_post_event_name", before_event, NULL, NULL)) logf_("no ak_post_event_name hook point");
    if (rc_hook_add_name("frontend_open_file", before_open, NULL, NULL)) logf_("no frontend_open_file hook point");
    pthread_t t;
    if (pthread_create(&t, NULL, prober, NULL) == 0) pthread_detach(t);
}
#else
// ---------------------------------------------------------------- self-test: a fake guest window

static volatile int g_stop;
static uint8_t *G(uint32_t g) { return (uint8_t *)(uintptr_t)(g_base + g); }
static void put32(uint32_t g, uint32_t v) { memcpy(G(g), &v, 4); }
static void put_str(uint32_t obj, uint32_t heap, const char *s) {  // MSVC std::string at obj
    size_t n = strlen(s);
    if (n < 16) memcpy(G(obj), s, n + 1), put32(obj + 20, 15);
    else memcpy(G(heap), s, n + 1), put32(obj, heap), put32(obj + 20, (uint32_t)n | 15);
    put32(obj + 16, (uint32_t)n);
}

static void *ticker(void *arg) {
    double t0 = now_s();
    while (!g_stop) {
        double t = 3 + now_s() - t0;
        memcpy(G(0x7000008), &t, 8);                // the song timer
        float pos = (float)t;
        int32_t ms = (int32_t)(t * 1000);
        memcpy(G(0x6800000 + 0x18), &pos, 4);        // play record: after the 24-byte string
        memcpy(G(0x6800000 + 0x1c), &ms, 4);
        put32(0x6900040, (uint32_t)(t * 10));  // note stats: a counter going up
        usleep(10000);
    }
    return arg;
}

int main(int argc, char **argv) {
    open_log();
    if (argc > 1) {  // lp_probe_test KEY: the index lookup alone, against the real game folder
        song_ref s = {0};
        int n = song_arrangements(argv[1], &s);
        for (int i = 0; i < n; i++) printf("%s\n", s.arr[i]);
        return n ? 0 : 1;
    }
    g_window = 256u << 20;
    void *w = mmap(NULL, g_window, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    g_base = (uint64_t)(uintptr_t)w;
    // arrangement objects: vtable 0x1d00100 at +0, name at +0x14; lead selected (twice)
    const char *names[] = {"testkey_lead", "testkey_lead", "testkey_rhythm", "testkey_bass_alternate"};
    for (int i = 0; i < 4; i++) {
        uint32_t o = 0x6000000 + (uint32_t)i * 0x1000;
        put32(o, 0x1d00100);
        put32(o + 0x10, 0x1d00200);  // another image pointer, in every object too
        put_str(o + 0x14, 0x6100000 + (uint32_t)i * 0x100, names[i]);
    }
    memcpy(G(0x6200000), "testkey_rhythm", 15);  // a loose copy of a name, not a string object
    put_str(0x6800000, 0, "Play_testkey");
    put32(0x6900000, 0x1d00300), put32(0x6900008, 111000), put32(0x6900030, 42);  // note stats
    put32(0x6910000, 0x1d00400), put32(0x6910008, 111000);                         // Score Attack
    put32(0x6920008, 111000);                                                       // a freed one: no type
    pthread_t t;
    pthread_create(&t, NULL, ticker, NULL);
    song_ref s = {.key = "testkey", .narr = 3, .played_at = now_s() - 3};
    snprintf(s.arr[0], 128, "testkey_lead");
    snprintf(s.arr[1], 128, "testkey_rhythm");
    snprintf(s.arr[2], 128, "testkey_bass_alternate");
    usleep(200000);
    run_all(&s, 1);
    s.played_at = now_s() - 2;
    stats_track(mmap(NULL, CHUNK, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), &s, 5);
    g_stop = 1;
    pthread_join(t, NULL);
    return 0;
}
#endif
