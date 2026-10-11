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
; to XK; XK is never read back (a read-modify-write of the extension
; register does not round-trip as +1 on this target).
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
ACKCHR  EQU     $4B             ; 'K' : write acknowledge
; Scratch cell for assembling a 24-bit pointer from received bytes (CPU16 has
; no D->X transfer, so the address bytes land here and LDX pulls the offset).
; Placed in the firmware-idle SRAM gap so it never touches config; Y (YK=$F8)
; points at it for the whole monitor session.
SCRBNK  EQU     $F8             ; scratch bank (SRAM CS0)
SCROFF  EQU     $E000           ; scratch offset -> $F8E000 (idle gap)

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
;***********************************************************************
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
        CLRA
        STAA    SYPCR           ; SYPCR = $00  (EK=$F -> $FFA21)

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

; --- Bring up the SCI ------------------------------------------------
        LDD     #SCBRVAL
        STD     SCCR0,Z         ; baud = f_sys/(32*SCBR), SCBR=27 -> ~19200
        LDD     #TE_RE
        STD     SCCR1,Z         ; enable TX + RX, 8 data bits, no parity, 1 stop

;-----------------------------------------------------------------------
; [main-session addition] Print the build-time-embedded banner (banner.bin).
;   Byte-transparent: drop CR ($0D), expand LF ($0A) -> CR,LF, and emit every
;   other byte verbatim -- so an arbitrary file (plain text OR ANSI/VT100 escape
;   sequences) displays correctly.  Reads the banner from bank 0 via Y (YK=0);
;   X is used only as a byte counter (never dereferenced, so the SRAM bank in
;   XK is irrelevant here).  Cosmetic only: does not touch the clean-room
;   init/banking/XMODEM core below.
;-----------------------------------------------------------------------
        CLRB
        TBYK                    ; YK = 0 : Y-indexed reads hit bank 0 (banner ROM)
        LDY     #banner
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
;   Y = pointer (YK=0 from the banner setup), X = byte counter.
;-----------------------------------------------------------------------
        LDY     #donemsg
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
; Multi-byte addresses are assembled through the SCROFF scratch cell (CPU16 has
; no D->X transfer).  'V' and 'X' touch no RAM, so they answer even if external
; SRAM is dead -- 'X' is the live clock probe (SYNCR; SLOCK = lo bit3).  Every
; SENDB / RECVB feeds the DS1232.  Clean-room: CPU16 register map + SCI only.
;-----------------------------------------------------------------------
MONITOR:
        LDAB    #SCRBNK
        TBYK                    ; YK = $F8 : Y-indexed stores hit the SRAM scratch
        LDY     #SCROFF         ; Y -> $F8E000 (firmware-idle gap)
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
        RECVB   rr1
        STAB    2,Y             ; [2] = bank
        RECVB   rr2
        STAB    0,Y             ; [0] = addr hi
        RECVB   rr3
        STAB    1,Y             ; [1] = addr lo
        RECVB   rr4
        STAB    3,Y             ; [3] = count (0 means 256)
        LDAB    2,Y
        TBXK                    ; XK = bank
        LDX     0,Y             ; X = hi:lo
        LDAA    3,Y             ; A = count (survives SENDB)
MONRLP:
        LDAB    0,X             ; read one byte at XK:X
        SENDB                   ; send it
        AIX     #1
        DECA
        BNE     MONRLP
        LBRA    MONLOOP

MON_W:
        RECVB   rw1
        STAB    2,Y             ; bank
        RECVB   rw2
        STAB    0,Y             ; addr hi
        RECVB   rw3
        STAB    1,Y             ; addr lo
        RECVB   rw4
        STAB    3,Y             ; data
        LDAB    2,Y
        TBXK                    ; XK = bank
        LDX     0,Y             ; X = hi:lo
        LDAB    3,Y             ; data
        STAB    0,X             ; write XK:X = data
        LDAB    #ACKCHR
        SENDB                   ; 'K'
        LBRA    MONLOOP

MON_J:
        RECVB   rj1
        STAB    0,Y             ; addr hi
        RECVB   rj2
        STAB    1,Y             ; addr lo
        LDX     0,Y             ; X = hi:lo
        JMP     0,X             ; jump within current program bank (PK=0)

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

;-----------------------------------------------------------------------
; Build-time-embedded banner: an arbitrary file staged as banner.bin (the
; Makefile / build.sh copies BANNER -> banner.bin).  Printed byte-transparently
; at startup (see PRBAN).  Placed clear of the code so any reasonable size fits
; the image budget; length is computed at assemble time.
;-----------------------------------------------------------------------
        ORG     $001000
banner:
        BINCLUDE "banner.bin"
banner_end:
BANNER_LEN      EQU     banner_end-banner

        END
