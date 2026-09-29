# SRAM-dump firmware — hardware specification (clean-room input)

You are writing a small **boot firmware** for a Motorola **MC68HC16Z1** board. Its only job:
after reset, bring up the serial port and transmit the board's 256 KB of external NVSRAM
out the serial port using the **XMODEM** protocol, then stop. It must only **read** the
SRAM — never write to it or to any other board resource beyond what init requires.

## Clean-room rules (important)

Implement **solely** from:
- the **MC68HC16Z1 / CPU16** datasheet & user's manual (instruction set, reset behavior,
  SIM and QSM register maps, chip-select and SCI programming),
- the public **XMODEM** protocol,
- the hardware facts in this document,
- and **testing against the emulator as a black box** (run it, exchange serial bytes).

Do **NOT** read, open, reference, or derive anything from: any RLC/Link Communications
firmware image, its decompilation, disassembly, or any reverse-engineering notes/source in
`~/rlc-reversing` or elsewhere (e.g. `fw_decomp.c`, `x86_decomp.c`, `rlcconfig.py`,
`rlcclub.cpp`). Do not read the emulator's driver source. Base every design decision on the
datasheet + these facts + your own testing. The point is a firmware whose design owes
nothing to the vendor's firmware.

## Hardware facts (from the datasheet + the board's chip complement/memory map)

- **CPU:** MC68HC16Z1 (CPU16 core), big-endian, system clock ≈ **16.78 MHz** (16.777216).
- **Boot memory:** the firmware runs from boot ROM/flash at **`$000000`** (chip-select
  CSBOOT), image size **512 KB (`$00000–$7FFFF`)**. The CPU16 fetches its reset vector from
  `$000000` (see the datasheet for the reset-vector word layout: initial K/CCR, PC, SP, IZ).
- **Data to dump:** **256 KB** of external byte-wide NVSRAM (two DS1245Y devices forming a
  16-bit bus) on chip-select **CS0**, occupying **`$F80000–$FBFFFF`** in the CPU's 24-bit
  address space. (CPU16 forms 24-bit addresses as {K-register[3:0], 20-bit operand}; the
  bank nibble comes from EK/XK/YK/ZK depending on the addressing mode. Determine and verify
  the exact register/offset to read this range against the target.)
- **On-chip modules** (standard HC16Z1 map, module space at `$FFxxx`, bank `$F`):
  - **SIM** base `$FFA00`. Relevant: `SYNCR` `$FFA04` (clock synthesizer), `SYPCR` `$FFA21`
    (COP watchdog / bus monitor — disable or service the COP so it doesn't reset you),
    chip-select pin assignment/base/option registers `$FFA44`+ (only needed if CS0 must be
    programmed to see the SRAM on real hardware).
  - **QSM** base `$FFC00`, containing the **SCI** (async UART):
    `SCCR0` `$FFC08` (baud rate register), `SCCR1` `$FFC0A` (enables: TE/RE, mode),
    `SCSR` `$FFC0C` (status: TDRE/RDRF/etc.), `SCDR` `$FFC0E` (data).
    SCI baud = f_sys / (32 × SCBR); for 9600 baud at 16.78 MHz, SCBR ≈ 55 (`$37`).
    The QSM pin-assignment/data-direction registers (`QPAR`/`QDDR`, near `$FFC15`) may need
    the SCI TXD/RXD pins assigned to the SCI — check the datasheet.
- **Serial line settings:** **9600 baud, 8 data bits, no parity, 1 stop bit.**

## Protocol

Standard **XMODEM** (checksum variant is fine; XMODEM-CRC optional):
- Wait for the receiver's start byte: NAK `$15` (checksum mode) or `C` `$43` (CRC mode).
- For each 128-byte block: send `SOH $01`, block number (starts at 1, wraps 255→0),
  block-number complement, 128 data bytes, then the 1-byte arithmetic checksum
  (or 2-byte CRC-16 if you chose CRC mode).
- Wait for `ACK $06` (next block) or `NAK $15` (resend the block).
- After the last block send `EOT $04` and wait for `ACK`.
- 256 KB = 2048 blocks of 128 bytes. Pad the final block with `$1A` if ever needed
  (here it divides evenly, so no padding).

## Build

- Assemble with **asl**: `asl -cpu 68HC16 -L sram_dump.s` → `sram_dump.p`.
- Convert to a flat binary: `p2bin sram_dump.p sram_dump.bin`.
- **Pad to exactly 512 KB** (`$80000` bytes) — the boot image size. (`truncate -s 524288`
  or emit padding in the source.)

## Test harness (emulator, black box)

The image is booted by an MC68HC16Z1 emulator that presents the same memory map. To test:
1. Put your padded 512 KB image where the emulator loads its boot ROM (the person running
   this will tell you the exact path / command; treat the emulator only as hardware).
2. Boot it **headless** (no window, no host audio, don't grab the desktop):
   run with `-video none -sound none` and with `DISPLAY`/`WAYLAND_DISPLAY` unset and
   `SDL_VIDEODRIVER=offscreen` in the environment.
3. The emulated SCI is exposed as a TCP socket / PTY. Attach an **XMODEM receiver**
   (e.g. `rx`, or a short Python XMODEM script) to it and capture the transfer.
4. **Success = the received 256 KB matches a known-good reference image of that SRAM,
   byte-for-byte.** Iterate (init order, baud divisor, banking, XMODEM timing) until it does.

## Deliverables (in this directory)

- `sram_dump.s` — the commented assembly source.
- `build.sh` — assemble + convert + pad.
- `sram_dump.bin` — the built 512 KB image.
- `NOTES.md` — how you derived the init/banking from the datasheet, and test results.
