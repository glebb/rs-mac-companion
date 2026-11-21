// Helix Native's engine: see engine.h. The functions are the framework's own, by the signatures of the HelixCore.h that
// Line 6 installs in it. Nothing is loaded here: the library is the one the plug-in brought, or there is none.
#include "engine.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int (*g_load)(int instance, void *data, size_t size, bool reset_signal_flows);
static int (*g_write)(int instance, void *data, size_t size);
static int (*g_mute)(int instance, bool silent);

int helix_engine_find(void) {
  if (g_load) return 1;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i), *last = name ? strrchr(name, '/') : NULL;
    if (!last || strcmp(last, "/HelixCoreLib")) continue;
    void *lib = dlopen(name, RTLD_NOLOAD | RTLD_LAZY);
    if (!lib) continue;
    g_load = (__typeof__(g_load))dlsym(lib, "hc_loadPreset");
    g_write = (__typeof__(g_write))dlsym(lib, "hc_writePreset");
    g_mute = (__typeof__(g_mute))dlsym(lib, "hc_mute");
    if (g_load && g_write && g_mute) return 1;
    g_load = NULL;
  }
  return 0;
}

int helix_engine_load(int instance, const void *preset, size_t n) {
  void *copy = g_load ? malloc(n) : NULL;  // the engine's argument isn't const
  if (!copy) return -1;
  memcpy(copy, preset, n);
  int result = g_load(instance, copy, n, true);  // true: its signal flows start afresh, as when the plug-in loads a state
  free(copy);
  return result;
}

int helix_engine_read(int instance, void *preset, size_t n) { return g_load ? g_write(instance, preset, n) : -1; }

int helix_engine_mute(int instance, int silent) { return g_load ? g_mute(instance, silent != 0) : -1; }
