#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB load command to the x86_64 slice of a (universal) Mach-O executable.

Writes a patched copy; it never edits the input in place. The command is appended after the
existing load commands, in the header padding before the first section, so nothing else moves.
Refuses if the dylib is already referenced, the slice is missing, or the padding isn't zero-filled.

Usage: add_load_dylib.py INPUT OUTPUT DYLIB_PATH   (e.g. @executable_path/libfoo.dylib)
"""
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_X86_64 = 0x01000007
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19


def x86_64_slice(data):
    """Offset of the x86_64 Mach-O inside the file (0 for a thin x86_64 file)."""
    (magic,) = struct.unpack_from(">I", data, 0)
    if magic == FAT_MAGIC:
        (n,) = struct.unpack_from(">I", data, 4)
        for i in range(n):
            cputype, _, offset, _, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            if cputype == CPU_TYPE_X86_64:
                return offset
        sys.exit("no x86_64 slice")
    if struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
        return 0
    sys.exit("not a Mach-O file")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, dst, dylib = sys.argv[1:]
    data = bytearray(open(src, "rb").read())
    base = x86_64_slice(data)
    magic, cputype, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, base)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_X86_64:
        sys.exit("x86_64 slice header not recognised")

    # Walk the load commands: reject duplicates, find where the first section's data starts.
    first_data = None
    off = base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_LOAD_DYLIB:
            (name_off,) = struct.unpack_from("<I", data, off + 8)
            name = bytes(data[off + name_off:off + size]).split(b"\0")[0].decode()
            if name == dylib:
                sys.exit(f"{dylib} is already loaded")
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for s in range(nsects):
                sect_offset = struct.unpack_from("<I", data, off + 72 + s * 80 + 48)[0]
                if sect_offset and (first_data is None or sect_offset < first_data):
                    first_data = sect_offset
        off += size

    name = dylib.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    end = 32 + sizeofcmds
    if first_data is None or end + cmdsize > first_data:
        sys.exit(f"not enough header space ({first_data - end if first_data else 0} bytes free, need {cmdsize})")
    if any(data[base + end:base + end + cmdsize]):
        sys.exit("header padding is not empty")

    # dylib_command: cmd, cmdsize, name offset, timestamp, current version, compatibility version
    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0, 0) + name
    data[base + end:base + end + cmdsize] = cmd.ljust(cmdsize, b"\0")
    struct.pack_into("<II", data, base + 16, ncmds + 1, sizeofcmds + cmdsize)
    open(dst, "wb").write(data)
    print(f"added LC_LOAD_DYLIB {dylib} ({cmdsize} bytes, {first_data - end - cmdsize} bytes still free)")


if __name__ == "__main__":
    main()
