// How loud a tone is: the guitar it is measured with and the meter, on their own so that the tests can reach them.
#ifndef TONE_LEVEL_H
#define TONE_LEVEL_H

#include <math.h>
#include <string.h>

#define LEVEL_RATE 48000.0
#define LEVEL_LOOP 24000  // the phrase, half a second, which goes round

// One string of the phrase, added to the loop from `at` seconds on and round its end. Overtones as a pickup hears a
// plucked string, 1/k and less where the pick is, rolled off above 900 Hz, a little sharp of whole multiples, the
// higher ones dying sooner; the pick's bump at the start; damped after `hold` seconds, dying away with `release`.
static inline void level_string(float *loop, double hz, double at, double amp, double tau, double hold, double release) {
  enum { MOST = 40 };
  double w[MOST], a[MOST], decay[MOST], phase[MOST];
  int parts = 0;
  for (int k = 1; k * hz < 7000 && k <= MOST; k++, parts++) {
    double f = k * hz * sqrt(1 + 1e-4 * k * k);
    w[parts] = 2 * M_PI * f / LEVEL_RATE;
    a[parts] = fabs(sin(k * M_PI * 0.15)) / k / sqrt(1 + (f / 900.0) * (f / 900.0));
    decay[parts] = tau / (1 + 0.3 * (k - 1)) * LEVEL_RATE;
    phase[parts] = 1.7 * k * k;
  }
  int from = (int)(at * LEVEL_RATE), length = (int)((hold + 7 * release) * LEVEL_RATE);
  double held = hold * LEVEL_RATE;
  for (int t = 0; t < length; t++) {
    double env = (t < 96 ? t / 96.0 : 1.0) * (1 + 0.9 * exp(-t / (0.02 * LEVEL_RATE)));
    if (t > held) env *= exp(-(t - held) / (release * LEVEL_RATE));
    double s = 0;
    for (int p = 0; p < parts; p++) s += a[p] * exp(-t / decay[p]) * sin(w[p] * t + phase[p]);
    loop[(from + t) % LEVEL_LOOP] += (float)(amp * env * s);
  }
}

// The guitar a tone is measured with: a made-up phrase, an accented power chord, a softer chord and a soft note dying
// away. The single low pluck before it said how loud a tone is with a low note alone: recorded guitar then came out of
// one tone in ten more than 4 dB off the others, and of the worst 15 dB off. So the phrase is shaped after recorded
// dry guitar: where its sound is (most of it under 700 Hz, and some up to 5 kHz), and how much of the time it is loud
// and how much quiet, which is what tells a clean tone, as loud as the playing, from a distorted one, as loud whatever
// comes in. Its loudest 50 ms are 4 dB under 1 and all of it 10.8 dB under, which is as loud as that pluck was at the
// same setting, and as loud as a recorded guitar whose peaks, taken over 5 s at a time, are about 2 dB over 1 in
// ordinary playing and 5 dB over when hit hard. (tonehost/README.md has what was measured.)
static inline void level_phrase(float *loop) {
  static const struct { double at, db, tau, strum, hold, release; int notes[3]; } hits[] = {
      {0.00, 0, 0.6, 0, 0.14, 0.01, {40, 47, 52}},         // E5
      {0.15, -7.5, 0.5, 0.006, 0.14, 0.01, {55, 59, 64}},  // G B E
      {0.30, -12, 0.25, 0, 0.10, 0.02, {57}},              // A
  };
  memset(loop, 0, LEVEL_LOOP * sizeof *loop);
  for (unsigned h = 0; h < sizeof hits / sizeof *hits; h++)
    for (int i = 0; i < 3 && hits[h].notes[i]; i++)
      level_string(loop, 440.0 * pow(2, (hits[h].notes[i] - 69) / 12.0), hits[h].at + i * hits[h].strum,
                   pow(10, hits[h].db / 20), hits[h].tau, hits[h].hold, hits[h].release);
  double most = 0;
  for (int from = 0; from < LEVEL_LOOP; from += 240) {  // the loudest 50 ms, round the end too
    double sum = 0;
    for (int i = 0; i < 2400; i++) sum += (double)loop[(from + i) % LEVEL_LOOP] * loop[(from + i) % LEVEL_LOOP];
    if (sum > most) most = sum;
  }
  float gain = (float)(pow(10, -4 / 20.0) / sqrt(most / 2400));
  for (int i = 0; i < LEVEL_LOOP; i++) loop[i] *= gain;
}

// The meter: a sample weighted as the ear hears it, less of the lows and more of the highs (the K-weighting of ITU-R
// BS.1770, at 48 kHz). `z` is the filter's own, zeros to begin with.
static inline double level_weigh(double z[4], double x) {
  static const double b[2][3] = {{1.53512485958697, -2.69169618940638, 1.19839281085285}, {1.0, -2.0, 1.0}};
  static const double a[2][2] = {{-1.69065929318241, 0.73248077421585}, {-1.99004745483398, 0.99007225036621}};
  for (int s = 0; s < 2; s++) {
    double y = b[s][0] * x + z[2 * s];
    z[2 * s] = b[s][1] * x - a[s][0] * y + z[2 * s + 1];
    z[2 * s + 1] = b[s][2] * x - a[s][1] * y;
    x = y;
  }
  return x;
}

// The loudness of `count` weighted samples whose squares add up to `sum`, in dB (LUFS, of the one channel)
static inline float level_db(double sum, double count) {
  return (float)(-0.691 + 10 * log10((count > 0 ? sum / count : 0) + 1e-12));
}

#endif
