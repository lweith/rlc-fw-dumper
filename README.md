# sram_dump — design notes and derivation

Read-only NVSRAM dumper for an MC68HC16Z1 (CPU16) board. Everything below is
derived from the **MC68HC16Z1 / CPU16 datasheet & user's manual**, the public
**XMODEM** protocol, and the facts in `HARDWARE_SPEC.md`. No vendor firmware,
decompilation, or RE notes were consulted.

## Build

Build with **`make`** (see the Makefile):

```
make                  # default: banner.txt, 19200 baud, sram_dump.bin
make BAUD=9600        # 9600 (stock default); BAUD=57600 for the fast build
make BANNER=moo.txt   # embed a different banner/data file (see additions)
make OUT=recover.bin  # name the output image
make clean all        # force a full rebuild
```

It runs: `asl -cpu 68HC16 [-D SCBRVAL=n] -L sram_dump.s` → `sram_dump.p`,
then `p2bin sram_dump.p sram_dump.bin -l 0xff -r 0x0-0x7ffff`. The `-r` spans
the full 512 KB boot window and `-l 0xff` fills every unused cell with **`$FF`**
(the erased-EPROM/flash state), so a programmer skips the blank cells and burns
only the ~600 used bytes. No `truncate`; the image is exactly **524288 bytes**,
reset vector at offset 0, code at `$0200`, banner right after the code, `$FF`
everywhere else. Result: **0 errors, 0 warnings.**

## Versioning

Every image says which source built it. It boots with

```
sram_dump 1.1.0+g1a2b3c4 (main, 2026-10-12)
```

and the monitor's `I` command returns the same text without the prefix.
`version.sh` derives it from git: the version from the nearest `vX.Y.Z` tag,
`+gHASH` for the commit, then the branch and the **commit** date. It uses the
commit date rather than the build time, so building a clean commit always gives
the same bytes, and a chip readback can be compared against a rebuild of the
commit it names.

| checkout | version |
|---|---|
| at tag `vX.Y.Z`, clean | `X.Y.Z+gHASH` |
| N commits past it | `X.Y.(Z+1)-dev.N+gHASH` (pre-release of the next patch) |
| uncommitted changes | `….dirty` appended |
| outside git | `0.0.0+unknown`, or `make VERSION=… BRANCH=… CDATE=…` |

Version numbers follow [semver](https://semver.org). What they promise to keep
stable is everything outside the image that depends on it:

- the monitor protocol (commands, reply formats, the `K` ack, `V` → `COW1`);
- the boot and dump behaviour (mode-select byte, XMODEM format, dump range);
- the slot contract: `SLOTSZ`, the `$C057` header, revocation by `$00`, and the
  slot index handed over in E. A stub burned into a chip has to keep booting
  every later slot image;
- the make variables (`BAUD BANNER OUT SLOT BASE SLOTSZ DEV`).

Breaking any of them is a **major** release, adding to them (a monitor command,
a build variant) is **minor**, and a fix that changes none of them is a
**patch**. `V`'s `COW1` is the monitor *protocol* revision and changes only
with a major release; `I` is the way to identify the build. See `CHANGELOG.md`.

## Append-only boot ROM (slots) — reburn without erasing

Programming only clears bits (1→0), so a blank (`$FF`) region of an
already-burned chip can be filled in later. `boot_stub.s` exploits that:

- The 512 KB is split into `SLOTSZ` slots (default **16 KB → 31 usable**).
  **Slot 0** is the stub: reset vector plus a scanner, burned **once**.
  `SLOTSZ` is fixed for the life of the chip from then on.
- Each slot `n ≥ 1` holds a complete dumper assembled to run at `n·SLOTSZ`,
  starting with the header word `$C057`; the entry point is slot+2 (CPU16
  code must be word-aligned).
- The stub scans from the top slot down and jumps to the first whose header
  byte is neither `$FF` (blank) nor `$00` (**revoked**) — i.e. the last one
  burned. To back out a bad image, program its first byte to `$00` and the
  stub falls back to the previous slot. No live slot → it spins silently.
- The stub writes no configuration registers (SYPCR is write-once and belongs
  to the image); its scan takes microseconds, inside both watchdog windows.
- Handoff: `Y` = the chosen slot index. The image prints `boot: slot NN`
  before the banner, adds `SLOT MISMATCH, built for MM` if that differs from
  the slot it was assembled for, and answers monitor command `S` with the
  index (`$FF` for a standalone build).

```
make patch SLOT=1                        # first burn: stub + slot 1 -> rom_patch.bin
minipro -p DEV -r rom_now.bin            # later: read the chip back
make patch SLOT=2 BASE=rom_now.bin       # overlay the next slot onto the readback
minipro -p DEV -w rom_patch.bin          # flash parts: ADD -e, or minipro erases it
```

`rom_patch.py` overlays the stub and the slot onto `BASE` and **refuses** if
any byte would need a 0→1 change (occupied slot, different stub/`SLOTSZ`, wrong
base). Because the output equals the chip everywhere outside the new slot, the
normal full-chip write + verify passes. It reports which slot the stub will
boot.

**Gotcha found in emulation:** CPU16 index registers are **20 bits** (XK:IX).
`AIX` carries/borrows into XK, so the stub steps slots with a single
`AIX #-SLOTSZ` and no bank arithmetic; an explicit bank decrement on top of
that skipped a bank (the slot-index self-check is what caught it).

Verified in MAME: slots 1–31 across every bank boundary report the right
index; append chain 1→2→9, revocation fallback, refusal of an occupied slot,
stub-only silence, monitor `S`/`V`, and a full 256 KB dump from slot 2
(0 mismatches). Not yet verified on silicon: that CSBOOT's reset decode spans
all 512 KB (if it does not, high slots read as garbage).

## Reset / vector layout

The CPU16 fetches a 4-word reset vector from `$000000`:

| Addr    | Word            | Value chosen | Why |
|---------|-----------------|--------------|-----|
| $000000 | initial ZK:SK:PK| `$0000`      | code runs in bank 0 → PK=0; SK/ZK reset to 0 (reprogrammed in code) |
| $000002 | initial PC      | `$0200`      | entry point `START` |
| $000004 | initial SP      | `$0000`      | unused — no stack ops, interrupts masked |
| $000006 | initial IZ      | `$0000`      | unused |

Code is placed at `$0200`, clear of the CPU16 exception-vector region
(`$0000–$01FF`). Interrupts are masked (`ORP #$00E0` sets CCR IP=7, which is
also the reset default) and no exceptions are expected, so the rest of the
vector table is left as fill.

The address-extension registers are all set explicitly at startup rather than
relying on reset defaults:

- `EK = $F` (`LDAB #$0F; TBEK`) — **extended** addressing (16-bit operand)
  then reaches the module block: operand `$FA21` → `$FFA21`, etc.
- `ZK = $F`, `Z = $FC00` (`TBZK`, `LDZ`) — **Z-indexed** addressing reaches the
  QSM: `off,Z` with off = register offset from `$FFC00`.
- `XK = $F8`, `X = $0000` (`TBXK`, `LDX`) — **X-indexed** reads hit the SRAM.

## SIM init — clock, and TWO watchdogs

The transfer moves ~272 KB on the wire (2048 × 133 bytes). Even at 57600 baud
that is ~47 s (at 9600 it is ~4.7 min), far longer than any watchdog timeout.
There are **two** watchdogs on this board; both must be handled.

**On-chip COP.** `SYPCR` (`$FFA21`) bit7 `SWE` = 0 disables the software
watchdog; writing `$00` also clears the bus/halt monitors. Done once, as the
**first** SIM write (`CLRA; STAA $FA21`): the COP is enabled out of reset with a
short timeout, so nothing slow may run ahead of it.

**External DS1232 (U24).** `SYPCR` does **not** touch this hardware part — it
pulls `/RESET` unless its `/ST` strobe is toggled within ~0.6–1.2 s (TD=VCC).
Per the board schematic its `/ST` is on **PQS1** (QSM `PORTQS` bit 1; net "ST"
→ U16 pin 11 = MOSI = PQS1). We make PQS1 a `DDRQS` output and pulse it on
**every transmitted byte** (in `SENDB`) and **every receive-wait pass** (in
`RECVB`) via the `STROBE` macro — which uses `B` only, preserving the checksum
in `A`. (The block header reloads the block number from `E` after a `SENDB`
because `STROBE` clobbers `B`.) Without this, the real board reset-loops about
once a second and no dump completes — a failure invisible until the emulator
also modelled the DS1232.

**Clock (`SYNCR`, `$FFA04`).** Out of reset the synthesizer gives
`f_ref·4·(Y+1)·2^(2W+X)` = `32768·4·64·1` = **8.39 MHz**, half the board's
16.78 MHz, while the baud divisor is computed for 16.78 MHz. So program
`SYNCR` = `$7F00` (W=0, X=1, Y=$3F): setting X doubles the clock to 16.777216
MHz with no VCO relock. Value derived from the datasheet synthesizer equation
and the 16.78 MHz target in `HARDWARE_SPEC.md`. (MAME's CPU16 runs at a fixed
clock and ignores `SYNCR`, so this one is datasheet-proven, not emulator-proven;
the baud is socket-irrelevant in the test bench anyway.)

## SCI (QSM) init and baud

QSM SCI registers (offsets from `Z = $FFC00`):

- `SCCR0` `$FFC08` — baud: `SCBR` in the low 13 bits.
- `SCCR1` `$FFC0A` — `TE` (bit3) | `RE` (bit2) = `$000C`; `M=0` → 8 data bits,
  `PE=0` → no parity, 1 stop bit ⇒ **8N1**.
- `SCSR`  `$FFC0C` — status.
- `SCDR`  `$FFC0E` — data (byte in the low half).

Baud equation (datasheet): `baud = f_sys / (32 × SCBR)`, `SCBR` integer.
At f_sys = 16.777216 MHz:

| Target  | SCBR  | Actual  | Error  | Verdict |
|---------|-------|---------|--------|---------|
| 9600    | **55**| 9532    | −0.7%  | **default** — matches the stock board's 9600 8N1 |
| 57600   | 9     | 58254   | +1.1%  | optional 6× speed-up once proven on hardware |
| 115200  | 5     | 104858  | −8.9%  | rejected — outside UART tolerance |
| 115200  | 4     | 131072  | +13.8% | rejected |

`SCBRVAL` is a **build knob**: the Makefile computes it (rounded) from
`make BAUD=<rate>`, or pass `-D SCBRVAL=<n>` to asl; the source `IFNDEF`
fallback is **19200 (`SCBRVAL = 27`)** when built with no override.

- **19200 (SCBR 27, +1.1%)** — the default. Per the RLC manual (command `024`,
  "Set Up RS-232 Serial Baud Rate"), the stock firmware supports **300–19200**,
  so 19200 is the vendor-documented max: known-good on this exact hardware and
  ~2× faster than 9600 (~2.4 min for 256 KB).
- **9600 (SCBR 55, −0.7%)** — the stock default; safest match for the very first
  on-hardware dump (matches the board's proven clock exactly).
- **57600 (SCBR 9, +1.1%)** — beyond anything RLC ships, but within HC16 spec and
  emulator-proven; ~47 s.

**115200 is not cleanly reachable at this clock** (ideal divisor 4.55; nearest
gives −8.9% / +13.8%). The receiver must be set to the matching rate.

### SCI status bits (biggest hardware assumption)

Per the QSM SCI SCSR map: `TDRE = bit 8`, `RDRF = bit 6`. The code tests them
as bytes:

- TDRE = bit 8 = bit0 of the SCSR **high** byte (`$FFC0C`), mask `$01`.
- RDRF = bit 6 of the SCSR **low** byte (`$FFC0D`), mask `$40`.

If the target shows "no serial output" or "start byte unanswered", these
bit positions/addresses are the first thing to re-check on the datasheet.

`SENDB` writes the data with a 16-bit `STD SCDR,Z`: B → low byte (the data),
A → high byte (which holds T8, ignored in 8-bit mode). This lets the send
routine preserve A, so it can be called from inside the data loop where **A
holds the running checksum**. `RECVB` reads `SCDR` (clears RDRF) into B.

## Address banking to reach the SRAM at $F80000–$FBFFFF

This is the point flagged in the spec as "verify against the target." The SRAM
is 256 KB = four 64 KB banks. The code walks it as `XK:X`:

- `XK` steps through the bank bytes **$F8, $F9, $FA, $FB**; `X` covers `$0000..$FFFF`.
- Each 128-byte XMODEM block lies wholly within one bank (65536 / 128 = 512),
  so bank changes never fall mid-block.

The `XK`/`X` walk is **robust to the exact width of the extension register**:

- If the emulator/board treats `XK` as the full high byte (24-bit
  `{XK[7:0], X[15:0]}`), the reads hit `$F80000..$FBFFFF` directly — the
  spec's map.
- If `XK` is the classic 4-bit CPU16 extension, `TBXK` keeps only the low
  nibble, so the banks become `$8,$9,$A,$B` → `$80000..$BFFFF`. That is still
  four contiguous 64 KB banks and does **not** collide with the module block
  (bank `$F`, `$FFxxx`).

Either way the low nibbles `8,9,A,B` select the four SRAM banks and avoid the
module space. Completion is detected by the bank low nibble reaching `$C`
(after `$B`), which is correct for both cases — so termination does not depend
on knowing the extension width. **Assumption to verify:** that CS0's SRAM
actually decodes at these banks on the target; if the received image is offset
or wrong, adjust `SRAMBNK` and re-check the `TBXK`/`XK` semantics.

Reads use `LDAB 0,X` only — the SRAM is **never written**.

## XMODEM logic (checksum mode)

- **Start:** wait for the receiver's `NAK $15`; ignore anything else (a
  CRC-mode `C $43` is ignored, and a standard receiver such as `rx` falls back
  to sending `NAK` after its CRC attempts time out, so checksum mode is entered
  automatically).
- **Per block:** `SOH $01`, block# (starts at 1, low byte of a running counter
  so it wraps 255→0 naturally), block# complement (`COMB`), 128 data bytes,
  then the 1-byte arithmetic checksum (`ABA` accumulates in A).
- **Response:** `ACK $06` → advance; `NAK $15` → rewind the read pointer by 128
  (`AIX #-128`; block# unchanged) and resend the same block; anything else is
  ignored and we keep waiting.
- **End:** after the 2048th block, send `EOT $04` and wait for `ACK` (resend
  `EOT` otherwise), then halt in a tight loop.

256 KB / 128 = 2048 blocks; the range divides evenly, so no `$1A` padding is
ever needed.

## Register usage during the data loop

Deliberately stack-free / RAM-free (the only writable RAM on the board is the
NVSRAM we must not touch, and configuring on-chip SRAM would add avoidable
assumptions):

| Reg | Role |
|-----|------|
| X / XK | SRAM read pointer / bank |
| Y   | 128-byte down-counter |
| A   | running checksum (preserved across `SENDB`) |
| B   | data byte / scratch |
| E   | bank tracker (high byte) + XMODEM block# (low byte, on the wire) |
| Z / ZK | QSM base pointer (constant) |

The poll loops use `BRCLR …,*` (branch-if-bit-clear to the instruction's own
address), so the wait needs no scratch register — important because every
GP register is live during the data loop.

## Assumptions to confirm on the emulator / hardware

1. **SCSR bit positions** — TDRE=bit8, RDRF=bit6 (checked as described above).
2. **f_sys = 16.777216 MHz** and `SYNCR` default — governs the baud divisor
   (`SCBRVAL`). Retune `SCBRVAL` if the actual clock differs.
3. **SRAM banking** — CS0 SRAM decodes at bank bytes `$F8..$FB` (or nibbles
   `8..B`) via `XK:X`. Adjust `SRAMBNK` if the image is offset/short.
4. **SCDR access** — writing the 16-bit `SCDR` (data in low byte) triggers
   transmit; reading it clears RDRF. If the QSM requires strict byte access,
   switch the `STD`/`LDD` to byte ops.
5. **COP window** — `SYPCR=$00` written early enough to disable the watchdog.

Symptoms to report back for iteration: "no serial output" (→ 1,2,4),
"XMODEM start byte unanswered" (→ 1, RX enable, baud), "received data differs
at offset N" (→ 3, baud error, or bit-order).

## Main-session additions (on top of the clean-room core)

The init/banking/XMODEM core above is the clean-room author's. The following
cosmetic/build additions were made in the main session (marked `[main-session
addition]` in the source); they touch no memory and don't alter the data path:

- **Embedded banner (arbitrary file).** `banner: BINCLUDE "banner.bin"` places a
  build-staged file after the code; the Makefile/`build.sh` copies `BANNER`
  (default `banner.txt`) → `banner.bin`. At startup, before the XMODEM
  handshake, the firmware prints it **byte-transparently**: drop `CR`, expand
  `LF`→`CRLF`, emit every other byte verbatim — so plain text OR ANSI/VT100
  escape sequences display correctly. Read from bank 0 via `Y` (`YK=0`); `X` is
  a counter only. Edit `banner.txt` and rebuild — no source edit.
- **Completion line.** After the EOT is ACKed it prints `Done. 262144 bytes
  sent.` (fixed CRLF string `donemsg`), then halts.
- **`$FF` fill** (see Build) so a burn skips blank cells.
- **Baud build knob** (see SCI section); default 19200.

### Why register-only / no-RAM matters
The dumper never writes memory (SRAM read-only; only SIM/QSM control regs during
bring-up) and holds all state in registers. The bank is tracked in **E's high
byte and only ever WRITTEN to `XK`** — never read back, because a
read-modify-write of the extension register does not net +1 on this target
(that was a real bug: the first build stepped `XK` by 2, dumping banks F8 and FA
only; fixed by the accumulator-tracked, write-only `XK`). On a NAK the code
**rewinds `X` by 128 and re-reads the block from SRAM** instead of buffering it,
so no block buffer / no RAM is needed. This is the property that makes it a
provably inert recovery ROM: with no writes to memory, it cannot corrupt the
config. It is also why an on-device hash (MD5 / CRC-32 / sum-32) is impractical
— no scratch RAM and every register live — so integrity is done **host-side**
(`sha256sum` the dump, or dump twice and `cmp`; the read is deterministic).

### Verified in the emulator (headless MAME, byte-oriented bitbanger socket)
- Full 256 KB dump = **byte-exact vs the real config (0 mismatches)** and vs a
  dense position-unique synthetic pattern; confirmed at 9600 and 19200 and after
  the FF-fill / baud-knob changes.
- **With the DS1232 watchdog now modelled in MAME** (it was not when the core
  was first verified): the strobe survives the handshake wait (0 resets, ~1.4M
  `PORTQS` strobes/s) and completes the full 2048-block dump with 0 mismatches.
  The earlier "verified" runs predated the emulated watchdog and would have
  reset-looped on real hardware — the reason the watchdog + `SYNCR` fixes exist.
- Banner prints correctly: cow + 12 CRLF pairs (12 LF / 12 CR, no lone LFs).
- End-to-end run: banner → 2048/2048 blocks → `Done.` → 0 mismatches.
- Baud is irrelevant over MAME's socket (byte-oriented); `SCBRVAL` matters only
  on real silicon, where the first dump should use 9600 to match the stock clock.
- Test harnesses (in `~/rlc-reversing`): `rlc_dump_xmodem.py` (automated
  pass/fail diff), and a verbose end-to-end runner that shows the banner +
  progress + `Done.` line.
