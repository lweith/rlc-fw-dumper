# SRAM-dump firmware — hardware specification (clean-room input)

You are writing a small **boot firmware** for a Motorola **MC68HC16Z1** board. Its only job:
after reset, bring up the serial port and transmit the board's 256 KB of external
battery-backed SRAM out the serial port using the **XMODEM** protocol, then stop. It must only **read** the
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
- **Data to dump:** **256 KB** of external battery-backed SRAM — two **NEC μPD431000A-70LL**
  devices (128K×8, 1 Mbit, 70 ns, low-standby "LL" data-retention grade). Both SRAMs — like
  the boot ROM — are wired to **D15–D8 only: CS0 is an 8-bit port**, and the board's own
  decode picks the device; D7–D0 is unconnected for them (a 16-bit CS0 reads floating junk
  on odd addresses — confirmed on silicon; MAME's 16-bit share hides it). These are
  **ordinary SRAM**, not internal-battery nvSRAM; retention comes from an external cell (BT1)
  through a backup-power switch, and the board's Dallas part (DS1286) is **RTC-only**. On
  chip-select **CS0**, occupying **`$F80000–$FBFFFF`** in the CPU's 24-bit
  address space. (CPU16 forms 24-bit addresses as {K-register[3:0], 20-bit operand}; the
  bank nibble comes from EK/XK/YK/ZK depending on the addressing mode. Determine and verify
  the exact register/offset to read this range against the target.)
- **On-chip modules** (standard HC16Z1 map, module space at `$FFxxx`, bank `$F`):
  - **SIM** base `$FFA00`. Relevant: `SYNCR` `$FFA04` (clock synthesizer), `SYPCR` `$FFA21`
    (COP watchdog / bus monitor — disable or service the COP so it doesn't reset you),
    chip-select pin assignment/base/option registers `$FFA44`+ — **required on real
    hardware**: out of reset only CSBOOT is live, and an access through an unprogrammed CS0
    never gets DSACK (with the bus monitor off it hangs until the DS1232 resets the board).
    - **Clock:** out of reset the synthesizer runs at `f_ref·4·(Y+1)·2^(2W+X)` with
      `SYNCR = $3F00` (Y=$3F, W=X=0) ⇒ `32768·4·64 = 8.39 MHz` — **half** the board's
      16.78 MHz. The SCI baud divisor is computed for 16.78 MHz, so **program `SYNCR`**
      (set X ⇒ `$7F00`, no VCO relock needed) or every baud comes out at half rate.
- **External watchdog (board fact, from the rev E/C schematic):** besides the on-chip COP,
  the board has a **DS1232 (U24)** hardware watchdog that pulls the CPU `/RESET` unless its
  **`/ST` strobe is toggled** within the timeout (TD strapped to VCC ⇒ ~0.6–1.2 s). `/ST` is
  wired to the CPU's **PQS1** pin (QSM `PORTQS` bit 1; schematic net "ST" → U16 pin 11 =
  MOSI = PQS1). Disabling the COP (SYPCR) does **not** affect it. The multi-minute dump far
  exceeds the timeout, so the firmware must make PQS1 a `PORTQS`/`DDRQS` output and pulse it
  continuously — on every transmitted byte and inside every receive-wait spin.
  - **QSM** base `$FFC00`, containing the **SCI** (async UART):
    `SCCR0` `$FFC08` (baud rate register), `SCCR1` `$FFC0A` (enables: TE/RE, mode),
    `SCSR` `$FFC0C` (status: TDRE/RDRF/etc.), `SCDR` `$FFC0E` (data).
    SCI baud = f_sys / (32 × SCBR); at 16.78 MHz, SCBR 55 → ~9600, SCBR 27 → ~19200.
    The QSM pin-assignment/data-direction registers (`QPAR`/`QDDR`, near `$FFC15`) may need
    the SCI TXD/RXD pins assigned to the SCI — check the datasheet.
- **Serial line settings:** **8 data bits, no parity, 1 stop bit (8N1).** Baud is a build
  knob — default **19200**. Per the RLC manual (command 024) the stock firmware supports
  **300–19200**, so 19200 is the vendor-documented max; use **9600** for the first
  on-hardware dump to match the stock clock exactly, then 19200/57600 for speed.

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

`make` (see the Makefile; knobs: `BAUD=` default 19200, `BANNER=`, `OUT=`), which runs:

- Assemble with **asl**: `asl -cpu 68HC16 [-D SCBRVAL=n] -L sram_dump.s` → `sram_dump.p`.
- Flatten to a full **512 KB** image with every unused cell `$FF`-filled (the erased-EPROM
  state, so a burn writes only the used cells):
  `p2bin sram_dump.p sram_dump.bin -l 0xff -r 0x0-0x7ffff`.

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
- `Makefile` — build with knobs (`BAUD`/`BANNER`/`OUT`); emits the `$FF`-filled 512 KB image.
- `banner.txt` — boot banner embedded into the image (edit + rebuild, no source change).
- `sram_dump.bin` — the built 512 KB image (git-ignored; regenerate with `make`).
- `NOTES.md` — how you derived the init/banking from the datasheet, and test results.
