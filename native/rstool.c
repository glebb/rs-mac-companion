// rstool: command-line front end for rsfile.
//   rstool toc <archive.psarc>...    one line per entry: <start> <end> <length> <path>
//   rstool tones <archive.psarc>...  one JSON line per arrangement in the song index format (song,
//                                     artist, tone slots Base..D, tones, changes [[time, slot id]])
// Build: see build.sh.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rsfile.h"

static void json_string(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

static int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcmp(s + a - b, suffix);
}

static void toc(rs_psarc *p) {
    for (uint32_t i = 0; i < p->n; i++)
        printf("%llu %llu %llu %s\n", (unsigned long long)p->e[i].offset, (unsigned long long)p->e[i].end,
               (unsigned long long)p->e[i].length, p->e[i].path);
}

// One JSON line per arrangement, the song index format (index_songs.py): arrangement, path,
// song, artist, songKey, persistentId, source, tuning (semitones per string, low to high, or
// null), centOffset, tempo (average BPM, or null), slots, tones [{key, name, descriptors,
// separator, amp, gain (amp gain knob 0-100 or null), gear, rig}], changes [[time, slot id]].
static void tones(rs_psarc *p, const char *archive) {
    for (uint32_t i = 0; i < p->n; i++) {
        const char *path = p->e[i].path;
        if (strncmp(path, "manifests/", 10) || !ends_with(path, ".json")) continue;
        const char *base = strrchr(path, '/') + 1;
        char arr[256], sngpath[512];
        snprintf(arr, sizeof arr, "%.*s", (int)(strlen(base) - 5), base);
        size_t jl = 0;
        char *json = (char *)rs_psarc_read(p, &p->e[i], &jl);
        if (!json) {
            fprintf(stderr, "cannot read %s in %s\n", path, archive);
            continue;
        }
        static const char *slot_keys[5] = {"Tone_Base", "Tone_A", "Tone_B", "Tone_C", "Tone_D"};
        char song[512], artist[512], kind[128], song_key[256], pid[128], slots[5][256];
        rs_json_str(json, "SongName", song, sizeof song);
        rs_json_str(json, "ArtistName", artist, sizeof artist);
        rs_json_str(json, "ArrangementName", kind, sizeof kind);
        rs_json_str(json, "SongKey", song_key, sizeof song_key);
        rs_json_str(json, "PersistentID", pid, sizeof pid);
        for (int s = 0; s < 5; s++) rs_json_str(json, slot_keys[s], slots[s], sizeof slots[s]);
        double tuning[6], cents = 0, tempo = -1;
        const char *t = strstr(json, "\"Tuning\"");
        int tuned = t != NULL;
        for (int s = 0; s < 6 && tuned; s++) {
            char key[16];
            snprintf(key, sizeof key, "string%d", s);
            tuned = rs_json_num(t, key, &tuning[s]);
        }
        rs_json_num(json, "CentOffset", &cents);
        rs_json_num(json, "SongAverageTempo", &tempo);
        static rs_tone_def defs[32];
        static char gear[32][512], rig[32][4096];
        int ndefs = rs_json_tones_gear(json, defs, &gear[0][0], sizeof gear[0], &rig[0][0], sizeof rig[0], 32);
        free(json);

        rs_tone_change *ch = NULL;
        int n = 0;
        snprintf(sngpath, sizeof sngpath, "songs/bin/macos/%s.sng", arr);
        const rs_entry *se = rs_psarc_find(p, sngpath);
        if (se) {
            size_t sl = 0;
            uint8_t *sng = rs_psarc_read(p, se, &sl);
            n = sng ? rs_sng_tones(sng, sl, &ch) : -1;
            free(sng);
            if (n < 0) {
                fprintf(stderr, "cannot read %s in %s\n", sngpath, archive);
                n = 0;
            }
        }
        printf("{\"arrangement\": ");
        json_string(arr);
        printf(", \"path\": ");
        json_string(kind);
        printf(", \"song\": ");
        json_string(song);
        printf(", \"artist\": ");
        json_string(artist);
        printf(", \"songKey\": ");
        json_string(song_key);
        printf(", \"persistentId\": ");
        json_string(pid);
        printf(", \"source\": ");
        json_string(archive);
        printf(", \"tuning\": ");
        if (tuned) printf("[%g, %g, %g, %g, %g, %g]", tuning[0], tuning[1], tuning[2], tuning[3], tuning[4], tuning[5]);
        else printf("null");
        printf(", \"centOffset\": %g, \"tempo\": ", cents);
        if (tempo > 0) printf("%g", tempo);
        else printf("null");
        printf(", \"slots\": [");
        for (int s = 0; s < 5; s++) {
            if (s) printf(", ");
            json_string(slots[s]);
        }
        printf("], \"tones\": [");
        for (int d = 0; d < ndefs; d++) {
            printf("%s{\"key\": ", d ? ", " : "");
            json_string(defs[d].key);
            printf(", \"name\": ");
            json_string(defs[d].name);
            printf(", \"descriptors\": [");
            for (int k = 0; k < defs[d].ndesc; k++) {
                if (k) printf(", ");
                json_string(defs[d].desc[k]);
            }
            printf("], \"separator\": ");
            json_string(defs[d].separator);
            printf(", \"amp\": ");
            json_string(defs[d].amp);
            if (defs[d].gain >= 0) printf(", \"gain\": %.4g", defs[d].gain);
            else printf(", \"gain\": null");
            printf(", \"gear\": [");
            int first = 1;
            for (char *g = gear[d], *end; *g; g = *end ? end + 1 : end) {
                end = strchr(g, ';');
                if (!end) end = g + strlen(g);
                char item[256];
                snprintf(item, sizeof item, "%.*s", (int)(end - g), g);
                printf("%s", first ? "" : ", ");
                json_string(item);
                first = 0;
            }
            printf("], \"rig\": %s}", rig[d]);
        }
        printf("], \"changes\": [");
        for (int c = 0; c < n; c++) printf("%s[%.9g, %d]", c ? ", " : "", ch[c].time, ch[c].id);
        printf("]}\n");
        free(ch);
    }
}

int main(int argc, char **argv) {
    if (argc < 3 || (strcmp(argv[1], "toc") && strcmp(argv[1], "tones"))) {
        fprintf(stderr, "usage: rstool toc|tones <archive.psarc>...\n");
        return 2;
    }
    int failures = 0;
    for (int a = 2; a < argc; a++) {
        rs_psarc *p = rs_psarc_open(argv[a]);
        if (!p) {
            fprintf(stderr, "FAILED %s\n", argv[a]);
            failures++;
            continue;
        }
        if (!strcmp(argv[1], "toc")) toc(p);
        else tones(p, argv[a]);
        rs_psarc_close(p);
    }
    return failures ? 1 : 0;
}
