#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Loren Weith
"""Overlay regions onto a boot-ROM image without needing an erase.

EPROM/flash programming can only clear bits (1->0).  Each REGION is written
into a copy of BASE at its address; every resulting byte must satisfy
(old & new) == new, or the patch is refused.  Starting BASE from a readback of
the chip means the output matches the chip everywhere outside the new data,
so a normal full-chip write + verify passes.

usage: rom_patch.py --base BASE --out OUT --slotsz N [--size N]
                    ADDR:FILE [ADDR:FILE ...]
       (BASE '-' = a blank all-$FF image)
"""
import argparse, sys


def live_slots(img, slotsz):
    """Indices of slots 1.. whose header byte is neither blank nor revoked."""
    return [i for i in range(1, len(img) // slotsz) if img[i * slotsz] not in (0xFF, 0x00)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--slotsz", type=lambda v: int(v, 0), required=True)
    ap.add_argument("--size", type=lambda v: int(v, 0), default=0x80000)
    ap.add_argument("regions", nargs="+", metavar="ADDR:FILE")
    a = ap.parse_args()

    if a.base == "-":
        img = bytearray(b"\xff" * a.size)
    else:
        img = bytearray(open(a.base, "rb").read())
        if len(img) != a.size:
            sys.exit(f"{a.base}: {len(img)} bytes, expected {a.size}")
    before = live_slots(img, a.slotsz)

    bad = []
    changed = 0
    for spec in a.regions:
        addr_s, path = spec.split(":", 1)
        addr = int(addr_s, 0)
        data = open(path, "rb").read()
        if addr + len(data) > a.size:
            sys.exit(f"{path}: {len(data)} bytes at {addr:#x} overruns the {a.size:#x}-byte ROM")
        for i, new in enumerate(data):
            old = img[addr + i]
            if old & new != new:
                bad.append((addr + i, old, new))
            elif old != new:
                img[addr + i] = new
                changed += 1

    if bad:
        print(f"REFUSED: {len(bad)} byte(s) would need a 0->1 bit change (erase required):",
              file=sys.stderr)
        for addr, old, new in bad[:16]:
            print(f"  {addr:#07x}: chip {old:02x} -> wanted {new:02x}", file=sys.stderr)
        if len(bad) > 16:
            print(f"  ... and {len(bad) - 16} more", file=sys.stderr)
        sys.exit(1)

    open(a.out, "wb").write(img)
    after = live_slots(img, a.slotsz)
    print(f"{a.out}: {changed} byte(s) newly programmed vs base")
    print(f"live slots before: {before or 'none'}   after: {after or 'none'}")
    print(f"stub will boot: slot {after[-1]}" if after else "stub will boot: nothing")


if __name__ == "__main__":
    main()
