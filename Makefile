# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 KN6FLN
#
# Makefile - RLC-Club Dlx2 NVSRAM dumper firmware (MC68HC16Z1 / CPU16)
#
#   make                     build sram_dump.bin (banner.txt, 19200 baud)
#   make BAUD=9600           build at 9600 baud (stock default) instead of 19200
#   make BAUD=57600          build at 57600 baud (beyond stock, emulator-proven)
#   make BANNER=mymoo.txt    embed a different banner/data file into the image
#   make OUT=recover.bin     write the image to a different name
#   make BANNER=x.txt OUT=y.bin BAUD=9600
#   make clean
#   make clean all           force a full rebuild
#
# The BANNER file is embedded verbatim into the image; the firmware prints it
# over the SCI before the XMODEM transfer. Edit header.txt (or point BANNER= at
# any file) and re-run make -- no source edit needed.
#
# NOTE: comments stay on their OWN lines. An inline comment after a value
# (VAR := x   # ...) captures the trailing spaces INTO the value in Make.

ASL     ?= asl
P2BIN   ?= p2bin
CPU     := 68HC16
SRC     := sram_dump.s
STEM    := $(basename $(SRC))
# BAUD = serial rate for the dump. 19200 = RLC's documented max (default);
#        9600 = stock default (safest first dump); 57600 = beyond-stock, emu-proven.
BAUD    ?= 19200
# SCBR = SCI divisor computed (rounded) from BAUD at f_sys = 16.777216 MHz
SCBR    := $(shell echo $$(( (16777216 + 16*$(BAUD)) / (32*$(BAUD)) )))
# BANNER = file embedded into the image (override: make BANNER=other.txt)
BANNER  ?= banner.txt
# OUT = output image name (override: make OUT=recover.bin)
OUT     ?= sram_dump.bin
# IMGTOP = last address; 0x0-0x7ffff spans the full 512 KB boot window
IMGTOP  := 0x7ffff
# FILL = filler byte for unused cells (0xff = erased-EPROM/flash state)
FILL    := 0xff
# STAGE = fixed name the source BINCLUDEs
STAGE   := banner.bin

.PHONY: all clean

all: $(OUT)

# Rebuild whenever the source OR the chosen banner file changes.
$(OUT): $(SRC) $(BANNER)
	cp -f "$(BANNER)" $(STAGE)
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -L $(SRC)
	$(P2BIN) $(STEM).p $(OUT) -l $(FILL) -r 0x0-$(IMGTOP)
	@echo "built $(OUT) from banner '$(BANNER)' at $(BAUD) baud (SCBR=$(SCBR)):"
	@ls -l $(OUT)

clean:
	rm -f $(OUT) $(STAGE) $(STEM).p $(STEM).lst
