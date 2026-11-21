# From rs-tonehost

These files are copied unchanged from [rearmed-mods](https://github.com/glebb/rearmed-mods) at commit `34dc4c1`
(MIT License, Copyright (c) 2026 rearmed-mods contributors):

| File | There |
|---|---|
| `tone_level.h` | `tonehost/tone_level.h`: the reference guitar phrase and the K-weighted loudness meter |
| `preset_places.h` | `tonehost/preset_places.h`: where a parameter's value goes in a preset for Helix's engine |
| `engine.c`, `engine.h` | `tonehost/helix/engine.c`, `engine.h`: Helix Native's engine, as the plug-in has loaded it |

`tools/measure_helix.m` builds with them, so that the HX Stomp's calibration measures a tone as tonehost does.
Copy them again when tonehost changes how it measures.
