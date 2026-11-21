// Helix Native's engine, HelixCoreLib, as the plug-in has loaded it in this process. A preset that make_presets.py built
// goes straight to it, with no saved state. README.md has what is known of it.
#ifndef HELIX_ENGINE_H
#define HELIX_ENGINE_H
#include <stddef.h>

int helix_engine_find(void);                                        // 1 if it is loaded and has what is used here
int helix_engine_load(int instance, const void *preset, size_t n);  // 0 if the engine took the preset
int helix_engine_read(int instance, void *preset, size_t n);        // 0 if it gave the preset the instance has
int helix_engine_mute(int instance, int silent);                    // 0 if it did
#endif
