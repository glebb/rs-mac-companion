// rscore: what the in-game libraries share, whichever app they run in (Rocksmith:
// rscompanion.c, RockNRoller: rnrcompanion.c): the log, a song's arrangements and tone timelines
// read from its archive (rsfile.c), the tone at a time, the events to the companion app and its
// settings file. Declarations and the song types: rscore.h.
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "rscore.h"

const char *const SLOT_NAMES[5] = {"Base", "A", "B", "C", "D"};

// ================================================================ data folder, time and logging

int data_dir(char *out, size_t outlen) {
    const char *home = getenv("HOME");
    if (!home) return 0;
    // The data folder, as in paths.py: RS_COMPANION_DATA overrides it (tests).
    if (getenv("RS_COMPANION_DATA")) snprintf(out, outlen, "%s", getenv("RS_COMPANION_DATA"));
    else snprintf(out, outlen, "%s/Library/Application Support/rs-mac-companion", home);
    return 1;
}

void log_open(const char *dir, const char *name) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    g_logf = fopen(path, "a");
    if (g_logf) setvbuf(g_logf, NULL, _IONBF, 0);
}

double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

FILE *g_logf;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

// Messages are formatted on the stack and the log is unbuffered, so log text never sits in the
// heap where a banner scan could find it.
void logline(const char *fmt, ...) {
    if (!g_logf) return;
    char msg[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    char hms[16];
    struct tm tm;
    strftime(hms, sizeof hms, "%H:%M:%S", localtime_r(&ts.tv_sec, &tm));  // several threads log
    pthread_mutex_lock(&g_log_lock);
    fprintf(g_logf, "%s.%03ld %s\n", hms, ts.tv_nsec / 1000000, msg);
    pthread_mutex_unlock(&g_log_lock);
}

int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcmp(s + a - b, suffix);
}

// ================================================================ songs (from files)

// Open archives, the 8 most recently used. One thread only (the one that loads songs).
#define CACHE 8
static struct { char *path; rs_psarc *p; unsigned used; } g_cache[CACHE];
static unsigned g_tick;

rs_psarc *archive(const char *path) {
    int oldest = 0;
    for (int i = 0; i < CACHE; i++) {
        if (g_cache[i].path && !strcmp(g_cache[i].path, path)) {
            g_cache[i].used = ++g_tick;
            return g_cache[i].p;
        }
        if (g_cache[i].used < g_cache[oldest].used) oldest = i;
    }
    rs_psarc *p = rs_psarc_open(path);
    if (!p) return NULL;
    free(g_cache[oldest].path);
    rs_psarc_close(g_cache[oldest].p);
    g_cache[oldest].path = strdup(path);
    g_cache[oldest].p = p;
    g_cache[oldest].used = ++g_tick;
    return p;
}

const char *short_path(const char *path) {
    const char *s = strstr(path, "rocksmith2014/");
    if (!s) s = strstr(path, "Rocksmith2014/");
    return s ? s + 14 : path;
}

song *load_song(rs_psarc *p, const char *key) {
    song *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    snprintf(s->key, sizeof s->key, "%s", key);
    char prefix[300];
    snprintf(prefix, sizeof prefix, "songs/bin/macos/%s_", key);
    static const char *slot_keys[5] = {"Tone_Base", "Tone_A", "Tone_B", "Tone_C", "Tone_D"};
    for (uint32_t i = 0; i < p->n && s->narr < MAX_ARRS; i++) {
        const char *path = p->e[i].path;
        if (strncmp(path, prefix, strlen(prefix)) || !ends_with(path, ".sng")) continue;
        arrangement *a = &s->arr[s->narr++];
        const char *base = strrchr(path, '/') + 1;
        snprintf(a->name, sizeof a->name, "%.*s", (int)(strlen(base) - 4), base);
        char suffix[300];
        snprintf(suffix, sizeof suffix, "/%s.json", a->name);
        for (uint32_t j = 0; j < p->n; j++) {
            if (strncmp(p->e[j].path, "manifests/", 10) || !ends_with(p->e[j].path, suffix)) continue;
            char *json = (char *)rs_psarc_read(p, &p->e[j], NULL);
            if (json) {
                rs_json_str(json, "SongName", a->song, sizeof a->song);
                rs_json_str(json, "ArtistName", a->artist, sizeof a->artist);
                rs_json_str(json, "SongKey", a->song_key, sizeof a->song_key);
                rs_json_str(json, "ArrangementName", a->type, sizeof a->type);
                double v;
                a->bonus = rs_json_num(json, "bonusArr", &v) && v > 0;
                a->represent = rs_json_num(json, "represent", &v) ? v > 0 : !a->bonus;
                for (int k = 0; k < 5; k++) rs_json_str(json, slot_keys[k], a->slots[k], sizeof a->slots[k]);
                a->ntones = rs_json_tones(json, a->tones, MAX_TONES);
                free(json);
            }
            break;
        }
        size_t len = 0;
        uint8_t *sng = rs_psarc_read(p, &p->e[i], &len);
        rs_tone_change *ch = NULL;
        int n = sng ? rs_sng_tones(sng, len, &ch) : -1;
        free(sng);
        for (int c = 0; c < n && c < MAX_CHANGES; c++) a->ch[a->nch++] = ch[c];
        free(ch);
    }
    return s;
}

// ================================================================ tones of an arrangement

int slot_at(const arrangement *a, double t) {
    int slot = 0;
    for (int i = 0; i < a->nch; i++) {
        if (a->ch[i].time > t) break;
        if (a->ch[i].id >= 0 && a->ch[i].id < 4) slot = a->ch[i].id + 1;
    }
    return slot;
}

const char *tone_key(const arrangement *a, int slot) { return a->slots[slot][0] ? a->slots[slot] : a->slots[0]; }

const rs_tone_def *tone_def(const arrangement *a, int slot) {
    const char *key = tone_key(a, slot);
    for (int i = 0; i < a->ntones; i++)
        if (!strcasecmp(a->tones[i].key, key)) return &a->tones[i];
    return NULL;
}

// ================================================================ events

// Events go to the companion app as JSON datagrams on a Unix socket the app owns
// (DATA_DIR/events.sock). Sending never blocks: with no app listening, or its queue full, the
// event is dropped. Every event is also logged as an "EVENT {json}" line, except heartbeats.
//
//   song   {"event":"song", song, artist, arrangement, song_key, archive,
//          tones:[{slot, tone, descriptors, amp, gain}],
//          parts:[{arrangement, slots:{Base: key, A: key, ...}}] (every arrangement of the song)}
//   tone   {"event":"tone", song, artist, arrangement, song_key, archive, slot, tone, descriptors, amp, gain,
//          source[, time]}
//          (amp: the tone's amp key, gain: its gain knob 0-100 or null)
//   state  heartbeat every second: {"event":"state", protocol, pid, lead_ms, timer_locked,
//          and with a song: song, artist, arrangement, song_key, archive, tones, parts, slot[, time]}
//   stats  only with overlay_enabled, 4 times a second while a song is played (see the stats
//          section): {"event":"stats", mode: "las" or "sa", hits, misses, streak, best_streak,
//          miss_streak[, time], and in Score Attack: best_miss_streak, perfect_hits,
//          perfect_streak, late_hits, late_streak, phrases:[perfect, good, passed, failed],
//          phrase_streaks:[4], best_phrase_streaks:[4], score, multiplier, best_multiplier};
//          {"event":"stats", "live": false} once when the game frees the objects. Rocksmith only.
//
// game: the app the library runs in, in state events, when set (g_game); none means Rocksmith.
//
// source: "song-start" (arrangement's starting tone), "banner" (the game's on-screen tone text,
// before the song timer is locked; up to ~1 s late), "timer" (song timer + timeline; on time).


static int g_sock = -1;
static struct sockaddr_un g_sock_addr;
int g_last_slot = -1;
char g_last_tone[128];
int g_lead_ms = 100;         // see config_poll()
const char *g_game;

void events_open(const char *data_dir) {
    g_sock_addr.sun_family = AF_UNIX;
    if ((size_t)snprintf(g_sock_addr.sun_path, sizeof g_sock_addr.sun_path, "%s/events.sock", data_dir) >=
        sizeof g_sock_addr.sun_path) {
        logline("warning: socket path too long; events only go to the log");
        return;
    }
    g_sock = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (g_sock < 0) return;
    fcntl(g_sock, F_SETFL, O_NONBLOCK);
    int size = 16384;  // datagrams may exceed the 2 KB default
    setsockopt(g_sock, SOL_SOCKET, SO_SNDBUF, &size, sizeof size);
}

void send_event(const char *json, int log) {
    if (g_sock >= 0)
        sendto(g_sock, json, strlen(json), 0, (const struct sockaddr *)&g_sock_addr, sizeof g_sock_addr);
    if (log) logline("EVENT %s", json);
}

void json_str(char *out, size_t outlen, const char *s) {
    size_t n = strlen(out);
    if (n + 2 >= outlen) return;
    out[n++] = '"';
    for (; *s && n + 8 < outlen; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') out[n++] = '\\', out[n++] = (char)c;
        else if (c < 0x20) n += (size_t)snprintf(out + n, outlen - n, "\\u%04x", c);
        else out[n++] = (char)c;
    }
    out[n++] = '"';
    out[n] = 0;
}

// "song": ..., "artist": ..., "arrangement": ...
static void add_song(char *ev, size_t size, const arrangement *a) {
    strlcat(ev, "\"song\": ", size);
    json_str(ev, size, a->song);
    strlcat(ev, ", \"artist\": ", size);
    json_str(ev, size, a->artist);
    strlcat(ev, ", \"arrangement\": ", size);
    json_str(ev, size, a->name);
    strlcat(ev, ", \"song_key\": ", size);
    json_str(ev, size, a->song_key);
    strlcat(ev, ", \"archive\": ", size);
    json_str(ev, size, a->archive);
}

// "descriptors": [...], "amp": ..., "gain": ... of the tone in a slot (gain: the amp's gain knob,
// 0-100, or null)
static void add_descriptors(char *ev, size_t size, const arrangement *a, int slot) {
    strlcat(ev, "\"descriptors\": [", size);
    const rs_tone_def *d = tone_def(a, slot);
    for (int i = 0; d && i < d->ndesc; i++) {
        if (i) strlcat(ev, ", ", size);
        json_str(ev, size, d->desc[i]);
    }
    strlcat(ev, "], \"amp\": ", size);
    json_str(ev, size, d ? d->amp : "");
    char g[32] = ", \"gain\": null";
    if (d && d->gain >= 0) snprintf(g, sizeof g, ", \"gain\": %.4g", d->gain);
    strlcat(ev, g, size);
}

// "tones": [{"slot": "Base", "tone": ..., "descriptors": [...], "amp": ..., "gain": ...}, ...] for
// the slots in use
static void add_tones(char *ev, size_t size, const arrangement *a) {
    strlcat(ev, "\"tones\": [", size);
    int n = 0;
    for (int slot = 0; slot < 5; slot++) {
        if (!a->slots[slot][0]) continue;
        strlcat(ev, n++ ? ", {\"slot\": " : "{\"slot\": ", size);
        json_str(ev, size, SLOT_NAMES[slot]);
        strlcat(ev, ", \"tone\": ", size);
        json_str(ev, size, a->slots[slot]);
        strlcat(ev, ", ", size);
        add_descriptors(ev, size, a, slot);
        strlcat(ev, "}", size);
    }
    strlcat(ev, "]", size);
}

void emit_tone(const arrangement *a, int slot, const char *source, double time_s) {
    char ev[4096] = "{\"event\": \"tone\", ";
    add_song(ev, sizeof ev, a);
    strlcat(ev, ", \"slot\": ", sizeof ev);
    json_str(ev, sizeof ev, SLOT_NAMES[slot]);
    strlcat(ev, ", \"tone\": ", sizeof ev);
    json_str(ev, sizeof ev, tone_key(a, slot));
    strlcat(ev, ", ", sizeof ev);
    add_descriptors(ev, sizeof ev, a, slot);
    strlcat(ev, ", \"source\": ", sizeof ev);
    json_str(ev, sizeof ev, source);
    if (time_s >= 0) {
        char t[32];
        snprintf(t, sizeof t, ", \"time\": %.2f", time_s);
        strlcat(ev, t, sizeof ev);
    }
    strlcat(ev, "}", sizeof ev);
    send_event(ev, 1);
    g_last_slot = slot;
    snprintf(g_last_tone, sizeof g_last_tone, "%s", tone_key(a, slot));
}

void emit_song(const arrangement *a, const char *parts) {
    char ev[12288] = "{\"event\": \"song\", ";
    add_song(ev, sizeof ev, a);
    strlcat(ev, ", ", sizeof ev);
    add_tones(ev, sizeof ev, a);
    strlcat(ev, ", ", sizeof ev);
    strlcat(ev, parts, sizeof ev);
    strlcat(ev, "}", sizeof ev);
    send_event(ev, 1);
}

// Heartbeat: the whole current state, so an app started mid-song catches up and can tell that
// the game (with this dylib) is running. a is NULL before the first song.
void emit_state(const arrangement *a, const char *parts, int locked, double time_s) {
    char ev[12288];
    snprintf(ev, sizeof ev, "{\"event\": \"state\", \"protocol\": %d, \"pid\": %d, \"lead_ms\": %d, \"timer_locked\": %s",
             PROTOCOL, getpid(), g_lead_ms, locked ? "true" : "false");
    if (g_game) {
        strlcat(ev, ", \"game\": ", sizeof ev);
        json_str(ev, sizeof ev, g_game);
    }
    if (a) {
        strlcat(ev, ", ", sizeof ev);
        add_song(ev, sizeof ev, a);
        strlcat(ev, ", ", sizeof ev);
        add_tones(ev, sizeof ev, a);
        strlcat(ev, ", ", sizeof ev);
        strlcat(ev, parts, sizeof ev);
        if (g_last_slot >= 0) {
            strlcat(ev, ", \"slot\": ", sizeof ev);
            json_str(ev, sizeof ev, SLOT_NAMES[g_last_slot]);
            strlcat(ev, ", \"tone\": ", sizeof ev);
            json_str(ev, sizeof ev, g_last_tone);
        }
        if (time_s >= 0) {
            char t[32];
            snprintf(t, sizeof t, ", \"time\": %.2f", time_s);
            strlcat(ev, t, sizeof ev);
        }
    }
    strlcat(ev, "}", sizeof ev);
    send_event(ev, 0);
}

// "parts": [{"arrangement": ..., "slots": {"Base": key, ...}}] for every arrangement of a song,
// so the app can apply an override to all parts that use a tone.
void build_parts(const song *s, char *out, size_t size) {
    snprintf(out, size, "\"parts\": [");
    for (int i = 0; s && i < s->narr; i++) {
        const arrangement *p = &s->arr[i];
        strlcat(out, i ? ", {\"arrangement\": " : "{\"arrangement\": ", size);
        json_str(out, size, p->name);
        strlcat(out, ", \"slots\": {", size);
        int n = 0;
        for (int slot = 0; slot < 5; slot++) {
            if (!p->slots[slot][0]) continue;
            if (n++) strlcat(out, ", ", size);
            json_str(out, size, SLOT_NAMES[slot]);
            strlcat(out, ": ", size);
            json_str(out, size, p->slots[slot]);
        }
        strlcat(out, "}}", size);
    }
    strlcat(out, "]", size);
}

// Settings from DATA_DIR/rscompanion.json, re-read when the file changes:
//   {"lead_ms": 100}            report tone changes this many ms before the song file's change time
//   {"overlay_enabled": true}   read the note statistics for the app's stream overlays
char g_config_file[1024];
volatile int g_overlay;

void config_poll(void) {
    static struct timespec seen;
    struct stat st;
    if (stat(g_config_file, &st) || (st.st_mtimespec.tv_sec == seen.tv_sec && st.st_mtimespec.tv_nsec == seen.tv_nsec))
        return;
    seen = st.st_mtimespec;
    FILE *f = fopen(g_config_file, "r");
    if (!f) return;
    char text[4096];
    size_t n = fread(text, 1, sizeof text - 1, f);
    fclose(f);
    text[n] = 0;
    const char *p = strstr(text, "\"lead_ms\"");
    if (p && (p = strchr(p + 9, ':'))) {
        long ms = strtol(p + 1, NULL, 10);
        if (ms >= 0 && ms <= 2000 && ms != g_lead_ms) {
            g_lead_ms = (int)ms;
            logline("config: lead_ms = %d", g_lead_ms);
        }
    }
    p = strstr(text, "\"overlay_enabled\"");
    int on = 0;
    if (p && (p = strchr(p + 17, ':'))) {
        while (*++p == ' ' || *p == '\t' || *p == '\n') {}
        on = !strncmp(p, "true", 4);
    }
    if (on != g_overlay) {
        g_overlay = on;
        logline("config: overlay_enabled = %s", on ? "true" : "false");
    }
}