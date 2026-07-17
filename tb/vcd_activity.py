#!/usr/bin/env python3
"""Report a conservative global switching activity from an RTL VCD."""
import re
import sys

path = sys.argv[1]
width = {}
name = {}
values = {}
toggles = 0
clock_rises = 0
clock_code = None
in_defs = True

with open(path, encoding="utf-8", errors="ignore") as f:
    for raw in f:
        line = raw.strip()
        if in_defs:
            if line == "$enddefinitions $end":
                in_defs = False
                continue
            if line.startswith("$var"):
                fields = line.split()
                code = fields[3]
                width.setdefault(code, int(fields[2]))
                name.setdefault(code, fields[4])
                if fields[4] == "clk":
                    clock_code = code
            continue
        if not line or line[0] in "#$":
            continue
        if line[0] in "01xXzZ":
            code, bits = line[1:], line[0].lower()
        elif line[0] in "bBrR":
            fields = line[1:].split()
            if len(fields) != 2:
                continue
            bits, code = fields[0].lower(), fields[1]
        else:
            continue
        if code not in width:
            continue
        bits = bits.zfill(width[code])
        old = values.get(code)
        values[code] = bits
        if old is None or len(old) != len(bits) or any(c not in "01" for c in old + bits):
            continue
        if code == clock_code and old == "0" and bits == "1":
            clock_rises += 1
        if name[code] not in ("clk", "rst_n"):
            toggles += sum(a != b for a, b in zip(old, bits))

bits = sum(w for code, w in width.items() if name[code] not in ("clk", "rst_n"))
activity = toggles / (bits * clock_rises) if bits and clock_rises else 0.0
print(f"clock_rises={clock_rises}")
print(f"unique_signal_bits={bits}")
print(f"bit_toggles={toggles}")
print(f"activity_per_bit_per_cycle={activity:.8f}")
