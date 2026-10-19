#!/usr/bin/env python3
"""Hex/qword dump: dump.py <hexaddr> [len]"""
import re
import struct
import sys

from probe import read

a = int(sys.argv[1], 16); n = int(sys.argv[2]) if len(sys.argv) > 2 else 256
b = read(a, n)
for i in range(0, len(b), 16):
    q = struct.unpack_from('<QQ', b, i)
    print(f"{a+i:x}  {q[0]:016x} {q[1]:016x}  {re.sub(rb'[^ -~]', b'.', b[i:i+16]).decode()}")
