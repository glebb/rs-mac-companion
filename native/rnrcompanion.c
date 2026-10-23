// rnrcompanion: library loaded into RockNRoller (a Rocksmith chart player for macOS,
// com.mintricksai.rocknroller) that reports its tone changes to the companion app, as the
// Rocksmith library (rscompanion.c) does for the game: the same events on the same socket, with
// "game": "rocknroller" in heartbeats.
//
// RockNRoller keeps its symbols, so everything comes from names it exports (dlsym), never from
// addresses or memory scans; docs/rocknroller.md lists them and what each holds:
// 1. Song: the archive path at the start of g_chart_session ("…/x_m.psarc", or
//    "…/rs1compatibilitydlc_m.psarc#songkey" for one song of a pack), while play_session_live().
//    Its arrangements and tone timelines are read from the archive itself (rscore.c, rsfile.c).
// 2. Arrangement: the first chart panel showing a part (g_chart_layout), mapped to the song's
//    arrangements the way RockNRoller assigns them (by manifest type, bonus and represent).
// 3. Position: play_audio_time_played(&g_pa), the song position in seconds (it only reads a
//    field, so calling it from our thread is safe).
// 4. Tone: the slot active at position + lead time (scaled by the playback speed), 20 times a
//    second; a heartbeat every second.
//
// Loaded with DYLD_INSERT_LIBRARIES (RockNRoller has no hardened runtime), which it then removes
// from the environment so programs RockNRoller starts don't load it too. In any other program, or
// when a name is missing (a RockNRoller update renamed it), it logs that and stays idle.
//
// Logs to ~/Library/Application Support/rs-mac-companion/rnrcompanion.log.
// Build: see build.sh (arm64 only, like RockNRoller).
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "rscore.h"

// ================================================================ RockNRoller's names

// g_chart_layout: the play screen's chart panels.
typedef struct {
    int template_id;                // layout template (single, split, ...)
    struct { int source, variant; } cell[4];
    int ncells;
} rnr_layout;

// A panel's source: a part, or something else (lyrics, empty).
enum { SRC_LEAD = 1, SRC_RHYTHM = 2, SRC_BASS = 3, SRC_LYRICS = 4, SRC_COMBO = 5,
       SRC_BONUS = 10, SRC_BONUS_END = 22 };   // bonus: 10 + 3 * type (0 lead .. 3 combo) + nth

static struct {
    bool (*session_live)(void);
    float (*time_played)(void *pa);
    void *pa;
    const char *chart_session;      // starts with the archive path
    const rnr_layout *layout;
} R;

static int bind_names(void) {
    void *h = RTLD_MAIN_ONLY;
    R.session_live = (bool (*)(void))dlsym(h, "play_session_live");
    R.time_played = (float (*)(void *))dlsym(h, "play_audio_time_played");
    R.pa = dlsym(h, "g_pa");
    R.chart_session = dlsym(h, "g_chart_session");
    R.layout = dlsym(h, "g_chart_layout");
    const char *missing = !R.session_live ? "play_session_live" : !R.time_played ? "play_audio_time_played"
                        : !R.pa ? "g_pa"
                        : !R.chart_session ? "g_chart_session" : !R.layout ? "g_chart_layout" : NULL;
    if (missing) logline("RockNRoller's %s not found (another version?); not following songs", missing);
    return !missing;
}

// The archive path of the song on the play screen, copied ("" if none). Read twice, so a path
// being replaced as we read is never taken.
static void session_path(char *out, size_t outlen) {
    char again[1024];
    for (int tries = 0; tries < 3; tries++) {
        snprintf(out, outlen, "%.*s", (int)(outlen - 1), R.chart_session);
        snprintf(again, sizeof again, "%.*s", (int)(sizeof again - 1), R.chart_session);
        if (!strcmp(out, again)) return;
    }
    out[0] = 0;
}

// ================================================================ songs and arrangements

// "…/pack_m.psarc#key" -> archive "…/pack_m.psarc", key "key". Without "#", the key is the
// file prefix of the archive's first arrangement (one song per archive).
static song *open_song(const char *path) {
    char file[1024], key[128] = "";
    const char *hash = strrchr(path, '#');
    snprintf(file, sizeof file, "%.*s", hash ? (int)(hash - path) : (int)strlen(path), path);
    if (hash) snprintf(key, sizeof key, "%s", hash + 1);
    rs_psarc *p = archive(file);
    if (!p) return logline("cannot open %s", file), NULL;
    for (uint32_t i = 0; !key[0] && i < p->n; i++) {
        const char *e = p->e[i].path, *us = strrchr(e, '_');
        if (!strncmp(e, "songs/bin/macos/", 16) && ends_with(e, ".sng") && us > e + 16)
            snprintf(key, sizeof key, "%.*s", (int)(us - e - 16), e + 16);
    }
    double t0 = now_s();
    song *s = key[0] ? load_song(p, key) : NULL;
    if (!s || !s->narr) return logline("no arrangements of \"%s\" in %s", key, short_path(file)), free(s), NULL;
    for (int i = 0; i < s->narr; i++) snprintf(s->arr[i].archive, sizeof s->arr[i].archive, "%s", file);
    logline("song %s from %s: %d arrangements read in %.0f ms", key, short_path(file), s->narr, (now_s() - t0) * 1000);
    for (int i = 0; i < s->narr; i++) {
        const arrangement *a = &s->arr[i];
        logline("  %s (%s%s%s): Base=%s A=%s B=%s C=%s D=%s; %d changes", a->name, a->type, a->bonus ? " bonus" : "",
                a->represent ? " represent" : "", a->slots[0], a->slots[1], a->slots[2], a->slots[3], a->slots[4], a->nch);
    }
    return s;
}

// Part kind of an arrangement, as RockNRoller decides it (rnr_arr_kind_from_path,
// rnr_arr_parse_manifest): the manifest's ArrangementName, else the last word of the file name
// without its digits ("x_combo2" -> combo). SRC_LEAD, SRC_RHYTHM, SRC_BASS, SRC_COMBO or 0.
static int kind_of(const arrangement *a) {
    static const struct { const char *word; int kind; } kinds[] = {
        {"lead", SRC_LEAD}, {"rhythm", SRC_RHYTHM}, {"bass", SRC_BASS}, {"combo", SRC_COMBO}};
    char word[32];
    const char *us = strrchr(a->name, '_');
    snprintf(word, sizeof word, "%s", us ? us + 1 : a->name);
    for (size_t n = strlen(word); n && word[n - 1] >= '0' && word[n - 1] <= '9'; n--) word[n - 1] = 0;
    for (int pass = 0; pass < 2; pass++) {
        const char *w = pass ? word : a->type;
        if (!pass && !w[0]) continue;
        for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++)
            if (!strcasecmp(w, kinds[i].word)) return kinds[i].kind;
        if (!pass && !strcasecmp(w, "Vocals")) return 0;
    }
    return 0;
}

// Order of a kind's other arrangements in its bonus slots (rnr_arr_assign): bonus ones first,
// each group by name.
static int bonus_before(const arrangement *x, const arrangement *y) {
    return x->bonus != y->bonus ? x->bonus : strcmp(x->name, y->name) < 0;
}

// The arrangement a panel source shows, as rnr_arr_assign fills them: a part's main arrangement
// (not bonus; represent first, then by name), or for a bonus source (10 + 3 * kind + n) the
// kind's nth other arrangement. -1 if none.
static int arrangement_for(const song *s, int source) {
    int kind = source, nth = -1;
    if (source >= SRC_BONUS && source < SRC_BONUS_END) {
        static const int kinds[4] = {SRC_LEAD, SRC_RHYTHM, SRC_BASS, SRC_COMBO};
        kind = kinds[(source - SRC_BONUS) / 3];
        nth = (source - SRC_BONUS) % 3;
    } else if (source < SRC_LEAD || source > SRC_COMBO || source == SRC_LYRICS) {
        return -1;
    }
    int main = -1;
    for (int i = 0; i < s->narr; i++) {
        const arrangement *a = &s->arr[i];
        if (kind_of(a) != kind || a->bonus) continue;
        if (main < 0 || a->represent > s->arr[main].represent ||
            (a->represent == s->arr[main].represent && strcmp(a->name, s->arr[main].name) < 0))
            main = i;
    }
    if (nth < 0) return main;
    // The nth of the others in bonus order: the one with exactly nth others before it.
    for (int i = 0; i < s->narr; i++) {
        if (i == main || kind_of(&s->arr[i]) != kind) continue;
        int before = 0;
        for (int j = 0; j < s->narr; j++)
            if (j != main && j != i && kind_of(&s->arr[j]) == kind && bonus_before(&s->arr[j], &s->arr[i])) before++;
        if (before == nth) return i;
    }
    return -1;
}

// The arrangement of the first panel that shows a part; else the song's main lead (then rhythm,
// bass), so a lyrics-only screen still follows the song. -1 if the song has no parts.
static int shown_arrangement(const song *s) {
    rnr_layout l = *R.layout;
    for (int c = 0; c < 4 && c < l.ncells; c++) {
        int i = arrangement_for(s, l.cell[c].source);
        if (i >= 0) return i;
    }
    for (int source = SRC_LEAD; source <= SRC_BASS; source++) {
        int i = arrangement_for(s, source);
        if (i >= 0) return i;
    }
    return -1;
}

// ================================================================ tracker

static void *tracker(void *arg) {
    (void)arg;
    static char path[1024], parts[8192];
    song *s = NULL;
    int cur = -1;                   // the followed arrangement of s
    double last_state = 0;
    // Playback speed, measured from the position over each second (RockNRoller plays at 25% to
    // 200% or so); the lead time is real time, so it is scaled by it.
    double rate = 1, rate_t = -1, rate_at = 0;
    for (;;) {
        usleep(50000);
        int live = R.session_live();
        char now_path[1024] = "";
        if (live) session_path(now_path, sizeof now_path);
        if (strcmp(now_path, path)) {
            snprintf(path, sizeof path, "%s", now_path);
            free(s);
            s = path[0] ? open_song(path) : NULL;
            if (s) build_parts(s, parts, sizeof parts);
            cur = -1;
            if (!path[0]) logline("play screen closed");
        }
        double t = live ? R.time_played(R.pa) : -1;
        double n = now_s();
        if (t < 0 || rate_t < 0) {
            rate_t = t, rate_at = n;
        } else if (n - rate_at >= 1) {
            double r = (t - rate_t) / (n - rate_at);
            if (r > 0.1 && r < 4) rate = r;  // not paused, no seek
            rate_t = t, rate_at = n;
        }
        if (s) {
            int i = shown_arrangement(s);
            if (i >= 0 && i != cur) {
                cur = i;
                logline("following %s", s->arr[i].name);
                g_last_slot = -1;
                g_last_tone[0] = 0;
                emit_song(&s->arr[i], parts);
            }
            if (cur >= 0 && t >= 0) {
                const arrangement *a = &s->arr[cur];
                int slot = slot_at(a, t + rate * g_lead_ms / 1000.0);
                // Same tone in another slot: no change.
                if (slot != g_last_slot && strcasecmp(tone_key(a, slot), g_last_tone))
                    emit_tone(a, slot, g_last_slot < 0 && t < 1 ? "song-start" : "timer", t);
                g_last_slot = slot;
            }
        }
        if (n - last_state >= 1) {
            last_state = n;
            config_poll();
            emit_state(s && cur >= 0 ? &s->arr[cur] : NULL, parts, s && cur >= 0, t);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void init(void) {
    // Not for the programs RockNRoller starts (file dialogs and the like).
    unsetenv("DYLD_INSERT_LIBRARIES");
    if (strcmp(getprogname(), "RockNRoller")) return;
    char dir[1024];
    if (!data_dir(dir, sizeof dir)) return;
    log_open(dir, "rnrcompanion.log");
    logline("rnrcompanion loaded (pid %d)", getpid());
    if (!bind_names()) return;
    g_game = "rocknroller";
    snprintf(g_config_file, sizeof g_config_file, "%s/rscompanion.json", dir);
    config_poll();
    logline("lead time %d ms; events to %s/events.sock", g_lead_ms, dir);
    events_open(dir);
    pthread_t th;
    if (pthread_create(&th, NULL, tracker, NULL) == 0) pthread_detach(th);
}
