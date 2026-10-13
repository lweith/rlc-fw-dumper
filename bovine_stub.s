; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Loren Weith
;
;***********************************************************************
; bovine_stub.s  -  Permanent slot selector for a grafted (bovine) boot ROM
;                   (MC68HC16Z1)
;
; The bovine build puts the cow into a host firmware's blank ($FF) space and
; points the reset vector at it -- a 0->1 change, so every new cow needed a
; UV erase.  This stub is grafted ONCE in its place; cows then go into
; append-only slots in the host's blank space, each programmed later onto the
; already-burned chip (programming only ever clears bits, 1->0), never erased.
;
; Slot layout (all build constants, FIXED for the life of the chip once this
; stub is burned): NSLOTS slots of SLOTSZ bytes from SLOT0, which must start a
; 64 KB bank.  Each slot:
;   +0  word  MAGIC ($C057)  first byte $FF = blank, $00 = revoked
;   +2  word  L              body length in bytes (even, 2..SLOTSZ-8)
;   +4  word  SUM            16-bit sum of the body's big-endian words
;   +6  word  0
;   +8  body                 a bovine cow assembled to run here; entry = +8
;
; The stub scans from the TOP slot down and jumps to the first whose header is
; MAGIC with a sane length and a matching SUM -- the last one burned that came
; out right.  A half-programmed slot, one over stuck bits, or one revoked by
; zeroing its first byte fails the check and the next lower slot is tried.
; No good slot -> chain straight to the host, exactly as a reset would leave
; it (so revoking every slot gives back the plain host).
;
; The stub writes NO configuration registers.  It runs from reset with the
; on-chip COP enabled (write-once SYPCR belongs to the host), so it services
; SWSR while it sums; the scan of blank slots takes microseconds.  It uses D,
; E, X, Y, Z and EK/XK, and leaves EK=XK=0 and IZ=HOSTIZ, as the reset vector
; had them, before it jumps.  SP/SK come from the vector and are untouched.
; Clean-room: CPU16 instruction set, reset-vector layout, COP service only.
;***********************************************************************

        CPU     68HC16

        IFNDEF  STUBBASE
STUBBASE EQU    $2D000          ; where the stub is grafted (host blank space)
        ENDIF
        IFNDEF  SLOT0
SLOT0   EQU     $30000          ; first slot; must start a 64 KB bank
        ENDIF
        IFNDEF  SLOTSZ
SLOTSZ  EQU     $2000           ; bytes per slot
        ENDIF
        IFNDEF  NSLOTS
NSLOTS  EQU     24
        ENDIF
        IFNDEF  HOSTPC
HOSTPC  EQU     $0400           ; host reset PC (vector word1; bank 0)
        ENDIF
        IFNDEF  HOSTIZ
HOSTIZ  EQU     $0000           ; host reset IZ (vector word3)
        ENDIF

MAGIC   EQU     $C057
HDRSZ   EQU     8
SLOTTOP EQU     SLOT0+(NSLOTS-1)*SLOTSZ
SWSR    EQU     $FA27           ; COP service register ($FFA27 with EK=$F)

        IF      (SLOT0 & $FFFF) <> 0
        ERROR   "SLOT0 must start a 64 KB bank"
        ENDIF
        IF      SLOTSZ <> $2000
        ERROR   "the hand-over's slot-index arithmetic assumes 8 KB slots"
        ENDIF
        IF      SLOT0+NSLOTS*SLOTSZ > $80000
        ERROR   "slots run past the 512 KB ROM"
        ENDIF
        IF      (STUBBASE & 1) <> 0
        ERROR   "STUBBASE not word-aligned"
        ENDIF

        ORG     STUBBASE
STUB:
        ORP     #$00E0          ; interrupts off (also the reset default)
        LDAB    #$0F
        TBEK                    ; EK = $F : SWSR reachable
        LDAB    #(SLOTTOP>>16)
        TBXK                    ; XK:X = the top slot
        LDX     #(SLOTTOP&$FFFF)

PROBE:
        LDD     0,X             ; header word
        CPD     #MAGIC
        BNE     NEXT            ; blank ($FF..), revoked ($00..) or junk
        LDD     2,X             ; L = body length
        BEQ     NEXT
        CPD     #(SLOTSZ-HDRSZ)
        BHI     NEXT
        BITB    #1
        BNE     NEXT            ; must be even (whole words)
        LSRD
        XGDY                    ; Y = words to sum
        CLRD
        XGDZ                    ; Z = running sum
        LDE     #HDRSZ          ; E = offset of the next word in the slot
SUM:
        XGDZ                    ; D = sum
        ADDD    E,X             ; + word at XK:X+E
        XGDZ                    ; Z = sum
        LDAB    #$55            ; COP service: $55 then $AA to SWSR
        STAB    SWSR
        LDAB    #$AA
        STAB    SWSR
        ADDE    #2
        AIY     #-1
        CPY     #0
        BNE     SUM
        XGDZ                    ; D = sum
        CPD     4,X
        BNE     NEXT            ; damaged, partly programmed or over stuck bits

        ; Good slot at XK:X.  Hand over through a table of absolute (EXT20)
        ; JMPs.  NOT  JMP 8,X : the 20-bit indexed mode adds its offset to the
        ; 16-bit IX only, not XK (User's Manual 5.5.3; the 8/16-bit and
        ; E-offset modes do use XK), so the bank must come from the offset --
        ; 1.4.0 did that and landed in bank 0 on silicon.  Table index =
        ; ((XK - SLOT0 bank) * slots/bank + X / SLOTSZ) * 4, reached with
        ; XK = 0 and a small IX: the same address under either reading.
        ; (the same instruction sequence as bovine_stubfix.s, which ran on
        ; silicon; 8 KB slots: 8 per bank, X / $2000 * 4 = X >> 11)
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
        TBXK                    ; XK = 0
        JMP     TABLE,X

NEXT:
        ; AIX is a 20-bit add (manual: XK:IX + IMM => XK:IX): it borrows out of
        ; XK at a bank boundary.  SLOT0 starts a bank, so stepping below it
        ; leaves XK one bank lower -- that is the end of the scan.
        AIX     #-SLOTSZ
        TXKB
        CMPB    #(SLOT0>>16)
        LBCC    PROBE           ; BHS (long: PROBE is out of short range)

NONE:
        ; no good slot: chain to the host as reset left the CPU
        LDZ     #HOSTIZ
        CLRB
        TBEK                    ; EK = 0
        TBXK                    ; XK = 0 (host bank)
        LDX     #HOSTPC
        JMP     0,X             ; IX + 0 in bank 0 (as CHAIN; proven on silicon)

        ALIGN   2
TABLE:
I       SET     0
        WHILE   I < NSLOTS
        JMP     SLOT0+I*SLOTSZ+HDRSZ    ; EXT20: absolute
I       SET     I+1
        ENDM

        END
