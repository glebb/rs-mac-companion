// Measures Helix Native with no window and no audio device: the Stomp has the same models, and can't be measured without
// a guitar. A job builds a tone's preset as rs-tonehost (rearmed-mods) builds it for Helix's engine, from its profile:
// the profile's empty frame, the amp's block and each block whose switch the job turns on, in the profile's order, with
// the job's values in their places; a parameter with no place in any block is set on the plug-in. The preset goes
// straight to the engine. Then tonehost's reference guitar, a phrase of half a second going round, plays through it,
// and the loudness that comes out (BS.1770's K-weighting, as tonehost measures a tone) is printed:
//   LABEL out_at_-60 out_at_-54 ... out_at_-6
// or with --at DB, at that level alone; "LABEL failed" for a job whose preset can't be made or that the engine refuses.
// --pluck measures the way tonehost did until November 2026 instead: one low plucked string, its plain power.
// The phrase, the meter, the places and the engine are tonehost's own files, in third_party/tonehost. tools/calibrate_stomp.py
// writes the jobs and reads the levels. Run it with the network guard, as tonehost runs Helix; calibrate_stomp.py does.
//   clang -fobjc-arc -I third_party/tonehost tools/measure_helix.m third_party/tonehost/engine.c \
//     -framework Foundation -framework AudioToolbox -o build/measure_helix
//   measure_helix --profile DIR [--paced] [--at DB] [--pluck] < JOBS
// DIR is tonehost's plug-in folder, with profile.json and its presets. A job is a line:
// LABEL<TAB>TEMPLATE<TAB>param=value param=value ..., the template one of the profile's and the parameters numbered as
// tonehost's rules number them.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include "engine.h"
#include "preset_places.h"
#include "tone_level.h"
#define N 256
#define RATE LEVEL_RATE
#define PLUCK 12000
static AudioUnit u;
static double when, peak;
static int pos, paced, pluck, instance = -1;
static float in[N], phrase[LEVEL_LOOP];
static double power, count, weigh[4];
static NSDictionary *profile;
static NSString *dir;

static OSStatus cb(void *r, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t, UInt32 b, UInt32 n, AudioBufferList *io) {
  for (UInt32 c = 0; c < io->mNumberBuffers; c++) memcpy(io->mBuffers[c].mData, in, n * 4);
  return 0;
}

// `seconds` of the guitar through the plug-in; with `listen`, what comes out is added to power and count
static void run(double seconds, int listen) {
  static float L[N], R[N];
  for (int k = 0; k < seconds * RATE / N; k++) {
    for (int i = 0; i < N; i++, pos++) {
      if (pluck) {
        double t = (pos % PLUCK) / RATE, w = 2 * M_PI * 110.0 * t;
        in[i] = (float)(peak * exp(-t * 9.0) * (sin(w) + 0.5 * sin(2 * w) + 0.3 * sin(3 * w) + 0.2 * sin(5 * w)) / 1.6);
      } else
        in[i] = (float)(peak * phrase[pos % LEVEL_LOOP]);
    }
    struct { UInt32 n; AudioBuffer b[2]; } bl = {2, {{1, sizeof L, L}, {1, sizeof R, R}}};
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    ts.mSampleTime = when;
    when += N;
    AudioUnitRenderActionFlags fl = 0;
    AudioUnitRender(u, &fl, &ts, 0, N, (AudioBufferList *)&bl);
    if (listen)
      for (int i = 0; i < N; i++) {
        double v = pluck ? L[i] : level_weigh(weigh, L[i]);
        if (!isfinite(v)) { memset(weigh, 0, sizeof weigh); v = 0; }
        power += v * v;
      }
    if (listen) count += N;
    if (paced) usleep(5333);
  }
}

static double measure(double db) {
  peak = pow(10, db / 20);
  if (pluck) {
    run(0.25, 0);     // the amp's sag finds its level
    pos = 0, power = 0, count = 0;
    run(0.25, 1);     // one pluck
    return 10 * log10(power / count + 1e-12);
  }
  // As tonehost measures a tone: the engine plays under its level for some 60-80 ms after a load, and a knob set on the
  // plug-in ramps for about 0.3 s. Then one round of the phrase after another, until two agree
  run(0.4, 0);
  memset(weigh, 0, sizeof weigh);
  run(0.1, 0);        // the meter's filter settles
  double rounds[6], level = -120, before;
  int i = 0, agreed = 0;
  for (; i < 6 && !agreed; i++) {
    power = 0, count = 0;
    run(LEVEL_LOOP / RATE, 1);
    rounds[i] = power / count;
    before = level;
    level = level_db(rounds[i], 1);
    agreed = i && fabs(level - before) < 0.5;
  }
  if (agreed) return level;
  double sum = 0;   // where no two agreed, what the last four came to
  for (int k = i - 4; k < i; k++) sum += rounds[k];
  return level_db(sum, 4);
}

static int place_of(NSArray *place, double at[3]) {
  if (![place isKindOfClass:NSArray.class] || place.count > 3) return 0;
  for (NSUInteger i = 0; i < place.count; i++) at[i] = [place[i] doubleValue];
  return (int)place.count;
}

static NSData *file(NSString *name) {
  return [NSData dataWithContentsOfFile:[name hasPrefix:@"/"] ? name : [dir stringByAppendingPathComponent:name]];
}

// The tone's preset, as tonehost's composed() makes one for a tone that doesn't say its chain, or nil. Values with no
// place in any block go to `unplaced`.
static NSData *composed(NSDictionary *t, NSDictionary<NSString *, NSNumber *> *values, NSMutableDictionary *unplaced) {
  NSMutableData *preset = [file(profile[@"frame"]) mutableCopy];
  NSArray *spots = profile[@"spots"], *blocks = profile[@"blocks"];
  if (!preset.length || ![spots isKindOfClass:NSArray.class] || ![blocks isKindOfClass:NSArray.class]) return nil;
  NSMutableDictionary<NSString *, NSNumber *> *start = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSArray *> *places = [NSMutableDictionary dictionary];
  NSMutableSet *known = [NSMutableSet set];
  NSUInteger spot = 0;
  for (NSDictionary *b in blocks) {
    BOOL amp = [b[@"amp"] boolValue];
    NSDictionary *own = !amp && [b[@"places"] isKindOfClass:NSDictionary.class] ? b[@"places"] : @{};
    [known addObjectsFromArray:own.allKeys];
    if (!amp && [values[[b[@"on"] description]] floatValue] < 0.5f) continue;
    NSData *block = file(amp ? t[@"block"] : b[@"file"]);
    if (!block.length || spot >= spots.count) return nil;
    NSUInteger at = [spots[spot++] unsignedIntegerValue];
    if (at > preset.length || block.length > preset.length - at) return nil;
    [preset replaceBytesInRange:NSMakeRange(at, block.length) withBytes:block.bytes];
    NSString *name = amp ? @"amp" : [b[@"name"] description];
    if (!start[name]) start[name] = @(at);
    for (NSString *id in own) {
      NSMutableArray *p = [own[id] mutableCopy];
      p[0] = @([p[0] doubleValue] + at);
      places[id] = p;
    }
  }
  NSDictionary *mine = [t[@"places"] isKindOfClass:NSDictionary.class] ? t[@"places"] : @{};
  for (NSString *id in mine) {  // the amp's knobs: in the amp, or in the block it lends one to, if the tone has that
    NSArray *place = mine[id];
    [known addObject:id];
    [places removeObjectForKey:id];
    NSNumber *at = [place isKindOfClass:NSArray.class] && place.count > 1 ? start[[place[0] description]] : nil;
    if (!at) continue;
    NSMutableArray *p = [[place subarrayWithRange:NSMakeRange(1, place.count - 1)] mutableCopy];
    p[0] = @([p[0] doubleValue] + at.doubleValue);
    places[id] = p;
  }
  for (NSString *id in values) {
    if (places[id]) {
      double at[3] = {0};
      if (place_value(preset.mutableBytes, preset.length, at, place_of(places[id], at), values[id].floatValue)) return nil;
    } else if (![known containsObject:id])
      unplaced[id] = values[id];
  }
  return preset;
}

// The plug-in's instance in the engine: the one whose muting silences what this process renders
static int find_instance(NSData *preset) {
  for (int i = 0; i < 8; i++) {
    if (helix_engine_load(i, preset.bytes, preset.length)) continue;
    if (helix_engine_mute(i, 1)) continue;
    double muted = measure(-12);
    helix_engine_mute(i, 0);
    if (muted < -90 && measure(-12) > -90) return i;
  }
  return -1;
}

int main(int argc, char **argv) { @autoreleasepool {
  int at = 0, one = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--paced")) paced = 1;
    else if (!strcmp(argv[i], "--pluck")) pluck = 1;
    else if (!strcmp(argv[i], "--at") && i + 1 < argc) at = atoi(argv[++i]), one = 1;
    else if (!strcmp(argv[i], "--profile") && i + 1 < argc) dir = @(argv[++i]);
  }
  NSData *json = dir ? [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"profile.json"]] : nil;
  profile = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
  if (![profile isKindOfClass:NSDictionary.class] || ![profile[@"engine"] isEqual:@"helix"]) {
    fprintf(stderr, "measure_helix: --profile names no folder with a profile.json of Helix's engine\n");
    return 1;
  }
  level_phrase(phrase);
  AudioComponentDescription d = {'aumf', '6HPA', 'LSIX', 0, 0};
  AudioComponent c = AudioComponentFindNext(NULL, &d);
  if (!c || AudioComponentInstanceNew(c, &u)) return 2;
  AudioStreamBasicDescription f = {RATE, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
  AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
  AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f);
  UInt32 max = N;
  AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max, 4);
  AURenderCallbackStruct r = {cb, NULL};
  AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &r, sizeof r);
  if (AudioUnitInitialize(u)) return 3;
  run(0.5, 0);
  if (!helix_engine_find()) {
    fprintf(stderr, "measure_helix: Helix Native's engine isn't there to take presets\n");
    return 4;
  }
  char line[8192];
  while (fgets(line, sizeof line, stdin)) {
    NSArray *parts = [[[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]
                      componentsSeparatedByString:@"\t"];
    if (parts.count < 2) continue;
    NSString *label = parts[0];
    NSDictionary *t = profile[@"templates"][parts[1]];
    NSMutableDictionary<NSString *, NSNumber *> *values = [NSMutableDictionary dictionary], *unplaced = [NSMutableDictionary dictionary];
    if (parts.count > 2)
      for (NSString *kv in [parts[2] componentsSeparatedByString:@" "]) {
        NSArray *a = [kv componentsSeparatedByString:@"="];
        if (a.count == 2) values[@([a[0] intValue]).stringValue] = @([a[1] floatValue]);
      }
    NSData *preset = [t isKindOfClass:NSDictionary.class] ? composed(t, values, unplaced) : nil;
    if (preset && instance < 0 && (instance = find_instance(preset)) < 0) {
      fprintf(stderr, "measure_helix: no instance of Helix's engine is this plug-in\n");
      return 5;
    }
    if (!preset || helix_engine_load(instance, preset.bytes, preset.length)) {
      printf("%s failed\n", label.UTF8String);
      fflush(stdout);
      continue;
    }
    for (NSString *id in unplaced)
      AudioUnitSetParameter(u, id.intValue, kAudioUnitScope_Global, 0, unplaced[id].floatValue, 0);
    printf("%s", label.UTF8String);
    if (one) printf(" %.2f", measure(at));
    else for (int db = -60; db <= -6; db += 6) printf(" %.2f", measure(db));
    printf("\n");
    fflush(stdout);
  }
  _exit(0);
}}
