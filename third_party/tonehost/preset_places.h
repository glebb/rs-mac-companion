// Where a parameter has its value in a preset the host hands a plug-in's engine: a template's "places" in the config.
// {"7": [1234, -60, 0]} is a knob: a float at byte 1234, -60 with the parameter at 0 and 0 with it at 1, and on along
// that line outside 0 to 1, as the plug-in itself goes. {"22": [1250]} is a switch: a byte, 1 with the parameter from
// 0.5 up.
#ifndef PRESET_PLACES_H
#define PRESET_PLACES_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// 0, or -1 for a place that isn't one or lies outside the preset: nothing is written then
static inline int place_value(uint8_t *preset, size_t size, const double *place, int count, float value) {
  if (count != 1 && count != 3) return -1;
  if (!(place[0] >= 0) || place[0] >= (double)size || place[0] != (double)(size_t)place[0]) return -1;
  size_t at = (size_t)place[0];
  if (count == 1) {
    preset[at] = value >= 0.5f;
    return 0;
  }
  if (size - at < sizeof(float)) return -1;
  float v = (float)(place[1] + (double)value * (place[2] - place[1]));
  memcpy(preset + at, &v, sizeof v);
  return 0;
}

// Whether two presets are the same but for the last digits of the knobs at their places: a plug-in works a knob's value
// out in its own arithmetic
static inline int place_same(uint8_t *a, const uint8_t *b, size_t size, const double *place, int count) {
  if (count != 3) return 1;  // a switch is a byte: the comparison of the whole has it
  if (!(place[0] >= 0) || place[0] >= (double)size || size - (size_t)place[0] < sizeof(float)) return 0;
  float x, y;
  memcpy(&x, a + (size_t)place[0], sizeof x);
  memcpy(&y, b + (size_t)place[0], sizeof y);
  float d = x > y ? x - y : y - x, m = x < 0 ? -x : x;
  if (!(d <= 1e-4f * (m > 1 ? m : 1))) return 0;
  memcpy(a + (size_t)place[0], &y, sizeof y);  // the same from here, for a comparison of the whole
  return 1;
}
#endif
