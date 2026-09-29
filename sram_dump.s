; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 KN6FLN
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
SYPCR   EQU     $FA21           ; System Protection CR (byte) -> disable COP
;
; QSM (base $FFC00) - Z points here at run time (Z = $FC00, ZK = $F):
QSMBASE EQU     $FC00
SCCR0   EQU     $08             ; offset of SCI Control Reg 0 (baud)   $FFC08
SCCR1   EQU     $0A             ; offset of SCI Control Reg 1 (enables)$FFC0A
SCSR_HI EQU     $0C             ; SCI Status high byte ($FFC0C): TDRE = bit0
SCSR_LO EQU     $0D             ; SCI Status low  byte ($FFC0D): RDRF = bit6
SCDR    EQU     $0E             ; SCI Data Register (16-bit) $FFC0E; data = low
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
; SENDB : transmit the byte in accumulator B over the SCI.
;   Polls TDRE (SCSR bit8 = bit0 of SCSR_HI) then writes SCDR.
;   Uses a 16-bit store of D (A:B) to SCDR: A -> high byte (T8/unused,
;   ignored in 8-bit mode), B -> low byte (the data).  Preserves A and B,
;   so it is safe to call from inside the data loop where A = checksum.
;-----------------------------------------------------------------------
SENDB   MACRO
        BRCLR   SCSR_HI,Z,#TDRE,*       ; spin here until transmitter ready
        STD     SCDR,Z                  ; write data (B) to SCI data register
        ENDM

;-----------------------------------------------------------------------
; RECVB : block until a byte arrives; return it in B (A clobbered).
;   Poll RDRF, then read SCDR (clears RDRF).
;-----------------------------------------------------------------------
RECVB   MACRO
        BRCLR   SCSR_LO,Z,#RDRF,*       ; spin here until receive data ready
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

; --- Disable COP watchdog / bus monitor ------------------------------
; The transfer takes minutes at 9600 baud, far longer than any COP
; timeout, so the software watchdog must be off.  SYPCR bit7 (SWE) = 0
; disables it; writing $00 also clears the bus/halt monitors.
        CLRA
        STAA    SYPCR           ; SYPCR = $00  (EK=$F -> $FFA21)

; --- Bring up the SCI ------------------------------------------------
        LDD     #SCBRVAL
        STD     SCCR0,Z         ; baud = f_sys/(32*SCBR), SCBR=55 -> ~9600
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

        LDE     #EINIT          ; E high = bank tracker ($F8), E low = block# 1

;-----------------------------------------------------------------------
; Handshake: wait for the receiver's start byte.  We run checksum mode,
; so we wait specifically for NAK ($15) and ignore anything else
; (a CRC-mode 'C' is ignored; a standard receiver falls back to NAK).
;-----------------------------------------------------------------------
HANDSHK:
        RECVB
        CMPB    #NAK
        BNE     HANDSHK

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
        LDAB    #SOH
        SENDB
        TED                     ; D <- E ; B = E low = block number (A = bank)
        SENDB                   ; send block number
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
        RECVB
        CMPB    #ACK
        BEQ     ACKED
        CMPB    #NAK
        BEQ     RESEND
        BRA     WACK            ; ignore anything else

RESEND:
        AIX     #-BLKSZ         ; rewind pointer to start of this block
        BRA     BLOCK           ; resend same block (same block number)

ACKED:
        ; advance block number (E low byte), leaving the bank (E high) alone
        TED                     ; A = bank, B = block number
        INCB                    ; block number++ (byte wrap; no carry to bank)
        TDE                     ; E = bank:blocknum
        ; did X just wrap past the end of a 64 KB bank?
        CPX     #0
        BNE     BLOCK           ; still inside this bank -> next block
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
        BNE     BLOCK           ; more banks remain (X is already 0)

;-----------------------------------------------------------------------
; End of transfer: send EOT, wait for ACK (resend EOT otherwise), stop.
;-----------------------------------------------------------------------
SENDEOT:
        LDAB    #EOT
        SENDB
        RECVB
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
