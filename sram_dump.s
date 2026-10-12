; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Loren Weith
;
;***********************************************************************
; sram_dump.s  -  Read-only NVSRAM dumper for an MC68HC16Z1 (CPU16) board
;
; Purpose (per HARDWARE_SPEC.md):
;   After reset, bring up the on-chip SCI (9600 8N1) and stream the board's
;   256 KB external NVSRAM (CS0, $F80000-$FBFFFF) out the serial port using
;   the XMODEM (checksum) protocol, then stop.  READ-ONLY: the SRAM is never
;   written; the only writes are to SIM/QSM control registers required for
;   bring-up.
;
; Clean-room: implemented solely from the MC68HC16Z1 / CPU16 datasheet and
;   user's manual (reset vector layout, SIM & QSM register maps, SCI baud
;   equation, address-extension registers), the public XMODEM protocol, and
;   the hardware facts in HARDWARE_SPEC.md.  No vendor firmware consulted.
;
; Assemble:  asl -cpu 68HC16 -L sram_dump.s   ->  sram_dump.p
; Flatten :  p2bin sram_dump.p sram_dump.bin
; Pad     :  truncate -s 524288 sram_dump.bin   (512 KB boot image)
;***********************************************************************

        CPU     68HC16

;-----------------------------------------------------------------------
; Register / constant equates
;-----------------------------------------------------------------------
; On-chip module space lives in bank $F.  With EK (extended-addressing
; bank) = $F, a 16-bit extended operand $Fxxx addresses $FFxxx.  With
; ZK = $F and Z = QSM base, indexed operand off Z reaches the same space.
;
; SIM (base $FFA00):
SYNCR   EQU     $FA04           ; Clock Synthesizer CR (word)  -> set f_sys
SYPCR   EQU     $FA21           ; System Protection CR (byte) -> disable COP
SWSR    EQU     $FA27           ; Software watchdog service reg (COP keep-alive)
CSPAR0  EQU     $FA44           ; Chip-select pin assignment 0 (word)
CSBAR0  EQU     $FA4C           ; CS0 base address register (word)
CSOR0   EQU     $FA4E           ; CS0 option register (word)
;
; CS0 frames the two SRAMs (U14/U15) at $F80000, 256 KB (board map).  Both
; SRAMs -- like the boot ROM -- sit on D15-D8 only, so CS0 is an 8-BIT port;
; as a 16-bit port, odd addresses read the unconnected D7-D0 lane (floating:
; junk decaying to $00; found on silicon, invisible in MAME).  Out of reset
; only CSBOOT is live, so without this every SRAM access waits forever for a
; DSACK that never comes (bus monitor off: the DS1232 resets the board).
CSP0_MSK EQU    $000C           ; CSPAR0 bits 3:2 = CS0 field
CSP0_8  EQU     $0008           ; CS0 field = %10: 8-bit chip select
CSB0VAL EQU     $F805           ; CSBAR0: base $F80000 (A23-A11 in 15:3), BLKSZ %101 = 256K
; CSOR0: MODE=0 async | BYTE=%11 both | R/W=%11 both | STRB=0 AS |
;        DSACK=%0010 (2 wait states; 70 ns parts, 60 ns clock) | SPACE=%11 S/U |
;        IPL=0 | AVEC=0
CSO0VAL EQU     $78B0
;
; QSM (base $FFC00) - Z points here at run time (Z = $FC00, ZK = $F):
QSMBASE EQU     $FC00
SCCR0   EQU     $08             ; offset of SCI Control Reg 0 (baud)   $FFC08
SCCR1   EQU     $0A             ; offset of SCI Control Reg 1 (enables)$FFC0A
SCSR_HI EQU     $0C             ; SCI Status high byte ($FFC0C): TDRE = bit0
SCSR_LO EQU     $0D             ; SCI Status low  byte ($FFC0D): RDRF = bit6
SCDR    EQU     $0E             ; SCI Data Register (16-bit) $FFC0E; data = low
PORTQS  EQU     $15             ; QSM port QS data             $FFC15
DDRQS   EQU     $17             ; QSM data-direction register  $FFC17
;
; SCI status bit masks (within the byte tested):
TDRE    EQU     $01             ; SCSR bit 8  -> bit0 of high byte
RDRF    EQU     $40             ; SCSR bit 6  -> bit6 of low  byte
;
; SCI setup values:
;   Baud = f_sys / (32 * SCBR), SCBR integer.  At f_sys = 16.777216 MHz:
;     SCBR=55 -> 9532 baud   (-0.7% vs 9600)   <- stock board default
;     SCBR=27 -> 19418 baud  (+1.1% vs 19200)  <- default here; RLC's documented max
;     SCBR= 9 -> 58254 baud  (+1.1% vs 57600)  <- beyond stock; HC16-fine (emu-proven)
;   115200 is NOT cleanly reachable (divisor 4.55; nearest gives -8.9% / +13.8%).
; SCBRVAL is a BUILD KNOB: `make BAUD=<rate>` computes it, or pass -D SCBRVAL=<n>.
; The default below applies only when built with no override.
        IFNDEF  SCBRVAL
SCBRVAL EQU     27              ; default -> ~19200 baud (RLC's documented max)
        ENDIF
TE_RE   EQU     $000C           ; SCCR1: TE(bit3)|RE(bit2); M=0 (8 bit),PE=0 -> 8N1
;
; Extension-bank values:
EKF     EQU     $0F             ; EK/ZK bank $F for module registers
SRAMBNK EQU     $F8             ; first SRAM bank byte -> XK:X = $F8:0000
BANKEND EQU     $0C             ; nibble after last SRAM bank ($B) -> done
;
; E accumulator packs bank tracker (high byte) and XMODEM block number
; (low byte).  The bank is tracked in an accumulator and only ever WRITTEN
; to XK; XK is never read back.  (IX is 20 bits: the data loop's AIX #1 at
; $FFFF already carries into XK, so a read-modify-write +1 of XK there would
; overshoot by a bank.  Writing the tracked value is right either way.)
EINIT   EQU     (SRAMBNK*256)+1 ; E high = first bank, E low = block# 1
;
; XMODEM control bytes:
SOH     EQU     $01
EOT     EQU     $04
ACK     EQU     $06
NAK     EQU     $15
;
CR      EQU     $0D             ; carriage return (banner line-end handling)
LF      EQU     $0A             ; line feed
;
BLKSZ   EQU     128             ; XMODEM data bytes per block

;-----------------------------------------------------------------------
; Bovine bootloader (`make bovine FW=host.bin`): a datasheet-only front-end
; that RIDES in a host firmware's free space.  bovine_patch.py points the
; reset vector at this image's START and copies the host's ORIGINAL four
; reset-vector words into VEC_SAVE below.  On boot the cow brings up the SCI
; (but NOT SYPCR -- write-once, left untouched for the host) and offers a
; short escape window:
;   any byte received within the window -> finish init, enter the dumper/monitor
;   window elapses                       -> restore a reset CPU state, JMP to the
;                                           host's saved vector (chain-load)
; The on-chip COP is enabled out of reset and SYPCR is off-limits here, so the
; wait keeps it alive by servicing SWSR ($55,$AA) every pass, alongside the
; DS1232 PQS1 strobe.  Clean-room: CPU16 datasheet (reset-vector format, COP
; service protocol, SCI) only; nothing from the host firmware.
COP_A   EQU     $55             ; COP service sequence byte 1 (SWSR)
COP_B   EQU     $AA             ; COP service sequence byte 2 (SWSR)
; Escape window length = BOVWAIT * BOVINNER iterations of the wait loop, which
; STROBEs (DS1232 + COP) once per iteration.  Defaults aim at ~5 s @ 16.78 MHz;
; both are build knobs (raise/lower for a longer/shorter window).  Timing is a
; busy-loop estimate, not timer-exact.
        IFNDEF  BOVWAIT
BOVWAIT EQU     85              ; outer passes
        ENDIF
        IFNDEF  BOVINNER
BOVINNER EQU    $8000           ; inner iterations per outer pass (32768)
        ENDIF

;-----------------------------------------------------------------------
; [main-session addition] Serial monitor ("cow monitor") selection + opcodes.
; After the banner the firmware waits for one byte to pick a mode:
;   NAK ($15) -> XMODEM dump (below, unchanged)
;   'g'/'G'   -> interactive monitor (peek/poke/registers) for live debugging.
; Clean-room: CPU16 datasheet register map + SCI only; no vendor firmware.
MON_G   EQU     $67             ; 'g' : enter monitor
MON_GU  EQU     $47             ; 'G' : enter monitor (upper)
CMD_V   EQU     $56             ; 'V' : version/ping   -> "COW1",CR,LF
CMD_R   EQU     $52             ; 'R' : read  bank,hi,lo,count -> count bytes
CMD_W   EQU     $57             ; 'W' : write bank,hi,lo,data  -> 'K'
CMD_X   EQU     $58             ; 'X' : read SYNCR (clock/SLOCK) -> hi,lo
CMD_J   EQU     $4A             ; 'J' : jump hi,lo (bank-0 program space; experimental)
CMD_S   EQU     $53             ; 'S' : boot slot index -> 1 byte ($FF = not slotted)
CMD_I   EQU     $49             ; 'I' : identify -> "VERSION (BRANCH, DATE)",CR,LF
ACKCHR  EQU     $4B             ; 'K' : write acknowledge

;-----------------------------------------------------------------------
; Slot build (boot_stub.s): `make patch SLOT=n` defines SLOTBASE (and SLOTSZ)
; and this image is assembled to run from slot n of the boot ROM instead of
; owning the reset vector.  The stub enters at SLOTBASE+2 with Y = the slot
; index it chose; the image prints it and flags a mismatch with SLOTNUM.
        IFDEF   SLOTBASE
SLOTNUM EQU     SLOTBASE/SLOTSZ
SLOTMAG EQU     $C057           ; live-slot header word (first byte not $FF/$00)
        IF      (SLOTBASE & (SLOTSZ-1)) <> 0
        ERROR   "SLOTBASE not slot-aligned"
        ENDIF
        IF      (SLOTNUM < 1) || (SLOTBASE >= $80000)
        ERROR   "slot out of range (slot 0 is the stub)"
        ENDIF
        ENDIF

;-----------------------------------------------------------------------
; HEXDIG : B = nibble (0-15) -> send as an ASCII hex digit.  Preserves A.
; HEX2   : B = byte -> send as two hex digits.  Clobbers A and B.
; PUTS   : send n bytes from string s (Y-indexed; YK must hold s's bank).
;   Labels are caller-supplied (asl has no one-liner for macro-local labels).
;-----------------------------------------------------------------------
HEXDIG  MACRO   l
        ADDB    #$30            ; '0'
        CMPB    #$3A            ; past '9'?
        BLO     l
        ADDB    #7              ; -> 'A'..'F'
l:      SENDB
        ENDM

HEX2    MACRO   l1,l2
        TBA                     ; A = byte (SENDB preserves A)
        LSRB
        LSRB
        LSRB
        LSRB
        HEXDIG  l1              ; high nibble
        TAB
        ANDB    #$0F
        HEXDIG  l2              ; low nibble
        ENDM

PUTS    MACRO   s,n,lp,dn
        LDY     #(s&$FFFF)
        LDX     #n
lp:     CPX     #0
        BEQ     dn
        LDAB    0,Y
        SENDB
        AIY     #1
        AIX     #-1
        BRA     lp
dn:
        ENDM

;-----------------------------------------------------------------------
; STROBE : pulse PQS1 (high->low) to service the EXTERNAL DS1232 watchdog
;   (U24), whose /ST input is wired to PQS1 (board schematic: U24 pin 7 <->
;   HC16 pin 11 = MOSI = PQS1).  Disabling the on-chip COP (SYPCR) does NOT
;   touch this external part; left unstrobed it resets the board within its
;   timeout, far shorter than the multi-minute dump.  Clobbers B; PRESERVES
;   A -- safe after a checksum-bearing SENDB.  Needs Z = QSM base and DDRQS
;   bit1 already an output.
;-----------------------------------------------------------------------
; PORTQS bit7 (TXD as GPIO) is held at 1 in both writes so the line idles at
; mark rather than break whenever the SCI is not driving it.
STROBE  MACRO
        LDAB    #$82                    ; PQS1 = 1  (PQS7 = 1)
        STAB    PORTQS,Z
        LDAB    #$80                    ; PQS1 = 0  (edge resets the DS1232)
        STAB    PORTQS,Z
        IFDEF   BOVINE
; Bovine also services the on-chip COP here: unlike the standalone/slot builds
; it never writes SYPCR (write-once -- the host's), so the COP stays enabled
; from reset and must be fed throughout the cow's run (prints and waits), not
; just in the wait loop, or it resets the board mid-banner (a boot loop).  Only
; B is used, so A is still preserved for a checksum-bearing SENDB.  After the
; escape path disables the COP this is a harmless no-op.
        LDAB    #COP_A
        STAB    SWSR                    ; COP service byte 1 ($FFA27, EK=$F)
        LDAB    #COP_B
        STAB    SWSR                    ; COP service byte 2 -> COP timer reset
        ENDIF
        ENDM

;-----------------------------------------------------------------------
; SENDB : transmit the byte in accumulator B over the SCI, then strobe the
;   watchdog.  Polls TDRE (SCSR bit8 = bit0 of SCSR_HI) then writes SCDR:
;   a 16-bit store of D (A:B) -> A to the high byte (T8/unused in 8-bit
;   mode), B to the data byte.  A survives the whole macro (STROBE touches
;   only B, which is no longer needed once the byte is queued), so this is
;   safe in the data loop where A = running checksum.
;-----------------------------------------------------------------------
SENDB   MACRO
        BRCLR   SCSR_HI,Z,#TDRE,*       ; spin here until transmitter ready
        STD     SCDR,Z                  ; write data (B) to SCI data register
        STROBE                          ; feed the watchdog on every byte sent
        ENDM

;-----------------------------------------------------------------------
; RECVB : block until a byte arrives; return it in B (A,B clobbered).  The
;   wait (handshake, per-block ACK, final ACK) is receiver-paced and can
;   exceed the watchdog timeout, so the spin strobes PQS1 every pass.
;-----------------------------------------------------------------------
; lbl = a caller-supplied unique label for the strobing spin (asl has no
; one-liner for a macro-local label, and this macro is used at >1 site).
RECVB   MACRO   lbl
lbl:    STROBE                          ; feed the watchdog while waiting
        BRCLR   SCSR_LO,Z,#RDRF,lbl     ; spin until receive data ready
        LDD     SCDR,Z                  ; read data -> B (low), clears RDRF
        ENDM

;***********************************************************************
; Reset vector (CPU16 fetches 4 words from $000000):
;   word0 = initial ZK:SK:PK  (all banks 0; code runs in bank 0, PK=0)
;   word1 = initial PC
;   word2 = initial SP        (unused: no stack ops / interrupts masked)
;   word3 = initial IZ
; In a slot build the stub owns the reset vector; the slot starts with its
; header word and the entry point follows it.
;***********************************************************************
        IFDEF   BOVINE
;***********************************************************************
; Bovine build: this image is relocated into a host firmware's free $FF space
; at BOVBASE (entry = BOVBASE; the patcher points the reset vector here and
; sets the vector's PK nibble to this image's bank so START runs in it).  The
; CPU loads SP/IZ from the patcher-written vector = the host's originals, so
; CHAIN needs no runtime copy of the host vector; it only restores the one
; host register the cow clobbers (IZ) and JMPs to the host entry.  HOSTPC and
; HOSTIZ are build-time constants the Makefile reads out of the host image.
;***********************************************************************
        IFNDEF  HOSTPC
HOSTPC  EQU     $0400           ; host reset PC (default: RLC-Club at $0400)
        ENDIF
        IFNDEF  HOSTIZ
HOSTIZ  EQU     $0000           ; host reset IZ (vector word3)
        ENDIF
        ORG     BOVBASE
START:
        LDE     #$00FF          ; E low = $FF : not started from a slot
        ELSE
        IFDEF   SLOTBASE
        ORG     SLOTBASE
        DC.W    SLOTMAG         ; live-slot header
START:
        XGDY                    ; D <- slot index handed over by the stub in Y
        TDE                     ; park it in E (untouched until DODUMP)
        ELSE
        ORG     $000000
        DC.W    $0000           ; ZK/SK/PK = 0
        DC.W    START           ; initial PC
        DC.W    $0000           ; initial SP
        DC.W    $0000           ; initial IZ

;***********************************************************************
; Code (placed clear of the CPU16 exception-vector region at $0000-$01FF)
;***********************************************************************
        ORG     $000200
START:
        LDE     #$00FF          ; E low = $FF : not started from a slot
        ENDIF
        ENDIF
        ORP     #$00E0          ; CCR: set interrupt priority mask IP=7
                                ; (interrupts off; also reset default)

; --- Address-extension banks -----------------------------------------
        LDAB    #EKF
        TBEK                    ; EK = $F : extended ops reach $FFxxx
        LDAB    #EKF
        TBZK                    ; ZK = $F : Z-indexed ops reach $FFxxx
        LDZ     #QSMBASE        ; Z -> QSM base ($FFC00 with ZK=$F)
        LDAB    #SRAMBNK
        TBXK                    ; XK = $F8 : X-indexed reads hit SRAM bank 0
        LDX     #$0000          ; X = offset 0 within the SRAM bank

; --- Disable COP watchdog / bus monitor (FIRST) -----------------------
; The on-chip COP comes out of reset ENABLED with a short timeout, so kill it
; before doing anything else.  SYPCR bit7 (SWE)=0 disables it, and writing $00
; also clears the bus/halt monitors.  (The EXTERNAL DS1232 is a separate part,
; serviced by STROBE, not by this register.)
;
; BOVINE: SYPCR is WRITE-ONCE and belongs to the host firmware, so the cow must
; not touch it before deciding to chain.  It is written only on the escape path
; (BOVESC), once the cow has committed to the dumper and will never chain back.
        IFNDEF  BOVINE
        CLRA
        STAA    SYPCR           ; SYPCR = $00  (EK=$F -> $FFA21)
        ENDIF

; --- Watchdog strobe pin + TXD pin -----------------------------------
; PQS1 drives the external DS1232 (U24) /ST input (board schematic: U24 pin 7
; <-> HC16 pin 11 = MOSI = PQS1).  PQSPAR bit1 = 0 (reset default) already
; leaves PQS1 a general-purpose pin; make it an output so STROBE can pulse it.
;
; Bit 7 (PQS7) is the SCI TXD pin, also made an output.  Until TE is set it is
; a plain GPIO driving PORTQS bit7, so PORTQS is preloaded with bit7 = 1 (line
; idle / mark) BEFORE DDRQS turns the driver on, and STROBE keeps bit7 high.
; Otherwise TXD sits low (a break) whenever the SCI is not driving it.
        LDAB    #$80
        STAB    PORTQS,Z        ; PQS7 = 1 (mark), PQS1 = 0
        LDAB    #$82
        STAB    DDRQS,Z         ; DDRQS: PQS7=TXD + PQS1=/ST, both outputs ($FFC17)

; --- System clock synthesizer ----------------------------------------
; Out of reset the HC16Z1 synthesizer runs at f_ref*4*(Y+1)*2^(2W+X) with
; Y=$3F, W=X=0 -> 32768*4*64 = 8.39 MHz.  Program W=0, X=1, Y=$3F ->
; *4*64*2 = 16.777216 MHz, the board's f_sys (HARDWARE_SPEC).  X only switches
; a divider outside the VCO loop, so no relock is needed and there is no wait.
        LDD     #$7F00          ; SYNCR: W=0 X=1 Y=$3F -> 16.78 MHz
        STD     SYNCR           ; (EK=$F -> $FFA04)

; --- Chip select CS0 -> external SRAM ---------------------------------
; Read-modify-write CSPAR0 so only the CS0 field changes: CSBOOT's field holds
; the boot port width (8-bit for the 27C040) and must be left as reset set it.
; Derived from the HC16Z1 SIM chip-select register layout + the board map.
; BOVINE: CS0 frames the SRAM, only needed for the dump; programmed on the
; escape path (BOVESC), not before the chain decision.  (The host reprograms
; all chip selects from scratch at its own reset anyway.)
        IFNDEF  BOVINE
        LDD     CSPAR0
        ANDD    #~CSP0_MSK
        ORD     #CSP0_8
        STD     CSPAR0          ; CS0 pin = 8-bit chip select
        LDD     #CSB0VAL
        STD     CSBAR0          ; $F80000, 256 KB
        LDD     #CSO0VAL
        STD     CSOR0           ; enable: both bytes, R/W, 2 wait states
        ENDIF

; --- Bring up the SCI ------------------------------------------------
        LDD     #SCBRVAL
        STD     SCCR0,Z         ; baud = f_sys/(32*SCBR), SCBR=27 -> ~19200
        LDD     #TE_RE
        STD     SCCR1,Z         ; enable TX + RX, 8 data bits, no parity, 1 stop

; All strings (slot line, banner, done message) live in this image's bank.
        LDAB    #((banner>>16)&$F)
        TBYK                    ; YK = this image's bank

; Identify the build first, whatever banner it carries: "sram_dump VERSION
; (BRANCH, DATE)" from the Makefile-staged ident.bin.  Printed in every build,
; including the bovine front-end below, so the cow announces what it is.
        PUTS    identmsg,IDENTMSG_LEN,pid1,pid2
        LDAB    #CR
        SENDB
        LDAB    #LF
        SENDB

        IFDEF   BOVINE
;-----------------------------------------------------------------------
; Bovine front-end: announce, then open the escape window.  Y = outer pass
; counter; X = inner spin.  Each outer pass feeds the DS1232 (STROBE) and the
; on-chip COP (SWSR $55,$AA -- SYPCR is left untouched) and polls RDRF.  A byte
; within the window -> BOVESC (dumper); the window elapsing -> CHAIN (host).
;-----------------------------------------------------------------------
        PUTS    bovmsg,BOVMSG_LEN,pbv1,pbv2
        LDY     #BOVWAIT
; Y = outer passes, X = inner spin.  STROBE (DS1232 + COP) and the RDRF poll run
; on EVERY inner iteration, so neither watchdog can starve during the delay and
; a keypress is caught promptly.  ~BOVWAIT*BOVINNER iterations total.
BOVWT:
        LDX     #BOVINNER               ; inner spin count
BOVIN:
        STROBE                          ; feed DS1232 + COP every iteration
        BRSET   SCSR_LO,Z,#RDRF,BOVESC  ; a byte arrived -> escape to the dumper
        AIX     #-1
        CPX     #0
        BNE     BOVIN
        AIY     #-1                     ; one outer pass done
        CPY     #0
        BNE     BOVWT
        LBRA    CHAIN                   ; window elapsed -> hand control to host

BOVESC:
; Committed to the dumper: now safe to claim SYPCR (we will never chain back)
; and frame the SRAM on CS0, then join the shared mode-select loop.
        CLRA
        STAA    SYPCR                   ; disable COP + bus/halt monitors
        LDD     CSPAR0
        ANDD    #~CSP0_MSK
        ORD     #CSP0_8
        STD     CSPAR0                  ; CS0 pin = 8-bit chip select
        LDD     #CSB0VAL
        STD     CSBAR0                  ; $F80000, 256 KB
        LDD     #CSO0VAL
        STD     CSOR0                   ; enable: both bytes, R/W, 2 wait states
        LDD     SCDR,Z                  ; consume the escape byte (clears RDRF)
        LDX     #$0000                  ; SRAM read offset for the transfer
        LBRA    SELECT
        ENDIF

        IFDEF   SLOTBASE
;-----------------------------------------------------------------------
; Report the slot the stub started us from (E low), and flag it if that is
; not the slot this image was assembled for -- a stub/layout bug, a wrong
; patch BASE, or a slot that should have been revoked.
;-----------------------------------------------------------------------
        PUTS    slotmsg,SLOTMSG_LEN,psl1,psl2
        TED
        HEX2    hx1,hx2
        TED
        CMPB    #SLOTNUM
        BEQ     SLOTOK
        PUTS    mismsg,MISMSG_LEN,pms1,pms2
        LDAB    #SLOTNUM
        HEX2    hx3,hx4
SLOTOK:
        LDAB    #CR
        SENDB
        LDAB    #LF
        SENDB
        ENDIF

;-----------------------------------------------------------------------
; [main-session addition] Print the build-time-embedded banner (banner.bin).
;   Byte-transparent: drop CR ($0D), expand LF ($0A) -> CR,LF, and emit every
;   other byte verbatim -- so an arbitrary file (plain text OR ANSI/VT100 escape
;   sequences) displays correctly.  Reads the banner via YK:Y (image bank);
;   X is used only as a byte counter (never dereferenced, so the SRAM bank in
;   XK is irrelevant here).  Cosmetic only: does not touch the clean-room
;   init/banking/XMODEM core below.
;-----------------------------------------------------------------------
        LDY     #(banner&$FFFF) ; YK = image bank (set above)
        LDX     #BANNER_LEN     ; X = bytes remaining (counter only)
PRBAN:
        CPX     #0
        BEQ     PRBANX
        LDAB    0,Y             ; next banner byte (bank 0 ROM)
        AIY     #1
        AIX     #-1             ; counter--
        CMPB    #CR
        BEQ     PRBAN           ; drop CR
        CMPB    #LF
        BNE     PRBSEND
        LDAB    #CR             ; LF -> emit CR then LF
        SENDB
        LDAB    #LF
        SENDB
        BRA     PRBAN
PRBSEND:
        SENDB                   ; emit byte verbatim
        BRA     PRBAN
PRBANX:
        LDX     #$0000          ; restore SRAM read offset for the transfer

;-----------------------------------------------------------------------
; [main-session addition] Mode select.  After the banner, one byte chooses:
;   NAK ($15) -> XMODEM dump (original behaviour; a stock XMODEM receiver sends
;                NAK to start, so the dump stays turnkey)
;   'g'/'G'   -> interactive serial monitor (peek/poke/registers)
; Anything else is ignored.  The wait STROBEs the DS1232 (via RECVB) and has no
; timeout: we wait for an explicit trigger byte.
;-----------------------------------------------------------------------
SELECT:
        RECVB   rsel
        CMPB    #NAK
        BEQ     DODUMP
        CMPB    #MON_G
        LBEQ    MONITOR
        CMPB    #MON_GU
        LBEQ    MONITOR
        BRA     SELECT          ; ignore anything else, keep feeding the dog
DODUMP:
        LDE     #EINIT          ; E high = bank tracker ($F8), E low = block# 1

;-----------------------------------------------------------------------
; Main block loop.
;   X   = read offset within current 64 KB SRAM bank
;   XK  = current SRAM bank ($F8..$FB), write-only from E's high byte
;   E   = bank tracker (high byte) : block number (low byte, on-wire value)
;   Z   = QSM base (constant)
; Each 128-byte block lies entirely within one bank (65536/128 = 512),
; so a NAK retransmit only needs to rewind X by 128; XK is unchanged.
;-----------------------------------------------------------------------
BLOCK:
        ; ---- header: SOH, blocknum, ~blocknum ----
        ; SENDB's watchdog STROBE clobbers B, so reload the block number from E
        ; (which STROBE never touches) before forming its complement.
        LDAB    #SOH
        SENDB
        TED                     ; D <- E ; B = E low = block number (A = bank)
        SENDB                   ; send block number
        TED                     ; reload block number into B (E is unchanged)
        COMB                    ; B = ~block number
        SENDB                   ; send block-number complement

        ; ---- 128 data bytes, accumulating checksum in A ----
        CLRA                    ; checksum = 0
        LDY     #BLKSZ          ; byte counter
DATA:
        LDAB    0,X             ; read one SRAM byte (XK:X)  [READ-ONLY]
        ABA                     ; checksum = checksum + data
        SENDB                   ; transmit data byte (preserves A and B)
        AIX     #1              ; advance read pointer
        AIY     #-1             ; counter--
        CPY     #0
        BNE     DATA

        ; ---- checksum byte ----
        TAB                     ; B = checksum
        SENDB

        ; ---- wait for ACK / NAK ----
WACK:
        RECVB   rwack
        CMPB    #ACK
        BEQ     ACKED
        CMPB    #NAK
        BEQ     RESEND
        BRA     WACK            ; ignore anything else

RESEND:
        AIX     #-BLKSZ         ; rewind pointer to start of this block
        LBRA    BLOCK           ; resend same block (long branch: block grew)

ACKED:
        ; advance block number (E low byte), leaving the bank (E high) alone
        TED                     ; A = bank, B = block number
        INCB                    ; block number++ (byte wrap; no carry to bank)
        TDE                     ; E = bank:blocknum
        ; did X just wrap past the end of a 64 KB bank?
        CPX     #0
        LBNE    BLOCK           ; still inside this bank -> next block (long)
        ; bank finished: step to the next SRAM bank.
        ; The bank is tracked in E's high byte and incremented with accumulator
        ; arithmetic, then WRITTEN to XK; XK is never read back.
        TED                     ; A = bank, B = block number
        INCA                    ; bank++  (one 64 KB window)
        TDE                     ; save updated bank back into E high byte
        TAB                     ; B = new bank
        TBXK                    ; XK = new bank  (write only)
        ANDB    #$0F            ; banks used have nibble 8,9,A,B; $C means done
        CMPB    #BANKEND
        LBNE    BLOCK           ; more banks remain (X is already 0) (long)

;-----------------------------------------------------------------------
; End of transfer: send EOT, wait for ACK (resend EOT otherwise), stop.
;-----------------------------------------------------------------------
SENDEOT:
        LDAB    #EOT
        SENDB
        RECVB   reot
        CMPB    #ACK
        BNE     SENDEOT

;-----------------------------------------------------------------------
; [main-session addition] Print a fixed completion line, then halt.
;   donemsg carries explicit CRLF, so it is sent verbatim (no translation).
;   Y = pointer (YK = image bank from the banner setup), X = byte counter.
;-----------------------------------------------------------------------
        LDY     #(donemsg&$FFFF)
        LDX     #DONEMSG_LEN
PRDON:
        CPX     #0
        BEQ     DONE
        LDAB    0,Y
        SENDB
        AIY     #1
        AIX     #-1
        BRA     PRDON

DONE:
        BRA     DONE            ; halt

;-----------------------------------------------------------------------
; [main-session addition] Interactive serial monitor ("cow monitor").
; Entered from SELECT on 'g'/'G'.  Single-letter commands over the same SCI:
;   'V'                      -> "COW1",CR,LF           (ping / baud confirm)
;   'X'                      -> SYNCR hi, SYNCR lo     (clock + SLOCK state)
;   'R' bank hi lo count     -> <count> bytes from bank:hi:lo (count 0 => 256)
;   'W' bank hi lo data      -> writes one byte, replies 'K'
;   'J' hi lo                -> JMP to bank-0 program address hi:lo (experimental)
;   'S'                      -> boot slot index, 1 byte ($FF = not slotted)
;   'I'                      -> "VERSION (BRANCH, DATE)",CR,LF  (which build)
; 'V' stays "COW1": it names the monitor protocol revision, not the build.
; The monitor uses NO RAM: addresses are assembled in registers (GETADR), so
; R/W can probe module registers (e.g. the chip selects) even when external
; SRAM does not respond.  'X' is the live clock probe (SYNCR; SLOCK = lo bit3).
; Every SENDB / RECVB feeds the DS1232.  Clean-room: CPU16 register map + SCI.
;-----------------------------------------------------------------------
; GETADR : receive addr hi, addr lo -> X = hi:lo.  XK untouched (set the bank
;   before or after).  Clobbers D and Y.  Y parks the high byte across the
;   second receive; ABX adds the low byte (hi:00 + lo never carries).
GETADR  MACRO   l1,l2
        RECVB   l1              ; B = hi
        CLRA
        XGDY                    ; Y = 00:hi
        RECVB   l2              ; B = lo
        XGDY                    ; D = 00:hi, Y = ??:lo
        TBA
        CLRB                    ; D = hi:00
        XGDX                    ; X = hi:00
        XGDY                    ; B = lo
        ABX                     ; X = hi:lo
        ENDM

MONITOR:
MONLOOP:
        RECVB   rmon            ; B = command byte
        CMPB    #CMD_V
        LBEQ    MON_V
        CMPB    #CMD_X
        LBEQ    MON_X
        CMPB    #CMD_R
        LBEQ    MON_R
        CMPB    #CMD_W
        LBEQ    MON_W
        CMPB    #CMD_J
        LBEQ    MON_J
        CMPB    #CMD_S
        LBEQ    MON_S
        CMPB    #CMD_I
        LBEQ    MON_I
        BRA     MONLOOP         ; unknown command -> ignore, resync

MON_V:
        LDAB    #$43            ; 'C'
        SENDB
        LDAB    #$4F            ; 'O'
        SENDB
        LDAB    #$57            ; 'W'
        SENDB
        LDAB    #$31            ; '1'
        SENDB
        LDAB    #CR
        SENDB
        LDAB    #LF
        SENDB
        LBRA    MONLOOP

MON_X:
        LDD     SYNCR           ; A = SYNCR hi, B = SYNCR lo
        TAB                     ; B = hi
        SENDB                   ; send hi  (SENDB preserves A)
        LDD     SYNCR           ; re-read: A = hi, B = lo (SYNCR is stable)
        SENDB                   ; send lo
        LBRA    MONLOOP

MON_R:
        RECVB   rr1             ; B = bank
        TBXK                    ; XK = bank
        GETADR  rr2,rr3         ; X = hi:lo
        RECVB   rr4             ; B = count (0 means 256)
        TBA                     ; A = count (survives SENDB)
MONRLP:
        LDAB    0,X             ; read one byte at XK:X
        SENDB                   ; send it
        AIX     #1
        DECA
        BNE     MONRLP
        LBRA    MONLOOP

MON_W:
        RECVB   rw1             ; B = bank
        TBXK                    ; XK = bank
        GETADR  rw2,rw3         ; X = hi:lo
        RECVB   rw4             ; B = data
        STAB    0,X             ; write XK:X = data
        LDAB    #ACKCHR
        SENDB                   ; 'K'
        LBRA    MONLOOP

MON_S:
        TED                     ; B = slot index (E is untouched on this path)
        SENDB
        LBRA    MONLOOP

MON_I:
        PUTS    ident,IDENT_LEN,pim1,pim2   ; YK = image bank since bring-up
        LDAB    #CR
        SENDB
        LDAB    #LF
        SENDB
        LBRA    MONLOOP

MON_J:
        CLRB
        TBXK                    ; XK = 0 : JMP ind20 takes its bank from XK
        GETADR  rj1,rj2         ; X = hi:lo
        JMP     0,X             ; jump to bank-0 program address hi:lo

        IFDEF   BOVINE
;-----------------------------------------------------------------------
; CHAIN : the escape window elapsed -- hand control to the host firmware.
; The host reinitializes every peripheral at its own reset, so we only need to
; put the CPU back into the state a hardware reset leaves and JMP to the host
; entry.  SP and SK are untouched by the cow (it uses no stack), so they still
; hold the host's reset values that the CPU loaded from the patcher-written
; vector.  IZ is the one host register the cow overwrote (LDZ #QSMBASE), so it
; is restored from HOSTIZ.  EK/ZK/XK/YK are returned to 0 (the reset value the
; host's own startup expects).  SYPCR was never written here, so the host's
; write-once programming still takes; and the DS1232 was just strobed, so the
; host gets a full watchdog window -- the same as a cold boot.  A bank-0 host
; entry is assumed (JMP via XK=0); bovine_patch.py verifies the host vector's
; PK nibble is 0 before it builds the image.
;-----------------------------------------------------------------------
CHAIN:
        LDD     #$0000
        STD     SCCR1,Z         ; SCI TE/RE off (needs ZK=$F/Z=QSM -- still set)
        CLRB
        TBEK                    ; EK = 0  (host reset value)
        TBZK                    ; ZK = 0
        TBYK                    ; YK = 0
        LDZ     #HOSTIZ         ; IZ <- host word3 (cow had clobbered Z)
        CLRB
        TBXK                    ; XK = 0  (host program bank)
        LDX     #HOSTPC         ; X = host reset entry PC
        JMP     0,X             ; PK:PC <- 0:HOSTPC -- enter the host firmware
        ENDIF

;-----------------------------------------------------------------------
; Copyright / license string embedded in the image (data only -- never
; executed or printed; discoverable via `strings sram_dump.bin`).
;-----------------------------------------------------------------------
copyright:
        DC.B    "sram_dump  Copyright (C) 2026 Loren Weith  GPL-3.0-or-later  NO WARRANTY",0

;-----------------------------------------------------------------------
; Fixed completion string (explicit CRLF; printed verbatim).
;-----------------------------------------------------------------------
donemsg:
        DC.B    $0D,$0A,"Done. 262144 bytes sent.",$0D,$0A
donemsg_end:
DONEMSG_LEN     EQU     donemsg_end-donemsg

        IFDEF   SLOTBASE
slotmsg:
        DC.B    "boot: slot "
slotmsg_end:
SLOTMSG_LEN     EQU     slotmsg_end-slotmsg
mismsg:
        DC.B    "  SLOT MISMATCH, built for "
mismsg_end:
MISMSG_LEN      EQU     mismsg_end-mismsg
        ENDIF

        IFDEF   BOVINE
;-----------------------------------------------------------------------
; Bovine prompt: printed once before the escape window opens.  Kept short
; (the full file banner is skipped on this path).  @BAUD@ is NOT substituted
; here -- this is a source literal, not the staged banner file.
;-----------------------------------------------------------------------
bovmsg:
        DC.B    $0D,$0A,"MOO! bovine boot. Press any key for dumper/monitor, "
        DC.B    "else booting host...",$0D,$0A
bovmsg_end:
BOVMSG_LEN      EQU     bovmsg_end-bovmsg
        ENDIF

;-----------------------------------------------------------------------
; Build-time-embedded banner: an arbitrary file staged as banner.bin (the
; Makefile copies BANNER -> banner.bin).  Printed byte-transparently at
; startup (see PRBAN).  Follows the code directly, so it lands in the same
; slot and bank; length is computed at assemble time.
;-----------------------------------------------------------------------
banner:
        BINCLUDE "banner.bin"
banner_end:
BANNER_LEN      EQU     banner_end-banner

;-----------------------------------------------------------------------
; Build identification, staged by the Makefile from version.sh as ident.bin:
; "VERSION (BRANCH, DATE)", no line ending.  Printed at boot after the
; "sram_dump " prefix, and alone by monitor 'I'.  Also visible to `strings`.
;-----------------------------------------------------------------------
identmsg:
        DC.B    "sram_dump "
ident:
        BINCLUDE "ident.bin"
ident_end:
IDENTMSG_LEN    EQU     ident_end-identmsg
IDENT_LEN       EQU     ident_end-ident

        IFDEF   SLOTBASE
        IF      ident_end > SLOTBASE+SLOTSZ
        ERROR   "image overflows its slot (raise SLOTSZ or shrink the banner)"
        ENDIF
        ENDIF

        END
