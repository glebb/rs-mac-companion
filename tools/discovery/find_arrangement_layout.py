#!/usr/bin/env python3
"""Re-derive game_profile.json's arrangement values from the running game.

Use after a Rocksmith update (see docs/when-the-game-updates.md). Needs:
  - Rocksmith running with a song selected (in the song's menu or playing it),
  - build/rsprobe attached to it:  build/rsprobe $(pgrep -x Rocksmith2014) &
  - the song index built (index_songs.py), to know that arrangement's tone keys.

Usage: find_arrangement_layout.py <arrangement>     e.g. skid18an_lead

How it works: the game keeps one description object per arrangement. Each holds the arrangement
name and the five tone keys (Base, A..D) as 32-byte small-buffer strings, and starts with a type
pointer (vtable) into the game's data segment. We find where the name and the tone keys sit in
memory, find the type pointer just before them, and report the offsets relative to it.
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
import paths  # noqa: E402
from probe import read, send  # noqa: E402

IMAGE_BASE = 0x100000000


def q(a):
    b = read(a, 8)
    return struct.unpack("<Q", b)[0] if b else None


def find_image():
    """Main executable's load address and the slid range of its __DATA segment."""
    for a in range(IMAGE_BASE, IMAGE_BASE + 0x10000000, 0x1000):
        h = read(a, 32)
        if h and struct.unpack_from("<I", h)[0] == 0xFEEDFACF and struct.unpack_from("<I", h, 12)[0] == 2:
            ncmds, sizeofcmds = struct.unpack_from("<II", h, 16)
            cmds = read(a + 32, sizeofcmds)
            off = 0
            for _ in range(ncmds):
                cmd, size = struct.unpack_from("<II", cmds, off)
                if cmd == 0x19 and cmds[off + 8:off + 24].rstrip(b"\0") == b"__DATA":
                    vm, vs = struct.unpack_from("<QQ", cmds, off + 24)
                    slide = a - IMAGE_BASE
                    return a, slide, (vm + slide, vm + slide + vs)
                off += size
    sys.exit("main executable not found in memory")


def string_fields(text):
    """Addresses of 32-byte string fields holding `text`: inline buffers, or fields pointing at it."""
    hits = [int(h, 16) for h in send(f"findhex {text.encode().hex()}00 5000").split() if len(h) > 6 and h != "end"]
    fields = set()
    for h in hits:
        if len(text) < 16:
            fields.add(h)  # short strings live inside the field itself
        for p in send(f"findptr {h:x} 200").split():  # long strings: the field's first word points at them
            if len(p) > 6 and p != "end":
                fields.add(int(p, 16))
    return fields


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    name = sys.argv[1]
    arr = None
    with open(paths.INDEX) as f:
        for line in f:
            a = json.loads(line)
            if a["arrangement"].lower() == name.lower():
                arr = a
                break
    if not arr:
        sys.exit(f"{name} is not in the song index ({paths.INDEX})")
    base, slide, (data_lo, data_hi) = find_image()
    print(f"image at 0x{base:x} (slide 0x{slide:x}), __DATA 0x{data_lo:x}-0x{data_hi:x}")

    name_fields = string_fields(arr["arrangement"])
    slots = [s for s in arr["slots"]]
    slot_fields = [string_fields(s) if s else None for s in slots]
    print(f"name '{arr['arrangement']}' in {len(name_fields)} field(s); tone keys {slots}")

    found = []
    for stride in (0x20, 0x18, 0x28):
        for f0 in slot_fields[0] or []:
            if all(sf is None or f0 + i * stride in sf for i, sf in enumerate(slot_fields)):
                for nf in name_fields:
                    if 0 < f0 - nf < 0x1000:
                        # The type pointer: nearest word before the name pointing into __DATA.
                        for back in range(0, 0x200, 8):
                            v = q(nf - back)
                            if v and data_lo <= v < data_hi:
                                obj = nf - back
                                found.append((obj, v, nf - obj, f0 - obj, stride))
                                break
    if not found:
        sys.exit("no arrangement object found: is that arrangement's song selected in the game?")

    # Several layouts can fit (a tone key may equal the arrangement name, and objects can hold more
    # than one tone list); the real one has the name first and the tone list closest after it.
    vtables = {}
    for obj, vt, name_off, tones_off, stride in found:
        if tones_off > name_off:
            vtables.setdefault((vt, name_off, tones_off, stride), []).append(obj)
    ranked = sorted(vtables.items(), key=lambda kv: (kv[0][2] - kv[0][1], kv[0][1]))
    print(f"{len(ranked)} candidate layout(s), most likely first:")
    for (vt, name_off, tones_off, stride), objs in ranked[:3]:
        n = len([h for h in send(f"findptr {vt:x} 500").split() if len(h) > 6 and h != "end"])
        print(f"\nobjects {[hex(o) for o in objs]}: type pointer 0x{vt:x}, {n} objects of this type in memory")
        print("game_profile.json values:")
        print(json.dumps({
            "image_base": hex(IMAGE_BASE),
            "arrangement_vtable": f"0x{vt - slide:X}",
            "arrangement_name_offset": hex(name_off),
            "arrangement_tones_offset": hex(tones_off),
            "arrangement_tone_stride": hex(stride),
        }, indent=2))
    print("\nAlso update executable_sha256 (shasum -a 256 on the game executable).")


if __name__ == "__main__":
    main()
