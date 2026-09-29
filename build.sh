#!/bin/sh
# Build the SRAM-dump boot image for the MC68HC16Z1 board.
#
#   1. assemble   sram_dump.s  -> sram_dump.p   (asl)
#   2. flatten    sram_dump.p  -> sram_dump.bin (p2bin)
#   3. pad        sram_dump.bin to exactly 512 KB (the boot ROM size)
#
# The reset vector sits at file offset 0 (= address $000000); everything
# above the code is zero-filled padding.
set -e

cd "$(dirname "$0")"

# 0. stage the banner file the source BINCLUDEs (default: header.txt).
#    Override by copying a different file to banner.bin, or use the Makefile
#    (make BANNER=other.txt).
cp -f header.txt banner.bin

# 1. assemble (clean-room source; -L emits sram_dump.lst)
/usr/bin/asl -cpu 68HC16 -L sram_dump.s

# 2. flatten .p to a full 512 KB image, filling ALL unused cells with $FF
#    (the erased-EPROM state).  -r spans the whole 0x0-0x7FFFF boot window, so
#    the output is already 524288 bytes -- no separate pad step -- and a
#    programmer skips the blank $FF cells, burning only the ~few hundred used
#    bytes instead of programming all 512 KB to zero.
/usr/bin/p2bin sram_dump.p sram_dump.bin -l 0xff -r 0x0-0x7ffff

echo "built sram_dump.bin:"
ls -l sram_dump.bin
