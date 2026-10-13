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

.PHONY: all clean stub patch bovine bovine-slots bovine-slot bovine-revoke FORCE

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
patch: stub $(SRC) $(STAGE) $(IDSTAGE) $(PATCHER)
	@test -n "$(SLOT)" || { echo "usage: make patch SLOT=n [BASE=readback.bin]"; exit 1; }
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -D SLOTSZ=$(SLOTSZ) -D SLOTBASE=$(SLOTB) \
		-o slot$(SLOT).p -olist slot$(SLOT).lst -L $(SRC)
	$(P2BIN) slot$(SLOT).p slot$(SLOT)_raw.bin -l $(FILL) -r $(SLOTB)-$(SLOTE)
	./$(PATCHER) overlay --base "$(BASE)" --out $(PATCH) --slotsz $(SLOTSZ) \
		0:$(STUB)_raw.bin $(SLOTB):slot$(SLOT)_raw.bin
	@echo "burn:   minipro -p $(DEV) -w $(PATCH)    (add -e if the part is FLASH: no erase!)"

# Bovine: assemble the cow for BOVBASE with the host's entry/IZ baked in, then
# graft it into FW and redirect the reset vector. Full image -> ERASE + burn.
# $(STAGE)/$(IDSTAGE) stage banner.bin + ident.bin (with version substitution)
# before asl, so the cow identifies its build like every other target.
bovine: $(SRC) $(STAGE) $(IDSTAGE) $(PATCHER)
	@test -n "$(FW)" || { echo "usage: make bovine FW=host.bin [BOVBASE=0x2D000]"; exit 1; }
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -D BOVINE -D BOVBASE=$(BOVBASE) \
		-D HOSTPC=`./$(PATCHER) probe-pc "$(FW)"` \
		-D HOSTIZ=`./$(PATCHER) probe-iz "$(FW)"` \
		-o bovine.p -olist bovine.lst -L $(SRC)
	$(P2BIN) bovine.p bovine_raw.bin -l $(FILL)
	./$(PATCHER) bovine --fw "$(FW)" --cow bovine_raw.bin \
		--base $(BOVBASE) --out $(BOVOUT)
	@echo "burn:   minipro -p $(DEV) -w $(BOVOUT)    (UV EPROM: erase first)"

# --- Bovine slots (`make bovine-slots FW=host.bin`) --------------------------
# bovine_stub.s is grafted ONCE where the cow used to go and owns the reset
# vector; cows go into append-only slots in the host's blank space, added later
# without erasing. The layout is FIXED for the life of the chip once the stub
# is burned: every later build must use the same values.
#   make bovine-slots FW=host.bin [BASE=blank.bin]     first burn (ERASE + burn):
#        stub + this cow in slot 0. BASE = a readback of the ERASED chip: the
#        image is checked against it, so a stuck bit refuses the build.
#   make bovine-slot FW=host.bin BASE=now.bin [AT=addr] append this cow to the
#        next free slot (or AT) of a chip readback -> burn WITHOUT erasing
#   make bovine-revoke BASE=now.bin AT=addr             retire a slot (falls back)
#   ./rlcpatch bovslots --base now.bin                  list the slots
STUBBASE ?= 0x2D000
BSLOT0   ?= 0x30000
BSLOTSZ  ?= 0x2000
BNSLOTS  ?= 24
BSOUT    ?= bovslots.bin
BSLAYOUT  = --slot0 $(BSLOT0) --slotsz $(BSLOTSZ) --nslots $(BNSLOTS)
AT       ?=

# the cow, assembled to run at slot address $(1) + 8 (after the header)
define bovcow
	$(ASL) -cpu $(CPU) -D SCBRVAL=$(SCBR) -D BOVINE -D BOVBASE=$$(( $(1) + 8 )) \
		$(if $(BOVSECS),-D BOVSECS=$(BOVSECS)) \
		-D HOSTPC=`./$(PATCHER) probe-pc "$(FW)"` \
		-D HOSTIZ=`./$(PATCHER) probe-iz "$(FW)"` \
		-o bovcow.p -olist bovcow.lst -L $(SRC)
	$(P2BIN) bovcow.p bovcow_raw.bin -l $(FILL)
endef

bovine-slots: $(SRC) bovine_stub.s $(STAGE) $(IDSTAGE) $(PATCHER)
	@test -n "$(FW)" || { echo "usage: make bovine-slots FW=host.bin [BASE=erased-readback.bin]"; exit 1; }
	$(ASL) -cpu $(CPU) -D STUBBASE=$(STUBBASE) -D SLOT0=$(BSLOT0) -D SLOTSZ=$(BSLOTSZ) \
		-D NSLOTS=$(BNSLOTS) \
		-D HOSTPC=`./$(PATCHER) probe-pc "$(FW)"` \
		-D HOSTIZ=`./$(PATCHER) probe-iz "$(FW)"` \
		-o bovine_stub.p -olist bovine_stub.lst -L bovine_stub.s
	$(P2BIN) bovine_stub.p bovine_stub_raw.bin -l $(FILL)
	$(call bovcow,$(BSLOT0))
	./$(PATCHER) bovine --fw "$(FW)" --cow bovine_stub_raw.bin --base $(STUBBASE) --out bovstub.tmp
	./$(PATCHER) bovslot --base bovstub.tmp --cow bovcow_raw.bin --at $(BSLOT0) --out $(BSOUT) $(BSLAYOUT)
	@if [ "$(BASE)" != "-" ]; then \
		./$(PATCHER) overlay --base "$(BASE)" --out $(BSOUT) --slotsz 0 0:$(BSOUT) || exit 1; \
		echo "checked against the erased chip $(BASE): every byte programmable"; \
	fi
	@rm -f bovstub.tmp
	@echo "burn:   minipro -p $(DEV) -w $(BSOUT)    (UV EPROM: erase first; the last erase)"

bovine-slot: $(SRC) $(STAGE) $(IDSTAGE) $(PATCHER)
	@test -n "$(FW)" -a "$(BASE)" != "-" || { echo "usage: make bovine-slot FW=host.bin BASE=readback.bin [AT=slot-address]"; exit 1; }
	$(eval SLOTAT := $(or $(AT),$(shell ./$(PATCHER) nextslot --base "$(BASE)" $(BSLAYOUT))))
	@test -n "$(SLOTAT)" || { echo "no free slot"; exit 1; }
	$(call bovcow,$(SLOTAT))
	./$(PATCHER) bovslot --base "$(BASE)" --cow bovcow_raw.bin --at $(SLOTAT) --out $(BSOUT) $(BSLAYOUT)
	@echo "burn:   minipro -p $(DEV) -w $(BSOUT)    (NO erase: add -e)"

bovine-revoke: $(PATCHER)
	@test "$(BASE)" != "-" -a -n "$(AT)" || { echo "usage: make bovine-revoke BASE=readback.bin AT=slot-address"; exit 1; }
	./$(PATCHER) revoke --base "$(BASE)" --at $(AT) --out $(BSOUT) $(BSLAYOUT)
	@echo "burn:   minipro -p $(DEV) -w $(BSOUT)    (NO erase: add -e)"

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
		$(STUB).bin $(STUB)_raw.bin slot*.p slot*.lst slot*_raw.bin $(PATCH) \
		bovine.p bovine.lst bovine_raw.bin $(BOVOUT) $(PATCHER) \
		bovine_stub.p bovine_stub.lst bovine_stub_raw.bin bovcow.p bovcow.lst bovcow_raw.bin \
		bovstub.tmp $(BSOUT)
