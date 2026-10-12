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
# over the SCI before the XMODEM transfer. Edit banner.txt (or point BANNER= at
# any file) and re-run make -- no source edit needed.
#
# Every image identifies its source: version.sh derives a semver string, the
# branch and the commit date from git, the firmware prints them at boot and
# monitor command 'I' returns them. Outside a git checkout, pass them in:
#   make VERSION=1.1.0 BRANCH=release CDATE=2026-10-12
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
# IDSTAGE = the identification line the source BINCLUDEs: VERSION (BRANCH, CDATE)
IDSTAGE := ident.bin
VINFO   := $(shell sh ./version.sh)
VERSION ?= $(word 1,$(VINFO))
BRANCH  ?= $(word 2,$(VINFO))
CDATE   ?= $(word 3,$(VINFO))

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

.PHONY: all clean stub patch FORCE

all: $(OUT)

# Slot 0 only, assembled for SLOTSZ; boot_stub.bin is the full 512 KB view.
stub: $(STUB).s
	$(ASL) -cpu $(CPU) -D SLOTSZ=$(SLOTSZ) -L $(STUB).s
	$(P2BIN) $(STUB).p $(STUB)_raw.bin -l $(FILL) -r 0x0-$$(( $(SLOTSZ) - 1 ))
	$(P2BIN) $(STUB).p $(STUB).bin -l $(FILL) -r 0x0-$(IMGTOP)

# Dumper assembled to run from slot SLOT, overlaid with the stub onto BASE.
patch: stub $(SRC) $(STAGE) $(IDSTAGE)
	@test -n "$(SLOT)" || { echo "usage: make patch SLOT=n [BASE=readback.bin]"; exit 1; }
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -D SLOTSZ=$(SLOTSZ) -D SLOTBASE=$(SLOTB) \
		-o slot$(SLOT).p -olist slot$(SLOT).lst -L $(SRC)
	$(P2BIN) slot$(SLOT).p slot$(SLOT)_raw.bin -l $(FILL) -r $(SLOTB)-$(SLOTE)
	python3 -I rom_patch.py --base "$(BASE)" --out $(PATCH) --slotsz $(SLOTSZ) \
		0:$(STUB)_raw.bin $(SLOTB):slot$(SLOT)_raw.bin
	@echo "burn:   minipro -p $(DEV) -w $(PATCH)    (add -e if the part is FLASH: no erase!)"

# Rebuild whenever the source, the banner or the identification changes.
$(OUT): $(SRC) $(STAGE) $(IDSTAGE)
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -L $(SRC)
	$(P2BIN) $(STEM).p $(OUT) -l $(FILL) -r 0x0-$(IMGTOP)
	@echo "built $(OUT) $(VERSION) ($(BRANCH), $(CDATE)) from banner '$(BANNER)' at $(BAUD) baud (SCBR=$(SCBR)):"
	@ls -l $(OUT)

# The staged files are regenerated on every run but replaced only when their
# content changes, so a new commit rebuilds the image and an unchanged tree
# does not. The banner may use @BAUD@ @VERSION@ @BRANCH@ @DATE@.
$(STAGE): $(BANNER) FORCE
	@sed -e 's|@BAUD@|$(BAUD)|g' -e 's|@VERSION@|$(VERSION)|g' \
		-e 's|@BRANCH@|$(BRANCH)|g' -e 's|@DATE@|$(CDATE)|g' "$(BANNER)" > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

$(IDSTAGE): FORCE
	@printf '%s' '$(VERSION) ($(BRANCH), $(CDATE))' > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

FORCE:

clean:
	rm -f $(OUT) $(STAGE) $(IDSTAGE) *.tmp $(STEM).p $(STEM).lst $(STUB).p $(STUB).lst \
		$(STUB).bin $(STUB)_raw.bin slot*.p slot*.lst slot*_raw.bin $(PATCH)
