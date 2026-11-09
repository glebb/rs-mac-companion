// Measures Helix Native with no window and no audio device: the Stomp has the same models, and can't be measured without
// a guitar. Each job loads a saved state of rs-tonehost (a preset with an amp, its cab and the pedals), sets parameters,
// and plays a low plucked string through it, tonehost's own probe: one pluck after the chain settles. It prints the level
// that comes out, at each input level, or at one with --at:
//   LABEL out_at_-60 out_at_-54 ... out_at_-6
// or "LABEL failed" for a job whose state Native can't load.
// An amp follows the input while it's clean, and stops following as it saturates. tools/calibrate_stomp.py writes the
// jobs and reads the levels.
// Run it with the network guard, as tonehost/helix/setup.sh runs Helix; tools/calibrate_stomp.py does.
//   clang -fobjc-arc tools/measure_helix.m -framework Foundation -framework AudioToolbox -o build/measure_helix
//   measure_helix [--paced] [--at DB] < JOBS
// A job is a line: LABEL<TAB>STATE<TAB>param=value param=value ...; Audio Unit parameters, as tonehost's config numbers
// them. Jobs on the same state in a row load it once.
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
  int at = 0, one = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--paced")) paced = 1;
    else if (!strcmp(argv[i], "--at") && i + 1 < argc) at = atoi(argv[++i]), one = 1;
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
  char line[8192];
  NSString *loaded = nil;
  while (fgets(line, sizeof line, stdin)) {
    NSArray *parts = [[[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]
                      componentsSeparatedByString:@"\t"];
    if (parts.count < 2) continue;
    NSString *label = parts[0], *state = parts[1];
    if (![state isEqual:loaded]) {
      NSData *data = [NSData dataWithContentsOfFile:state];
      CFPropertyListRef p = data ? (__bridge_retained CFPropertyListRef)[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : NULL;
      OSStatus set = p ? AudioUnitSetProperty(u, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &p, sizeof p) : -1;
      if (p) CFRelease(p);   // the unit has taken what it needs: one state per amp would leak otherwise
      if (set) {
        printf("%s failed\n", label.UTF8String);
        fflush(stdout);
        loaded = nil;
        continue;
      }
      loaded = state;
      peak = 0;
      run(1.5, 0);    // a state takes a while to load: measured sooner, the first job hears the state's own settings
    }
    if (parts.count > 2)  // a knob's value from a state isn't reported: a job sets every one it relies on
      for (NSString *kv in [parts[2] componentsSeparatedByString:@" "]) {
        NSArray *a = [kv componentsSeparatedByString:@"="];
        if (a.count == 2) AudioUnitSetParameter(u, [a[0] intValue], kAudioUnitScope_Global, 0, [a[1] floatValue], 0);
      }
    printf("%s", label.UTF8String);
    if (one) printf(" %.2f", measure(at));
    else for (int db = -60; db <= -6; db += 6) printf(" %.2f", measure(db));
    printf("\n");
    fflush(stdout);
  }
  _exit(0);
}}
