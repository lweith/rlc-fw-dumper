# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Loren Weith
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
# Append-only boot ROM (boot_stub.s): slot 0 = a stub that boots the LAST live
# slot; images are appended into blank slots without erasing the chip.
#   make patch SLOT=1                        first burn: stub + slot 1 on a blank image
#   minipro -p DEV -r rom_now.bin            later: read the chip back, then
#   make patch SLOT=2 BASE=rom_now.bin       overlay slot 2 -> rom_patch.bin
#   make stub                                just the stub (boot_stub.bin)
# The patch is refused if any byte would need a 0->1 change. It prints the
# minipro command; set DEV= to your part (e.g. DEV=AM27C040).
#
# The BANNER file is embedded verbatim into the image; the firmware prints it
# over the SCI before the XMODEM transfer. Edit header.txt (or point BANNER= at
# any file) and re-run make -- no source edit needed.
#
# NOTE: comments stay on their OWN lines. An inline comment after a value
# (VAR := x   # ...) captures the trailing spaces INTO the value in Make.

ASL     ?= asl
P2BIN   ?= p2bin
# CC/CFLAGS build rlcpatch, the small C image-surgery helper (no Python).
CC      ?= cc
CFLAGS  ?= -O2 -std=c89 -Wall
CPU     := 68HC16
SRC     := sram_dump.s
STEM    := $(basename $(SRC))
# BAUD = serial rate for the dump. 19200 = RLC's documented max (default);
#        9600 = stock default (safest first dump); 57600 = beyond-stock, emu-proven.
BAUD    ?= 19200
# SCBR = SCI divisor computed (rounded) from BAUD at f_sys = 16.777216 MHz
SCBR    := $(shell echo $$(( (16777216 + 16*$(BAUD)) / (32*$(BAUD)) )))
# BANNER = file embedded into the image (override: make BANNER=other.txt).
#          The token @BAUD@ inside it is replaced with the BAUD value at build time,
#          so the banner's advertised rate always matches what the firmware runs.
BANNER  ?= banner.txt
# OUT = output image name (override: make OUT=recover.bin)
OUT     ?= sram_dump.bin
# IMGTOP = last address; 0x0-0x7ffff spans the full 512 KB boot window
IMGTOP  := 0x7ffff
# FILL = filler byte for unused cells (0xff = erased-EPROM/flash state)
FILL    := 0xff
# STAGE = fixed name the source BINCLUDEs
STAGE   := banner.bin

# SLOTSZ = bytes per boot-ROM slot. FIXED for the life of a chip once its stub
#          is burned: every later slot build must use the same value.
SLOTSZ  ?= 16384
# SLOT = slot index for `make patch` (1 .. 512K/SLOTSZ-1; slot 0 is the stub)
SLOT    ?=
# BASE = image to overlay onto: a readback of the chip, or - for blank ($FF)
BASE    ?= -
# PATCH = output image for `make patch`
PATCH   ?= rom_patch.bin
# DEV = minipro device name, only used to print the burn command
DEV     ?= <DEV>
STUB    := boot_stub
SLOTB    = $(shell echo $$(( $(SLOT) * $(SLOTSZ) )))
SLOTE    = $(shell echo $$(( $(SLOT) * $(SLOTSZ) + $(SLOTSZ) - 1 )))

# --- Bovine bootloader (`make bovine FW=host.bin`) -------------------------
# FW = the host firmware image to graft the cow into (bring your own; e.g. a
#      minipro readback of your current chip, or an RLC update image).
# BOVBASE = where the cow lands in the host's free space. Default $2D000 sits
#      in the large $FF gap of the v2.1x ClubDlx2 images; override for others.
# BOVOUT = grafted output image. The host's entry PC/IZ are read out of FW by
#          rlcpatch inside the recipe (so no parse-time tooling is needed).
FW      ?=
BOVBASE ?= 0x2D000
BOVOUT  ?= bovine.bin
PATCHER := rlcpatch

.PHONY: all clean stub patch bovine

all: $(OUT)

# The C image-surgery helper (replaces the old Python patchers).
$(PATCHER): $(PATCHER).c
	$(CC) $(CFLAGS) -o $@ $<

# Slot 0 only, assembled for SLOTSZ; boot_stub.bin is the full 512 KB view.
stub: $(STUB).s
	$(ASL) -cpu $(CPU) -D SLOTSZ=$(SLOTSZ) -L $(STUB).s
	$(P2BIN) $(STUB).p $(STUB)_raw.bin -l $(FILL) -r 0x0-$$(( $(SLOTSZ) - 1 ))
	$(P2BIN) $(STUB).p $(STUB).bin -l $(FILL) -r 0x0-$(IMGTOP)

# Dumper assembled to run from slot SLOT, overlaid with the stub onto BASE.
patch: stub $(SRC) $(BANNER) $(PATCHER)
	@test -n "$(SLOT)" || { echo "usage: make patch SLOT=n [BASE=readback.bin]"; exit 1; }
	sed 's/@BAUD@/$(BAUD)/g' "$(BANNER)" > $(STAGE)
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -D SLOTSZ=$(SLOTSZ) -D SLOTBASE=$(SLOTB) \
		-o slot$(SLOT).p -olist slot$(SLOT).lst -L $(SRC)
	$(P2BIN) slot$(SLOT).p slot$(SLOT)_raw.bin -l $(FILL) -r $(SLOTB)-$(SLOTE)
	./$(PATCHER) overlay --base "$(BASE)" --out $(PATCH) --slotsz $(SLOTSZ) \
		0:$(STUB)_raw.bin $(SLOTB):slot$(SLOT)_raw.bin
	@echo "burn:   minipro -p $(DEV) -w $(PATCH)    (add -e if the part is FLASH: no erase!)"

# Bovine: assemble the cow for BOVBASE with the host's entry/IZ baked in, then
# graft it into FW and redirect the reset vector. Full image -> ERASE + burn.
bovine: $(SRC) $(BANNER) $(PATCHER)
	@test -n "$(FW)" || { echo "usage: make bovine FW=host.bin [BOVBASE=0x2D000]"; exit 1; }
	sed 's/@BAUD@/$(BAUD)/g' "$(BANNER)" > $(STAGE)
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -D BOVINE -D BOVBASE=$(BOVBASE) \
		-D HOSTPC=`./$(PATCHER) probe-pc "$(FW)"` \
		-D HOSTIZ=`./$(PATCHER) probe-iz "$(FW)"` \
		-o bovine.p -olist bovine.lst -L $(SRC)
	$(P2BIN) bovine.p bovine_raw.bin -l $(FILL)
	./$(PATCHER) bovine --fw "$(FW)" --cow bovine_raw.bin \
		--base $(BOVBASE) --out $(BOVOUT)
	@echo "burn:   minipro -p $(DEV) -w $(BOVOUT)    (UV EPROM: erase first)"

# Rebuild whenever the source OR the chosen banner file changes.
$(OUT): $(SRC) $(BANNER)
	sed 's/@BAUD@/$(BAUD)/g' "$(BANNER)" > $(STAGE)
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -L $(SRC)
	$(P2BIN) $(STEM).p $(OUT) -l $(FILL) -r 0x0-$(IMGTOP)
	@echo "built $(OUT) from banner '$(BANNER)' at $(BAUD) baud (SCBR=$(SCBR)):"
	@ls -l $(OUT)

clean:
	rm -f $(OUT) $(STAGE) $(STEM).p $(STEM).lst $(STUB).p $(STUB).lst $(STUB).bin \
		$(STUB)_raw.bin slot*.p slot*.lst slot*_raw.bin $(PATCH) \
		bovine.p bovine.lst bovine_raw.bin $(BOVOUT) $(PATCHER)
