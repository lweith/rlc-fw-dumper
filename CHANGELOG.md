# Changelog

Versions follow semver as described under "Versioning" in `README.md`.

## 1.4.1

Three silicon facts the emulator did not model; all found on a real RLC-Club
(v2.16 host), confirmed in the MC68HC16Z1 User's Manual, reproduced in MAME
once modelled, and fixed without erasing the chip.

- The 20-bit indexed JMP adds its offset to the 16-bit index register only, not
  XK (manual 5.5.3; the 8/16-bit and E-offset modes do use XK). The 1.4.0 stub's
  `JMP 8,X` therefore landed in bank 0 on silicon (slot 0: the host's vector
  table, which happened to boot the host; other slots: a silent crash).
  `bovine_stub.s` now hands over through a table of absolute (EXT20) JMPs,
  reached with XK = 0 and a small IX: the same address under either reading.
- `make bovine-stubfix BASE=readback.bin` repairs a chip that carries the 1.4.0
  stub WITHOUT an erase: `bovine_stubfix.s` turns the old stub's `BNE SUM`
  (`B6 E0`) into `BRA` (`B0 40`, bits cleared only) into a corrected stub in the
  blank space after it. Verified on silicon.
- TMSK2's prescaler field (CPR) is write-once after reset (manual 8.7). The
  1.3.0/1.4.0 window wrote /256 and CHAIN's restore to /4 was ignored, so the
  host still ran 64x slow (the 1.4.0 "fix" passed only in the emulator). The
  window now runs on the untouched reset prescaler (TCNT wraps 64x a second,
  `BOVTICKS = BOVSECS*64`) and nothing writes TMSK2. Verified on silicon (the
  host's 10 s timer fires at 10 s after the chain).
- `bovine_tramp.s` (a 4-byte slot body that jumps to another slot's cow) and
  `bovine_beacon.s` (prints a slot's header and sum as the CPU reads them, then
  jumps on): the diagnostics used to find the above.

## 1.4.0

- Bovine slots: `bovine_stub.s`, grafted once in the cow's place, boots the
  highest slot whose header and 16-bit sum check out, from 24 append-only 8 KB
  slots in the host's blank space; no good slot chains straight to the host.
  New cows are added and old ones revoked without erasing the chip.
  `make bovine-slots` (first burn, checked against a readback of the erased
  chip so stuck bits refuse the build), `make bovine-slot`, `make bovine-revoke`;
  `rlcpatch bovslots|nextslot|bovslot|revoke`. `BOVSECS=` reaches slot builds.
- Fix (1.3.1 content): `CHAIN` restores the GPT prescaler (`TMSK2`) to its reset
  value. 1.3.0 left it at /256 from the escape window, and a host that relies on
  the reset value ran its GPT timebase 64× slow on every bovine boot (stock
  RLC-Club v2.16: 10 ms tick -> 640 ms; timers, CW and pacing all 64× slow).

## 1.3.0

- Bovine escape window is now timed by the on-chip GPT free-running counter
  (TCNT, prescale /256 = one wrap/second), counting `BOVSECS` (default 5)
  seconds. Accurate on real silicon regardless of instruction timing, unlike
  the old cycle-counted delay loop. No external chip (not the DS1286 RTC) and
  no SRAM write.
- One keypress now acts immediately: the key that breaks in is the mode byte —
  `g` enters the monitor, an XMODEM `NAK` starts the dump, any other key shows a
  menu and waits. No more silent two-step.
- On a keypress the cow prints the full ASCII-cow banner (`banner.bin`), and on
  time-out it prints `booting host...` so the hand-off is visible on serial.
- Verified in MAME on the matching machine for each product (base `rlcclub` with
  `Club-v2.16`, and `rlcclubd2` with `ClubDlx2-v2.16`): do-nothing chains to the
  host banner; a keypress reaches the cow (`V` -> `COW1`). Reminder: build the
  cow against the firmware for the actual board — wrong product = silent no-boot.

## 1.2.1

- Bovine: keep the on-chip COP watchdog alive for the whole of the cow's run.
  The COP is write-once-owned by the host, so the cow cannot disable it and must
  service `SWSR` continuously. It previously serviced only inside the wait loop,
  so the ~22 ms banner/ident print starved it and the board reset mid-banner (a
  boot loop on real silicon). `STROBE` now also services the COP on every byte
  sent, and the escape-window loop services on every iteration. The reset-default
  COP time-out is ~15.6 ms (SWP=1 from MODCLK), observed on the board and now
  modelled in the MAME harness so this class of bug is caught in emulation.

## 1.2.0

- Bovine bootloader (`make bovine FW=host.bin`): graft the cow into a host
  firmware's free `$FF` space and redirect the reset vector to it. On boot it
  opens a ~5 s window — a key enters the dumper/monitor; otherwise it restores a
  reset CPU state and chain-loads the host unchanged. `SYPCR` is never written
  on the chain path (write-once; belongs to the host); the COP is kept alive via
  `SWSR` and the DS1232 via the PQS1 strobe during the wait. Verified in MAME
  against `ClubDlx2-v2.16` (timeout boots stock; keypress reaches the monitor).
- Both Python patchers replaced by one C89 helper, `rlcpatch.c` (`overlay` /
  `probe` / `bovine`), built by the Makefile with `cc`. Python is no longer a
  build dependency; output is byte-identical to the old scripts.

## 1.1.0

- The image identifies its build: `sram_dump VERSION (BRANCH, DATE)` at boot,
  from `version.sh` (git tag, commit, branch and commit date).
- Monitor command `I` returns the same identification. `V` is unchanged.
- Banner files may use `@VERSION@`, `@BRANCH@` and `@DATE@` as well as `@BAUD@`.
- `make` rebuilds when the commit, banner or baud changes, and only then. The
  standalone and slot builds share one staging rule.

## 1.0.0

The first build proven on silicon: it dumped the full 256 KB configuration of
a base RLC-Club v2.15, burned as slot 2 of the append-only boot ROM.

- CS0 is programmed for the SRAM as an **8-bit** port (the SRAMs sit on D15–D8
  only). Earlier builds used a 16-bit port and read even bytes only.
- Append-only boot ROM: slot stub, slot builds, no-erase patching
  (`make patch`, `rom_patch.py`).
- Cow monitor (`g` after the banner): `V R W X J S`, using no RAM.
- External DS1232 watchdog strobed throughout; clock set to 16.78 MHz; 19200
  baud by default.
