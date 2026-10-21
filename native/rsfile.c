// rsfile: see rsfile.h.
//
// .psarc: big-endian 32-byte header ("PSAR", version, "zlib", toc length, toc entry size,
// entry count, block size, flags). Flag 4 = the table of contents after the header is
// AES-256-CFB encrypted with a fixed key. Entries are 30 bytes: MD5 of the path (16),
// block index (u32), uncompressed length (u40), offset (u40). A uint16 block-size table
// follows. Entry data is stored in blocks, each zlib-compressed unless its size is 0 (stored).
// Entry 0 is the newline-separated path list of the other entries.
//
// .sng (Mac): u32 0x4A, u32 flags, 16-byte IV, then AES-256-CTR (fixed Mac key) over
// u32 plain length + zlib data. The plain SNG is a sequence of length-prefixed arrays
// (little-endian); the tone changes come after 12 arrays of fixed-size records (except one).
#include "rsfile.h"

#include <CommonCrypto/CommonCryptor.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static const uint8_t TOC_KEY[32] = {
    0xC5, 0x3D, 0xB2, 0x38, 0x70, 0xA1, 0xA2, 0xF7, 0x1C, 0xAE, 0x64, 0x06, 0x1F, 0xDD, 0x0E, 0x11,
    0x57, 0x30, 0x9D, 0xC8, 0x52, 0x04, 0xD4, 0xC5, 0xBF, 0xDF, 0x25, 0x09, 0x0D, 0xF2, 0x57, 0x2C};
static const uint8_t TOC_IV[16] = {
    0xE9, 0x15, 0xAA, 0x01, 0x8F, 0xEF, 0x71, 0xFC, 0x50, 0x81, 0x32, 0xE4, 0xBB, 0x4C, 0xEB, 0x42};
static const uint8_t SNG_KEY_MAC[32] = {
    0x98, 0x21, 0x33, 0x0E, 0x34, 0xB9, 0x1F, 0x70, 0xD0, 0xA4, 0x8C, 0xBD, 0x62, 0x59, 0x93, 0x12,
    0x69, 0x70, 0xCE, 0xA0, 0x91, 0x92, 0xC0, 0xE6, 0xCD, 0xA6, 0x76, 0xCC, 0x98, 0x38, 0x28, 0x9D};

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint64_t be40(const uint8_t *p) { return (uint64_t)p[0] << 32 | be32(p + 1); }
static int32_t le32(const uint8_t *p) { return (int32_t)((uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24); }

// Sizes come from the files themselves; corrupt custom songs must not make us allocate gigabytes.
// The largest entries we read are manifests and .sng files (well under 10 MB unpacked).
#define MAX_ENTRY (64u << 20)
#define MAX_SNG_PLAIN (64u << 20)

// Decompress entry data starting at e->offset into a buffer of e->length (+1) bytes.
static uint8_t *extract(rs_psarc *p, uint64_t offset, uint64_t length, uint32_t zindex) {
    if (length > MAX_ENTRY) return NULL;
    // Compressed block sizes are uint16, so 64 KiB holds any of them, whatever block size the
    // archive declares.
    uint8_t *out = malloc(length + 1), *z = malloc(65536);
    if (!out || !z || fseeko(p->f, (off_t)offset, SEEK_SET)) goto fail;
    uint64_t done = 0;
    for (uint32_t i = zindex; done < length; i++) {
        uint32_t zs = i < p->nbs ? p->bs[i] : 0;
        uint64_t want = length - done < p->block ? length - done : p->block;
        if (zs == 0) {
            if (fread(out + done, 1, want, p->f) != want) goto fail;
            done += want;
            continue;
        }
        if (fread(z, 1, zs, p->f) != zs) goto fail;
        uLongf n = (uLongf)want;
        if (uncompress(out + done, &n, z, zs) != Z_OK) {
            // Not zlib after all: the block is stored as is.
            n = zs < want ? zs : want;
            memcpy(out + done, z, n);
        }
        if (n == 0) goto fail;  // a block that inflates to nothing: corrupt
        done += n;
    }
    out[length] = 0;
    free(z);
    return out;
fail:
    free(out);
    free(z);
    return NULL;
}

rs_psarc *rs_psarc_open(const char *path) {
    rs_psarc *p = calloc(1, sizeof *p);
    uint8_t h[32], *toc = NULL, *plain = NULL;
    char *names = NULL;
    if (!p || !(p->f = fopen(path, "rb"))) goto fail;
    if (fread(h, 1, 32, p->f) != 32 || memcmp(h, "PSAR", 4)) goto fail;
    uint32_t toc_len = be32(h + 12), esize = be32(h + 16), count = be32(h + 20), flags = be32(h + 28);
    p->block = be32(h + 24);
    p->toc_end = toc_len;
    // Real archives use 64 KiB blocks; a tiny block size would only make work for us.
    if (toc_len < 32 || toc_len > MAX_ENTRY || esize < 30 || count == 0 || p->block < 4096 ||
        p->block > (1u << 24) || (uint64_t)count * esize > toc_len - 32)
        goto fail;
    uint32_t region = toc_len - 32;
    toc = malloc(region);
    plain = malloc(region + 16);
    if (!toc || !plain || fread(toc, 1, region, p->f) != region) goto fail;
    if (flags == 4) {
        CCCryptorRef c;
        size_t moved = 0;
        if (CCCryptorCreateWithMode(kCCDecrypt, kCCModeCFB, kCCAlgorithmAES, ccNoPadding, TOC_IV, TOC_KEY,
                                    sizeof TOC_KEY, NULL, 0, 0, 0, &c) != kCCSuccess)
            goto fail;
        CCCryptorStatus st = CCCryptorUpdate(c, toc, region, plain, region + 16, &moved);
        CCCryptorRelease(c);
        if (st != kCCSuccess) goto fail;
    } else {
        memcpy(plain, toc, region);
    }

    p->nbs = (region - count * esize) / 2;
    p->bs = malloc(p->nbs * sizeof *p->bs + 1);
    if (!p->bs) goto fail;
    for (uint32_t i = 0; i < p->nbs; i++) {
        const uint8_t *b = plain + (size_t)count * esize + i * 2;
        p->bs[i] = (uint16_t)(b[0] << 8 | b[1]);
    }

    // Entry 0 is the path list; entries 1.. are the files in that order.
    const uint8_t *e0 = plain;
    names = (char *)extract(p, be40(e0 + 25), be40(e0 + 20), be32(e0 + 16));
    if (!names) goto fail;
    p->e = calloc(count, sizeof *p->e);
    if (!p->e) goto fail;
    // Each entry's blocks are in the block-size table; in a valid archive the entries' blocks add
    // up to about the table's size. More work than that means a corrupt (or crafted) archive.
    uint64_t budget = (uint64_t)p->nbs + 2ULL * count + 1024;
    char *save = NULL, *line = strtok_r(names, "\r\n", &save);
    for (uint32_t i = 1; i < count && line; i++, line = strtok_r(NULL, "\r\n", &save)) {
        const uint8_t *r = plain + (size_t)i * esize;
        rs_entry *e = &p->e[p->n++];
        e->path = strdup(line);
        e->zindex = be32(r + 16);
        e->length = be40(r + 20);
        e->offset = be40(r + 25);
        uint64_t span = 0, left = e->length;
        for (uint32_t b = e->zindex; left > 0; b++) {
            if (budget-- == 0) goto fail;
            uint64_t raw = left < p->block ? left : p->block;
            span += (b < p->nbs && p->bs[b]) ? p->bs[b] : raw;
            left -= raw;
        }
        e->end = e->offset + span;
    }
    free(names);
    free(toc);
    free(plain);
    return p;
fail:
    free(names);
    free(toc);
    free(plain);
    rs_psarc_close(p);
    return NULL;
}

void rs_psarc_close(rs_psarc *p) {
    if (!p) return;
    if (p->f) fclose(p->f);
    for (uint32_t i = 0; i < p->n; i++) free(p->e[i].path);
    free(p->e);
    free(p->bs);
    free(p);
}

const rs_entry *rs_psarc_entry_at(const rs_psarc *p, uint64_t offset) {
    for (uint32_t i = 0; i < p->n; i++)
        if (offset >= p->e[i].offset && offset < p->e[i].end) return &p->e[i];
    return NULL;
}

const rs_entry *rs_psarc_find(const rs_psarc *p, const char *path) {
    for (uint32_t i = 0; i < p->n; i++)
        if (!strcmp(p->e[i].path, path)) return &p->e[i];
    return NULL;
}

uint8_t *rs_psarc_read(rs_psarc *p, const rs_entry *e, size_t *len) {
    uint8_t *b = extract(p, e->offset, e->length, e->zindex);
    if (b && len) *len = (size_t)e->length;
    return b;
}

// Skip a length-prefixed array of fixed-size records. Returns 0 if it runs past the end.
static int skip_array(const uint8_t *d, size_t len, size_t *at, size_t rec, int32_t *count) {
    if (*at + 4 > len) return 0;
    int32_t n = le32(d + *at);
    *at += 4;
    if (n < 0 || (uint64_t)n * rec > len - *at) return 0;
    *at += (size_t)n * rec;
    if (count) *count = n;
    return 1;
}

int rs_sng_tones(const uint8_t *sng, size_t len, rs_tone_change **out) {
    *out = NULL;
    if (len < 24 || le32(sng) != 0x4A) return -1;
    const uint8_t *iv = sng + 8;
    size_t clen = len - 24;
    uint8_t *dec = malloc(clen ? clen : 1);
    if (!dec) return -1;
    CCCryptorRef c;
    size_t moved = 0;
    if (CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, SNG_KEY_MAC,
                                sizeof SNG_KEY_MAC, NULL, 0, 0, kCCModeOptionCTR_BE, &c) != kCCSuccess) {
        free(dec);
        return -1;
    }
    CCCryptorStatus st = CCCryptorUpdate(c, sng + 24, clen, dec, clen, &moved);
    CCCryptorRelease(c);
    if (st != kCCSuccess || clen < 4) {
        free(dec);
        return -1;
    }

    // Decrypted: u32 plain length + zlib stream (followed by unused bytes).
    uLongf plen = (uint32_t)le32(dec);
    if (plen > MAX_SNG_PLAIN) {
        free(dec);
        return -1;
    }
    uint8_t *d = malloc(plen ? plen : 1);
    z_stream zs = {0};
    int ok = d && inflateInit(&zs) == Z_OK;
    if (ok) {
        zs.next_in = dec + 4;
        zs.avail_in = (uInt)(clen - 4);
        zs.next_out = d;
        zs.avail_out = (uInt)plen;
        ok = inflate(&zs, Z_FINISH) == Z_STREAM_END && zs.total_out == plen;
        inflateEnd(&zs);
    }
    free(dec);
    if (!ok) {
        free(d);
        return -1;
    }

    // Arrays before the tones (record sizes as in Rocksmith2014.NET's Types/*.fs, MIT).
    size_t at = 0;
    int32_t vocals = 0, nld = 0;
    ok = skip_array(d, plen, &at, 16, NULL)          // beats
         && skip_array(d, plen, &at, 44, NULL)       // phrases
         && skip_array(d, plen, &at, 72, NULL)       // chords
         && skip_array(d, plen, &at, 2376, NULL)     // chord notes
         && skip_array(d, plen, &at, 60, &vocals);   // vocals
    if (ok && vocals > 0)
        ok = skip_array(d, plen, &at, 32, NULL)      // symbol headers
             && skip_array(d, plen, &at, 144, NULL)  // symbol textures
             && skip_array(d, plen, &at, 44, NULL);  // symbol definitions
    ok = ok && skip_array(d, plen, &at, 24, NULL)    // phrase iterations
         && skip_array(d, plen, &at, 16, NULL)       // phrase extra info
         && skip_array(d, plen, &at, 0, &nld);       // new linked difficulties: count only
    for (int32_t i = 0; ok && i < nld; i++) {        // each: level break, int array
        at += 4;
        ok = at <= plen && skip_array(d, plen, &at, 4, NULL);
    }
    int32_t ntones = 0;
    ok = ok && skip_array(d, plen, &at, 260, NULL)   // actions
         && skip_array(d, plen, &at, 260, NULL);     // events
    size_t tones_at = at + 4;
    ok = ok && skip_array(d, plen, &at, 8, &ntones); // tones: float time, int32 id
    if (!ok) {
        free(d);
        return -1;
    }
    rs_tone_change *t = malloc((ntones ? ntones : 1) * sizeof *t);
    if (!t) {
        free(d);
        return -1;
    }
    for (int32_t i = 0; i < ntones; i++) {
        const uint8_t *r = d + tones_at + (size_t)i * 8;
        uint32_t bits = (uint32_t)le32(r);
        memcpy(&t[i].time, &bits, 4);
        t[i].id = le32(r + 4);
    }
    free(d);
    *out = t;
    return ntones;
}

static void put_utf8(char **o, char *end, unsigned cp) {
    char b[4];
    int n;
    if (cp < 0x80) b[0] = (char)cp, n = 1;
    else if (cp < 0x800) b[0] = (char)(0xC0 | cp >> 6), b[1] = (char)(0x80 | (cp & 0x3F)), n = 2;
    else b[0] = (char)(0xE0 | cp >> 12), b[1] = (char)(0x80 | (cp >> 6 & 0x3F)), b[2] = (char)(0x80 | (cp & 0x3F)), n = 3;
    for (int i = 0; i < n && *o < end; i++) *(*o)++ = b[i];
}

int rs_json_str(const char *json, const char *key, char *out, size_t outlen) {
    size_t kl = strlen(key);
    out[0] = 0;
    for (const char *s = json; (s = strchr(s, '"')); s++) {
        if (strncmp(s + 1, key, kl) || s[1 + kl] != '"') continue;
        const char *v = s + 2 + kl;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v++ != ':') continue;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v++ != '"') return 0;  // not a string value
        char *o = out, *end = out + outlen - 1;
        for (; *v && *v != '"'; v++) {
            if (*v != '\\') {
                if (o < end) *o++ = *v;
                continue;
            }
            v++;
            switch (*v) {
            case 'n': put_utf8(&o, end, '\n'); break;
            case 't': put_utf8(&o, end, '\t'); break;
            case 'r': put_utf8(&o, end, '\r'); break;
            case 'b': put_utf8(&o, end, '\b'); break;
            case 'f': put_utf8(&o, end, '\f'); break;
            case 'u': {
                unsigned cp = 0;
                int i = 1;
                for (; i <= 4 && v[i]; i++)
                    cp = cp * 16 + (unsigned)(v[i] <= '9' ? v[i] - '0' : (v[i] | 0x20) - 'a' + 10);
                v += i - 1;  // past the digits there were (fewer at the end of the text)
                put_utf8(&o, end, cp);
                break;
            }
            case 0: v--; break;
            default: put_utf8(&o, end, (unsigned char)*v); break;
            }
        }
        *o = 0;
        return 1;
    }
    return 0;
}

// --- Minimal JSON walking for the "Tones" array ---

static const char *ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

// Parse a string at p (which points at its opening quote) into out; returns the position after
// the closing quote, or NULL. Escapes other than \" and \\ are copied loosely (tags and keys
// are plain ASCII).
static const char *jstr(const char *p, char *out, size_t outlen) {
    if (*p != '"') return NULL;
    size_t n = 0;
    for (p++; *p && *p != '"'; p++) {
        if (*p == '\\' && p[1]) p++;
        if (out && n + 1 < outlen) out[n++] = *p;
    }
    if (out && outlen) out[n] = 0;
    return *p == '"' ? p + 1 : NULL;
}

// Skip any JSON value at p; returns the position after it, or NULL.
static const char *jskip(const char *p) {
    p = ws(p);
    if (*p == '"') return jstr(p, NULL, 0);
    if (*p == '{' || *p == '[') {
        int depth = 0;
        for (; *p; p++) {
            if (*p == '"') {
                p = jstr(p, NULL, 0);
                if (!p) return NULL;
                p--;
            } else if (*p == '{' || *p == '[') {
                depth++;
            } else if (*p == '}' || *p == ']') {
                if (--depth == 0) return p + 1;
            }
        }
        return NULL;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']') p++;  // number, true, false, null
    return p;
}

static int ends_with_str(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcmp(s + a - b, suffix);
}

// "KnobValues": {"Amp_HG500_Gain": 88.0, ...} -> the gain knob (or the higher Loudness knob,
// which the Plexi has instead), or -1.
static const char *jgain(const char *p, float *gain) {
    *gain = -1;
    if (*p != '{') return jskip(p);
    for (p = ws(p + 1); p && *p == '"';) {
        char name[128];
        p = jstr(p, name, sizeof name);
        if (!p) return NULL;
        p = ws(p);
        if (*p++ != ':') return NULL;
        p = ws(p);
        if (ends_with_str(name, "_Gain") || ends_with_str(name, "_Loudness1") || ends_with_str(name, "_Loudness2")) {
            char *end;
            double v = strtod(p, &end);
            if (end != p && v > *gain) *gain = (float)v;
        }
        p = jskip(p);
        if (!p) return NULL;
        p = ws(p);
        if (*p == ',') p = ws(p + 1);
    }
    return p && *p == '}' ? p + 1 : NULL;
}

// "GearList": {"Amp": {"Key": "Amp_AT20", ...}, "Cabinet": {...}, ...} -> "Amp=Amp_AT20;Cabinet=..."
// into out (if not NULL), and the amp's key and gain into t.
static const char *jgear(const char *p, char *out, size_t outlen, rs_tone_def *t) {
    if (*p != '{') return jskip(p);
    for (p = ws(p + 1); p && *p == '"';) {
        char slot[64], key[128] = "";
        int has_key = 0;
        float gain = -1;
        p = jstr(p, slot, sizeof slot);
        if (!p) return NULL;
        p = ws(p);
        if (*p++ != ':') return NULL;
        p = ws(p);
        if (*p == '{') {  // a gear item: find its "Key" (and an amp's gain)
            for (p = ws(p + 1); p && *p == '"';) {
                char name[64];
                p = jstr(p, name, sizeof name);
                if (!p) return NULL;
                p = ws(p);
                if (*p++ != ':') return NULL;
                p = ws(p);
                if (!strcmp(name, "Key") && *p == '"') p = jstr(p, key, sizeof key), has_key = 1;
                else if (!strcmp(name, "KnobValues") && !strcmp(slot, "Amp")) p = jgain(p, &gain);
                else p = jskip(p);
                if (!p) return NULL;
                p = ws(p);
                if (*p == ',') p = ws(p + 1);
            }
            if (!p || *p != '}') return NULL;
            p++;
            if (!strcmp(slot, "Amp") && has_key) {
                snprintf(t->amp, sizeof t->amp, "%s", key);
                t->gain = gain;
            }
            if (out && outlen && has_key) {  // items without a key (e.g. no cabinet) are left out
                if (out[0]) strlcat(out, ";", outlen);
                strlcat(out, slot, outlen);
                strlcat(out, "=", outlen);
                strlcat(out, key, outlen);
            }
        } else {
            p = jskip(p);
        }
        if (!p) return NULL;
        p = ws(p);
        if (*p == ',') p = ws(p + 1);
    }
    return p && *p == '}' ? p + 1 : NULL;
}

static int parse_tones(const char *json, rs_tone_def *out, char *gear, size_t gear_size, int max) {
    const char *p = strstr(json, "\"Tones\"");
    if (!p) return 0;
    p = ws(p + 7);
    if (*p++ != ':') return 0;
    p = ws(p);
    if (*p != '[') return 0;  // e.g. null for vocals
    int n = 0;
    for (p = ws(p + 1); p && *p == '{' && n < max; p = ws(p)) {
        rs_tone_def *t = &out[n];
        char *g = gear ? gear + (size_t)n * gear_size : NULL;
        memset(t, 0, sizeof *t);
        t->gain = -1;
        if (g) g[0] = 0;
        for (p = ws(p + 1); p && *p == '"';) {
            char name[64];
            p = jstr(p, name, sizeof name);
            if (!p) return n;
            p = ws(p);
            if (*p++ != ':') return n;
            p = ws(p);
            if (!strcmp(name, "Key") && *p == '"') {
                p = jstr(p, t->key, sizeof t->key);
            } else if (!strcmp(name, "Name") && *p == '"') {
                p = jstr(p, t->name, sizeof t->name);
            } else if (!strcmp(name, "NameSeparator") && *p == '"') {
                p = jstr(p, t->separator, sizeof t->separator);
            } else if (!strcmp(name, "GearList")) {
                p = jgear(p, g, gear_size, t);
            } else if (!strcmp(name, "ToneDescriptors") && *p == '[') {
                for (p = ws(p + 1); p && *p == '"'; p = ws(p)) {
                    char d[64];
                    p = jstr(p, d, sizeof d);
                    if (!p) return n;
                    const char *s = d;
                    if (s[0] == '$' && s[1] == '[' && strchr(s, ']')) s = strchr(s, ']') + 1;
                    if (t->ndesc < RS_MAX_DESC) snprintf(t->desc[t->ndesc++], sizeof t->desc[0], "%s", s);
                    p = ws(p);
                    if (*p == ',') p++;
                }
                if (p && *p == ']') p++;
            } else {
                p = jskip(p);
            }
            if (!p) return n;
            p = ws(p);
            if (*p == ',') p = ws(p + 1);
        }
        if (!p || *p != '}') return n;
        n++;
        p = ws(p + 1);
        if (*p == ',') p++;
    }
    return n;
}

int rs_json_tones(const char *json, rs_tone_def *out, int max) { return parse_tones(json, out, NULL, 0, max); }

int rs_json_tones_gear(const char *json, rs_tone_def *out, char *gear, size_t gear_size, int max) {
    return parse_tones(json, out, gear, gear_size, max);
}
