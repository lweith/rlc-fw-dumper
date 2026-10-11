; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Loren Weith
;
;***********************************************************************
; boot_stub.s  -  Slot selector for an append-only boot EPROM (MC68HC16Z1)
;
; The 512 KB boot ROM is divided into SLOTSZ-byte slots.  Slot 0 holds this
; stub (reset vector + scanner) and is burned ONCE.  Slots 1..N hold complete
; firmware images, each assembled at its own slot address, appended over time
; without erasing: programming only ever clears bits (1->0), so a blank ($FF)
; slot can be filled in later on an already-burned chip.
;
; Slot header (first word of a slot; the entry point is slot+2, keeping the
; code word-aligned as CPU16 requires):
;   first byte $FF -> blank    (never programmed)
;   first byte $00 -> revoked  (zeroed later to fall back to an older slot)
;   anything else  -> live
; The stub scans from the TOP slot down and jumps to the first live one,
; i.e. the last one burned.  No live slot -> spin (a reset rescans).
;
; Handoff: Y = index of the chosen slot, XK:X = its header address.  The
; image reports the slot it was started from using Y.
;
; The stub touches NO configuration registers: SYPCR, SYNCR, etc. are
; write-once or stateful, and belong to the image.  The scan completes in
; microseconds, well inside the reset-default COP timeout and the DS1232
; window, so neither watchdog needs servicing here.
;
; SLOTSZ is fixed for the life of the chip once this stub is burned.
; Clean-room: CPU16 instruction set + reset-vector layout only.
;***********************************************************************

        CPU     68HC16

        IFNDEF  SLOTSZ
SLOTSZ  EQU     16384           ; bytes per slot (power of two, 4K..32K)
        ENDIF
ROMSZ   EQU     $80000          ; 512 KB boot window (CSBOOT)
NSLOTS  EQU     ROMSZ/SLOTSZ    ; slot 0 = this stub, 1..NSLOTS-1 = images
TOPSLOT EQU     ROMSZ-SLOTSZ    ; address of the highest slot
BLANK   EQU     $FF
REVOKED EQU     $00

        IF      (SLOTSZ < 4096) || (SLOTSZ > 32768) || ((SLOTSZ & (SLOTSZ-1)) <> 0)
        ERROR   "SLOTSZ must be a power of two from 4K to 32K"
        ENDIF

;***********************************************************************
; Reset vector (CPU16 fetches 4 words from $000000):
;   ZK:SK:PK, PC, SP, IZ
;***********************************************************************
        ORG     $000000
        DC.W    $0000           ; ZK/SK/PK = 0
        DC.W    STUB            ; initial PC
        DC.W    $0000           ; initial SP (unused: no stack)
        DC.W    $0000           ; initial IZ

        ORG     $000200
STUB:
        ORP     #$00E0          ; interrupts off (also reset default)
        LDAB    #(TOPSLOT>>16)
        TBXK                    ; XK:X = highest slot
        LDX     #(TOPSLOT&$FFFF)
        LDY     #NSLOTS-1       ; Y = index of the probed slot
PROBE:
        LDAB    0,X             ; header byte at XK:X
        CMPB    #BLANK
        BEQ     NEXT
        CMPB    #REVOKED
        BEQ     NEXT
        JMP     2,X             ; ind20: PK:PC <- XK:X+2  (Y = slot index)
NEXT:
        AIY     #-1
        CPY     #0
        BEQ     NONE            ; reached slot 0 (this stub) -> nothing to run
        ; IX is 20 bits (XK:X): AIX borrows out of XK by itself at a bank
        ; boundary, so stepping down one slot needs no bank arithmetic.
        AIX     #-SLOTSZ
        BRA     PROBE
NONE:
        BRA     NONE

        IF      * > SLOTSZ
        ERROR   "stub overflows slot 0"
        ENDIF

        END
