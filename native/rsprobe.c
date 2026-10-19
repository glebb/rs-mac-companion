// rsprobe: external memory reader for Rocksmith 2014 (macOS).
// Attaches read-only to the running game with task_for_pid (needs the
// com.apple.security.cs.debugger entitlement). Serves a line-based command
// protocol on /tmp/rsprobe.sock (see tools/discovery/probe.py for the commands).
// Only scans writable data regions; never reads the game's (encrypted) code.
// Usage: rsprobe <pid>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCK_PATH "/tmp/rsprobe.sock"
#define CHUNK (1 << 20)

typedef struct { mach_vm_address_t a; mach_vm_size_t s; } region_t;

static mach_port_t g_task;
static region_t g_regions[65536];
static int g_nregions;

static void load_regions(void) {
    g_nregions = 0;
    mach_vm_address_t a = 0;
    for (;;) {
        mach_vm_size_t s = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (mach_vm_region(g_task, &a, &s, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE) && !(info.protection & VM_PROT_EXECUTE) && g_nregions < 65536)
            g_regions[g_nregions++] = (region_t){a, s};
        a += s;
    }
}

static int safe_read(uint64_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(g_task, addr, len, (mach_vm_address_t)buf, &got) == KERN_SUCCESS && got == len;
}

static void out(int fd, const char *fmt, ...) {
    char b[4096];
    va_list ap; va_start(ap, fmt); int n = vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    if (n > 0) write(fd, b, n < (int)sizeof b ? n : (int)sizeof b - 1);
}

static int hexval(char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }

// Generic pattern search over writable regions. Calls back on every match.
typedef void (*hit_fn)(uint64_t addr, void *ctx);
static void search(const uint8_t *pat, size_t plen, size_t align, hit_fn fn, void *ctx, size_t max, size_t *nhits) {
    static uint8_t buf[CHUNK + 64];
    *nhits = 0;
    for (int r = 0; r < g_nregions && *nhits < max; r++) {
        for (mach_vm_size_t off = 0; off < g_regions[r].s && *nhits < max; off += CHUNK) {
            size_t len = g_regions[r].s - off < CHUNK ? g_regions[r].s - off : CHUNK;
            uint64_t base = g_regions[r].a + off;
            if (!safe_read(base, buf, len)) continue;
            for (size_t i = 0; i + plen <= len; i += align) {
                if (buf[i] == pat[0] && memcmp(buf + i, pat, plen) == 0) {
                    uint64_t at = base + i;
                    fn(at, ctx); if (++*nhits >= max) break;
                }
            }
        }
    }
}

static void print_hit(uint64_t a, void *ctx) { out(*(int *)ctx, "%llx\n", a); }


// Integer candidates for snapshot diffing: address + last seen value.
static uint64_t *g_iaddr; static int32_t *g_ival; static size_t g_ni, g_capi;

static void snap_i32(int32_t lo, int32_t hi) {
    static int32_t buf[CHUNK / 4];
    g_ni = 0;
    for (int r = 0; r < g_nregions; r++)
        for (mach_vm_size_t off = 0; off < g_regions[r].s; off += CHUNK) {
            size_t len = g_regions[r].s - off < CHUNK ? g_regions[r].s - off : CHUNK;
            uint64_t base = g_regions[r].a + off;
            if (!safe_read(base, buf, len)) continue;
            for (size_t i = 0; i < len / 4; i++)
                if (buf[i] >= lo && buf[i] <= hi) {
                    if (g_ni == g_capi) { g_capi = g_capi ? g_capi * 2 : 1 << 20; g_iaddr = realloc(g_iaddr, g_capi * 8); g_ival = realloc(g_ival, g_capi * 4); }
                    g_iaddr[g_ni] = base + i * 4; g_ival[g_ni++] = buf[i];
                }
        }
}

// mode: 'e' value == n, 'c' changed, 's' same, 'd' value == old + n
static void filter_i32(char mode, int32_t n) {
    size_t k = 0;
    for (size_t i = 0; i < g_ni; i++) {
        int32_t v; if (!safe_read(g_iaddr[i], &v, 4)) continue;
        int keep = mode == 'e' ? v == n : mode == 'c' ? v != g_ival[i] : mode == 's' ? v == g_ival[i] : v == g_ival[i] + n;
        if (keep) { g_iaddr[k] = g_iaddr[i]; g_ival[k++] = v; }
    }
    g_ni = k;
}

// Multi-type timer search: float seconds, double seconds and int32 milliseconds at once.
// Timer search. Each candidate keeps its value AND the moment it was read, so a filter pass
// compares each value against its own elapsed time: pass duration (hundreds of ms on millions
// of candidates) cannot skew the result.
// Arrays come straight from mmap and go back with munmap, so the hundreds of MB used during a
// search are really returned to the system afterwards (free() lets macOS keep them attached).
enum { T_F32S, T_F64S, T_I32MS, T_F32MS, T_F64MS, NTYPES };
static const char *g_tnames[NTYPES] = {"f32", "f64", "i32ms", "f32ms", "f64ms"};
typedef struct { uint64_t *a; float *v; float *t; size_t n, cap; } tset_t;
static tset_t g_t[NTYPES];

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static void *grow(void *old, size_t old_bytes, size_t new_bytes) {
    void *p = mmap(0, new_bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) return 0;
    if (old) { memcpy(p, old, old_bytes); munmap(old, old_bytes); }
    return p;
}

static void tadd(tset_t *t, uint64_t a, double v, float when) {
    if (t->n == t->cap) {
        size_t cap = t->cap ? t->cap * 2 : 1 << 20;
        uint64_t *na = grow(t->a, t->cap * 8, cap * 8);
        float *nv = grow(t->v, t->cap * 4, cap * 4), *nt = grow(t->t, t->cap * 4, cap * 4);
        if (!na || !nv || !nt) return;  // out of memory: keep what we have
        t->a = na; t->v = nv; t->t = nt; t->cap = cap;
    }
    t->a[t->n] = a; t->v[t->n] = (float)v; t->t[t->n++] = when;
}

static void tfree_all(void) {
    for (int t = 0; t < NTYPES; t++) {
        if (g_t[t].a) munmap(g_t[t].a, g_t[t].cap * 8);
        if (g_t[t].v) munmap(g_t[t].v, g_t[t].cap * 4);
        if (g_t[t].t) munmap(g_t[t].t, g_t[t].cap * 4);
        g_t[t] = (tset_t){0};
    }
}

static int tsize(int type) { return type == T_F64S || type == T_F64MS ? 8 : 4; }

// Value in seconds.
static double tread(int type, const uint8_t *p) {
    float f; double d; int32_t i;
    switch (type) {
        case T_F32S: memcpy(&f, p, 4); return f;
        case T_F64S: memcpy(&d, p, 8); return d;
        case T_I32MS: memcpy(&i, p, 4); return i / 1000.0;
        case T_F32MS: memcpy(&f, p, 4); return f / 1000.0;
        default: memcpy(&d, p, 8); return d / 1000.0;
    }
}

// group 0: float/double seconds + int milliseconds; group 1: float/double milliseconds;
// group 2: double seconds only (Rocksmith's song timer; few candidates, little memory).
static void snap_timers(int group) {
    static uint8_t buf[CHUNK];
    tfree_all();
    for (int r = 0; r < g_nregions; r++)
        for (mach_vm_size_t off = 0; off < g_regions[r].s; off += CHUNK) {
            size_t len = g_regions[r].s - off < CHUNK ? g_regions[r].s - off : CHUNK;
            uint64_t base = g_regions[r].a + off;
            if (!safe_read(base, buf, len)) continue;
            float when = (float)now_s();
            for (size_t i = 0; i + 8 <= len; i += 4) {
                int t0 = group == 0 ? T_F32S : T_F32MS, t1 = group == 1 ? T_F64MS : T_F64S;
                double v;
                if (group != 2) { v = tread(t0, buf + i); if (v >= 0.5 && v <= 1000) tadd(&g_t[t0], base + i, v, when); }
                if (!(i & 7)) { v = tread(t1, buf + i); if (v >= 0.5 && v <= 1000) tadd(&g_t[t1], base + i, v, when); }
                if (group == 0) { v = tread(T_I32MS, buf + i); if (v >= 0.5 && v <= 1000) tadd(&g_t[T_I32MS], base + i, v, when); }
            }
        }
}

// Keep candidates whose value advanced at a rate in [lo, hi] seconds per second since it was
// last read. Candidates are in address order, so they are read through a 1 MB window.
static void rate_timers(double lo, double hi) {
    static uint8_t win[CHUNK];
    for (int t = 0; t < NTYPES; t++) {
        tset_t *ts = &g_t[t]; uint64_t wbase = 0, wlen = 0; size_t k = 0; float when = 0;
        for (size_t i = 0; i < ts->n; i++) {
            uint64_t a = ts->a[i];
            if (a < wbase || a + 8 > wbase + wlen) {
                wlen = 0;
                for (int r = 0; r < g_nregions; r++)
                    if (a >= g_regions[r].a && a < g_regions[r].a + g_regions[r].s) {
                        wbase = a & ~(uint64_t)0xfff;
                        uint64_t end = g_regions[r].a + g_regions[r].s;
                        wlen = end - wbase < CHUNK ? end - wbase : CHUNK;
                        if (!safe_read(wbase, win, wlen)) wlen = 0;
                        when = (float)now_s();
                        break;
                    }
                if (!wlen || a + tsize(t) > wbase + wlen) continue;
            }
            double v = tread(t, win + (a - wbase)), dt = when - ts->t[i];
            if (dt < 0.2) { ts->a[k] = a; ts->v[k] = ts->v[i]; ts->t[k++] = ts->t[i]; continue; }  // too soon to judge
            double rate = (v - ts->v[i]) / dt;
            if (rate >= lo && rate <= hi) { ts->a[k] = a; ts->v[k] = (float)v; ts->t[k++] = when; }
        }
        ts->n = k;
    }
}

static void tcounts(int fd) {
    out(fd, "tcands");
    for (int t = 0; t < NTYPES; t++) out(fd, " %zu", g_t[t].n);
    out(fd, "\n");
}

static void handle(int fd, char *line) {
    char cmd[32] = {0}; char arg1[1024] = {0}; char arg2[64] = {0};
    sscanf(line, "%31s %1023s %63s", cmd, arg1, arg2);
    if (!strcmp(cmd, "ping")) { out(fd, "pong pid=%d\n", getpid()); }
    else if (!strcmp(cmd, "regions")) {
        load_regions(); uint64_t tot = 0;
        for (int i = 0; i < g_nregions; i++) tot += g_regions[i].s;
        out(fd, "regions=%d bytes=%llu\n", g_nregions, tot);
    } else if (!strcmp(cmd, "findhex")) {  // findhex <hexbytes> [max]
        uint8_t pat[512]; size_t n = strlen(arg1) / 2; if (n > 512) n = 512;
        for (size_t i = 0; i < n; i++) pat[i] = hexval(arg1[2 * i]) << 4 | hexval(arg1[2 * i + 1]);
        size_t max = arg2[0] ? strtoull(arg2, 0, 10) : 200, nh; load_regions();
        search(pat, n, 1, print_hit, &fd, max, &nh); out(fd, "end %zu\n", nh);
    } else if (!strcmp(cmd, "findptr")) {  // findptr <hexaddr> [max]
        uint64_t v = strtoull(arg1, 0, 16); size_t max = arg2[0] ? strtoull(arg2, 0, 10) : 200, nh; load_regions();
        search((uint8_t *)&v, 8, 8, print_hit, &fd, max, &nh); out(fd, "end %zu\n", nh);
    } else if (!strcmp(cmd, "findrange")) {  // findrange <lo> <hi>: aligned qwords whose value is in [lo,hi)
        uint64_t lo = strtoull(arg1, 0, 16), hi = strtoull(arg2, 0, 16); size_t nh = 0;
        static uint64_t buf[CHUNK / 8]; load_regions();
        for (int r = 0; r < g_nregions && nh < 500; r++)
            for (mach_vm_size_t off = 0; off < g_regions[r].s && nh < 500; off += CHUNK) {
                size_t len = g_regions[r].s - off < CHUNK ? g_regions[r].s - off : CHUNK;
                uint64_t base = g_regions[r].a + off;
                if (!safe_read(base, buf, len)) continue;
                for (size_t i = 0; i < len / 8; i++)
                    if (buf[i] >= lo && buf[i] < hi) { out(fd, "%llx %llx\n", base + i * 8, buf[i]); if (++nh >= 500) break; }
            }
        out(fd, "end %zu\n", nh);
    } else if (!strcmp(cmd, "read")) {  // read <hexaddr> <len>
        uint64_t a = strtoull(arg1, 0, 16); size_t n = strtoull(arg2, 0, 10); if (n > 4096) n = 4096;
        uint8_t b[4096];
        if (!safe_read(a, b, n)) { out(fd, "err\n"); return; }
        char h[8200]; for (size_t i = 0; i < n; i++) sprintf(h + 2 * i, "%02x", b[i]); h[2 * n] = 0;
        out(fd, "%s\n", h);
    }
    else if (!strcmp(cmd, "snapt")) { load_regions(); snap_timers(atoi(arg1)); tcounts(fd); }  // snapt <group 0/1/2>
    else if (!strcmp(cmd, "ratet")) { rate_timers(strtod(arg1, 0), strtod(arg2, 0)); tcounts(fd); }  // ratet <lo> <hi>
    else if (!strcmp(cmd, "tfree")) { tfree_all(); out(fd, "ok\n"); }  // release search memory
    else if (!strcmp(cmd, "tlist")) {
        for (int t = 0; t < NTYPES; t++)
            for (size_t i = 0; i < g_t[t].n && i < 50; i++) out(fd, "%s %llx %.3f\n", g_tnames[t], g_t[t].a[i], g_t[t].v[i]);
        out(fd, "end\n");
    }
    else if (!strcmp(cmd, "snapi")) { load_regions(); snap_i32(atoi(arg1), atoi(arg2)); out(fd, "icands %zu\n", g_ni); }
    else if (!strcmp(cmd, "filteri")) { filter_i32(arg1[0], atoi(arg2)); out(fd, "icands %zu\n", g_ni); }
    else if (!strcmp(cmd, "icands")) {
        size_t max = arg1[0] ? strtoull(arg1, 0, 10) : 50;
        for (size_t i = 0; i < g_ni && i < max; i++) { int32_t v = 0; safe_read(g_iaddr[i], &v, 4); out(fd, "%llx %d\n", g_iaddr[i], v); }
        out(fd, "end %zu\n", g_ni);
    }
    else out(fd, "unknown\n");
}

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void *client(void *arg) {
    int c = (int)(intptr_t)arg;
    struct timeval tv = {.tv_sec = 5};
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    char line[2048]; size_t n = 0; char ch;
    while (read(c, &ch, 1) == 1) {
        if (ch == '\n') {
            line[n] = 0; n = 0;
            // Plain reads touch no shared state, so they never wait behind a long scan.
            int shared = strncmp(line, "read ", 5) && strncmp(line, "ping", 4);
            if (shared) pthread_mutex_lock(&g_lock);
            handle(c, line);
            if (shared) pthread_mutex_unlock(&g_lock);
        }
        else if (n < sizeof line - 1) line[n++] = ch;
    }
    close(c);
    return 0;
}

static void *server(void *unused) {
    (void)unused;
    unlink(SOCK_PATH);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = {.sun_family = AF_UNIX}; strcpy(sa.sun_path, SOCK_PATH);
    // The socket gives read access to the game's memory: only this user may connect
    // (connecting needs write permission on the socket file).
    mode_t old = umask(077);
    int bound = bind(s, (struct sockaddr *)&sa, sizeof sa);
    umask(old);
    if (bound || chmod(SOCK_PATH, 0600) || listen(s, 16)) return 0;
    for (;;) {
        int c = accept(s, 0, 0); if (c < 0) continue;
        pthread_t t; pthread_create(&t, 0, client, (void *)(intptr_t)c); pthread_detach(t);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: rsprobe <pid>\n"); return 2; }
    kern_return_t k = task_for_pid(mach_task_self(), atoi(argv[1]), &g_task);
    if (k != KERN_SUCCESS) { fprintf(stderr, "task_for_pid failed: %s\n", mach_error_string(k)); return 1; }
    fprintf(stderr, "attached to %s, serving %s\n", argv[1], SOCK_PATH);
    server(0);
    return 0;
}
