; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Loren Weith
;
;***********************************************************************
; bovine_stubfix.s  -  In-place repair of the 1.4.0 bovine slot stub
;                      (MC68HC16Z1), applied WITHOUT an erase
;
; The 1.4.0 stub (bovine_stub.s) hands over with  JMP 8,X  and XK = the slot's
; bank.  On silicon the 20-bit indexed mode adds the offset to the 16-bit index
; register only -- NOT its extension field (MC68HC16Z1 User's Manual 5.5.3;
; the 8- and 16-bit modes do use it) -- so the bank comes from the offset alone
; and the jump lands in bank 0: the host's vectors or the middle of host code.
;
; Repair, by programming only (bits 1 -> 0) onto a chip that holds the 1.4.0
; stub:
;   - the stub's  BNE SUM  at $2D04C (B6 E0) becomes  BRA STUB2  (B0 40): the
;     first time the old stub sums a slot it has accepted the header of, it
;     comes here instead.  If no slot has a valid header the old stub never
;     gets there and chains to the host as before (a path proven on silicon).
;   - STUB2, in the blank space after the stub: the same top-down scan and
;     checks, then a hand-over that does not depend on how the 20-bit indexed
;     mode treats XK: the slot index picks an entry of a table of JMPs with
;     absolute 20-bit addresses (EXT20), reached by  JMP TABLE,X  with XK = 0
;     and a small IX -- the same result under either reading.
; Layout constants must match the burned stub.
; Clean-room: CPU16 instruction set, reset-vector layout, COP service only.
;***********************************************************************

        CPU     68HC16

        IFNDEF  STUBBASE
STUBBASE EQU    $2D000
        ENDIF
        IFNDEF  SLOT0
SLOT0   EQU     $30000
        ENDIF
        IFNDEF  SLOTSZ
SLOTSZ  EQU     $2000
        ENDIF
        IFNDEF  NSLOTS
NSLOTS  EQU     24
        ENDIF
        IFNDEF  HOSTPC
HOSTPC  EQU     $0400
        ENDIF
        IFNDEF  HOSTIZ
HOSTIZ  EQU     $0000
        ENDIF

MAGIC   EQU     $C057
HDRSZ   EQU     8
SLOTTOP EQU     SLOT0+(NSLOTS-1)*SLOTSZ
SWSR    EQU     $FA27
OLDBNE  EQU     STUBBASE+$4C    ; BNE SUM in the 1.4.0 stub (B6 E0)
STUB2   EQU     STUBBASE+$92    ; reachable as B0 40 from OLDBNE

        IF      SLOTSZ <> $2000
        ERROR   "the slot index arithmetic below assumes 8 KB slots"
        ENDIF

;-----------------------------------------------------------------------
; the patch to the old stub: B6 E0 -> B0 40 (clears bits only)
        ORG     OLDBNE
        BRA     STUB2
        IF      * <> OLDBNE+2
        ERROR   "BRA did not assemble to two bytes"
        ENDIF

;-----------------------------------------------------------------------
        ORG     STUB2
        ORP     #$00E0
        LDAB    #$0F
        TBEK                    ; EK = $F : SWSR reachable
        LDAB    #(SLOTTOP>>16)
        TBXK
        LDX     #(SLOTTOP&$FFFF)

PROBE:
        LDD     0,X
        CPD     #MAGIC
        BNE     NEXT
        LDD     2,X
        BEQ     NEXT
        CPD     #(SLOTSZ-HDRSZ)
        BHI     NEXT
        BITB    #1
        BNE     NEXT
        LSRD
        XGDY                    ; Y = words to sum
        CLRD
        XGDZ                    ; Z = running sum
        LDE     #HDRSZ
SUM:
        XGDZ
        ADDD    E,X             ; (8/16-bit and E-offset modes DO use XK)
        XGDZ
        LDAB    #$55
        STAB    SWSR
        LDAB    #$AA
        STAB    SWSR
        ADDE    #2
        AIY     #-1
        CPY     #0
        BNE     SUM
        XGDZ
        CPD     4,X
        BNE     NEXT

        ; good slot at XK:X.  Its index within the table:
        ;   (XK - SLOT0 bank) * 8 slots/bank + X / $2000, times 4 bytes/entry
        TXKB
        SUBB    #(SLOT0>>16)
        LSLB
        LSLB
        LSLB
        LSLB
        LSLB                    ; B = bank * 32
        CLRA
        TDE                     ; E = bank * 32
        XGDX                    ; D = X (slot offset in its bank)
        LSRA
        LSRA
        LSRA                    ; A = X >> 11 = slot-in-bank * 4
        TAB
        CLRA
        ADE                     ; E = table offset
        TED
        XGDX                    ; X = table offset (small, positive)
        LDZ     #HOSTIZ
        CLRB
        TBEK                    ; EK = 0
        TBXK                    ; XK = 0: same result whether or not XK counts
        JMP     TABLE,X

NEXT:
        AIX     #-SLOTSZ        ; 20-bit: borrows into XK (manual: XK:IX + IMM)
        TXKB
        CMPB    #(SLOT0>>16)
        LBCC    PROBE           ; BHS, long: PROBE is out of short range

NONE:
        LDZ     #HOSTIZ
        CLRB
        TBEK
        TBXK
        LDX     #HOSTPC
        JMP     0,X             ; IX + 0, bank 0: the host (as CHAIN, proven)

        ALIGN   2
TABLE:
I       SET     0
        WHILE   I < NSLOTS
        JMP     SLOT0+I*SLOTSZ+HDRSZ    ; EXT20: absolute
I       SET     I+1
        ENDM

        END
