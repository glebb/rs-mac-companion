// Measures Helix Native's amps with no window and no audio device: the Stomp has the same models, and can't be
// measured without a guitar. For each template in rs-tonehost's config, for each amp Drive from 0 to 1, a low plucked
// string goes through at several levels (tonehost's own probe), and the level it comes out at is printed:
//   amp drive out_at_-60 out_at_-48 ... out_at_-6
// An amp follows the input while it's clean, and stops following as it saturates: calibrate_stomp.py reads how far
// below a guitar's level that starts.
// Run it with the network guard, as tonehost/helix/setup.sh runs Helix; tools/calibrate_stomp.py does.
//   clang -fobjc-arc tools/measure_helix.m -framework Foundation -framework AudioToolbox -o build/measure_helix
//   measure_helix CONFIG [--paced] [AMP ...]
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#define N 256
#define RATE 48000.0
#define PLUCK 12000
static AudioUnit u;
static double when, peak;
static int pos, paced;
static float in[N];
static double power, count;

static OSStatus cb(void *r, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t, UInt32 b, UInt32 n, AudioBufferList *io) {
  for (UInt32 c = 0; c < io->mNumberBuffers; c++) memcpy(io->mBuffers[c].mData, in, n * 4);
  return 0;
}

static void run(double seconds, int listen) {
  static float L[N], R[N];
  for (int k = 0; k < seconds * RATE / N; k++) {
    for (int i = 0; i < N; i++) {
      double t = (pos++ % PLUCK) / RATE, w = 2 * M_PI * 110.0 * t;
      in[i] = (float)(peak * exp(-t * 9.0) * (sin(w) + 0.5 * sin(2 * w) + 0.3 * sin(3 * w) + 0.2 * sin(5 * w)) / 1.6);
    }
    struct { UInt32 n; AudioBuffer b[2]; } bl = {2, {{1, sizeof L, L}, {1, sizeof R, R}}};
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    ts.mSampleTime = when;
    when += N;
    AudioUnitRenderActionFlags fl = 0;
    AudioUnitRender(u, &fl, &ts, 0, N, (AudioBufferList *)&bl);
    if (listen) { for (int i = 0; i < N; i++) power += (double)L[i] * L[i]; count += N; }
    if (paced) usleep(5333);
  }
}

static double measure(double db) {
  peak = pow(10, db / 20);
  run(0.25, 0);     // parameters settle, and the amp's sag finds its level
  pos = 0, power = 0, count = 0;
  run(0.25, 1);     // one pluck
  return 10 * log10(power / count + 1e-12);
}

int main(int argc, char **argv) { @autoreleasepool {
  if (argc < 2) return 1;
  NSString *config = [NSString stringWithUTF8String:argv[1]];
  NSDictionary *templates = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:config] options:0 error:NULL][@"templates"];
  NSMutableArray *only = [NSMutableArray array];
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--paced")) paced = 1; else [only addObject:[NSString stringWithUTF8String:argv[i]]];
  }
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
  NSString *dir = config.stringByDeletingLastPathComponent;
  for (NSString *amp in [templates.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (only.count && ![only containsObject:amp]) continue;
    NSDictionary *t = templates[amp];
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:t[@"state"]]];
    CFPropertyListRef p = (__bridge_retained CFPropertyListRef)[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    if (!p || AudioUnitSetProperty(u, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &p, sizeof p)) { printf("%s failed\n", amp.UTF8String); continue; }
    peak = 0;
    run(0.3, 0);
    AudioUnitSetParameter(u, 32, kAudioUnitScope_Global, 0, 0.f, 0);   // Master Input and Output at 0 dB
    AudioUnitSetParameter(u, 33, kAudioUnitScope_Global, 0, 0.f, 0);
    for (int k = 1; k <= 4; k++) {     // the amp's tone knobs at Line 6's defaults
      NSNumber *v = t[@"params"][[NSString stringWithFormat:@"%d", k]];
      if (v) AudioUnitSetParameter(u, k, kAudioUnitScope_Global, 0, v.floatValue, 0);
    }
    static const float drives[] = {0, .025, .05, .075, .1, .15, .2, .25, .3, .4, .5, .6, .7, .8, .9, 1};
    for (int s = 0; s < sizeof drives / sizeof *drives; s++) {
      AudioUnitSetParameter(u, 0, kAudioUnitScope_Global, 0, drives[s], 0);
      printf("%s %.3f", amp.UTF8String, drives[s]);
      for (int db = -60; db <= -6; db += 6) printf(" %.2f", measure(db));
      printf("\n");
      fflush(stdout);
    }
  }
  _exit(0);
}}
