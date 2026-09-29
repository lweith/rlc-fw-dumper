# sram_dump — design notes and derivation

Read-only NVSRAM dumper for an MC68HC16Z1 (CPU16) board. Everything below is
derived from the **MC68HC16Z1 / CPU16 datasheet & user's manual**, the public
**XMODEM** protocol, and the facts in `HARDWARE_SPEC.md`. No vendor firmware,
decompilation, or RE notes were consulted.

## Build

`./build.sh` (simple; default 19200 baud, banner from `banner.txt`), or the
**Makefile** for knobs:

```
make                  # default: banner.txt, 19200 baud, sram_dump.bin
make BAUD=9600        # 9600 (stock default); BAUD=57600 for the fast build
make BANNER=moo.txt   # embed a different banner/data file (see additions)
make OUT=recover.bin  # name the output image
make clean all        # force a full rebuild
```

Both run: `asl -cpu 68HC16 [-D SCBRVAL=n] -L sram_dump.s` → `sram_dump.p`,
then `p2bin sram_dump.p sram_dump.bin -l 0xff -r 0x0-0x7ffff`. The `-r` spans
the full 512 KB boot window and `-l 0xff` fills every unused cell with **`$FF`**
(the erased-EPROM/flash state), so a programmer skips the blank cells and burns
only the ~600 used bytes. No `truncate`; the image is exactly **524288 bytes**,
reset vector at offset 0, code at `$0200`, banner at `$1000`, `$FF` everywhere
else. Result: **0 errors, 0 warnings.**

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

## SIM init — disabling the COP

The transfer moves ~272 KB on the wire (2048 × 133 bytes). Even at 57600 baud
that is ~47 s (at 9600 it is ~4.7 min), far longer than any COP timeout, so the
software watchdog must be off. `SYPCR` (`$FFA21`) bit7 `SWE` = 0 disables the
software watchdog; writing `$00` also clears the bus/halt monitors. Done once,
early (`CLRA; STAA $FA21`), within the write-once window after reset.

`SYNCR` (clock synthesizer, `$FFA04`) is **left at its reset/board default**.
`HARDWARE_SPEC.md` states f_sys ≈ 16.777216 MHz as a hardware fact, so the
baud divisor is computed for that clock. If the emulator/board comes up at a
different f_sys, only `SCBRVAL` needs adjusting (see below). **Assumption to
verify.**

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
- Banner prints correctly: cow + 12 CRLF pairs (12 LF / 12 CR, no lone LFs).
- End-to-end run: banner → 2048/2048 blocks → `Done.` → 0 mismatches.
- Baud is irrelevant over MAME's socket (byte-oriented); `SCBRVAL` matters only
  on real silicon, where the first dump should use 9600 to match the stock clock.
- Test harnesses (in `~/rlc-reversing`): `rlc_dump_xmodem.py` (automated
  pass/fail diff), and a verbose end-to-end runner that shows the banner +
  progress + `Done.` line.
