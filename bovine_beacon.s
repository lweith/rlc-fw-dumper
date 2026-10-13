; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Loren Weith
;
;***********************************************************************
; bovine_beacon.s  -  Diagnostic bovine slot body (MC68HC16Z1)
;
; Started by the slot stub like any slot.  It brings up the SCI as the cow
; does, then reports what the CPU actually reads in-circuit:
;     BEACON H=<the 8 header bytes of slot PROBE> S=<its body sum>
; computing the sum with the stub's own loop (16-bit sum of big-endian words,
; length from the header), while servicing both watchdogs.  Then it jumps on
; to TARGET (a cow's entry) with an absolute EXT20 JMP.  Each line tells a
; step apart: no output =
; the stub's jump into a slot / code in this bank fails; wrong H or S = reads
; of PROBE's bank come back wrong; output then silence = the cow at TARGET
; cannot run.  Clean-room: CPU16 datasheet only.
;***********************************************************************

        CPU     68HC16

        IFNDEF  BOVBASE
        ERROR   "BOVBASE (this slot's body address) must be given"
        ENDIF
        IFNDEF  TARGET
        ERROR   "TARGET (the cow's entry) must be given"
        ENDIF
        IFNDEF  PROBE
PROBE   EQU     TARGET-8        ; the slot whose header and sum are reported
        ENDIF
        IFNDEF  SCBRVAL
SCBRVAL EQU     27              ; ~19200 baud at 16.78 MHz
        ENDIF

SYNCR   EQU     $FA04
SWSR    EQU     $FA27
QSMBASE EQU     $FC00
SCCR0   EQU     $08
SCCR1   EQU     $0A
SCSR_HI EQU     $0C
SCDR    EQU     $0E
PORTQS  EQU     $15
DDRQS   EQU     $17
TDRE    EQU     $01
CR      EQU     $0D
LF      EQU     $0A

; strobe the DS1232 (PQS1 high->low, TXD idle high) and service the COP.
; EXT addressing (EK=$F), so Z is free.  Clobbers B only.
STROBE  MACRO
        LDAB    #$82
        STAB    QSMBASE+PORTQS
        LDAB    #$80
        STAB    QSMBASE+PORTQS
        LDAB    #$55
        STAB    SWSR
        LDAB    #$AA
        STAB    SWSR
        ENDM

; send B over the SCI (Z = QSM base); preserves A
SENDB   MACRO
        BRCLR   SCSR_HI,Z,#TDRE,*
        STD     SCDR,Z
        STROBE
        ENDM

HEXDIG  MACRO   l
        ADDB    #$30
        CMPB    #$3A
        BLO     l
        ADDB    #7
l:      SENDB
        ENDM

; B = byte -> two hex digits.  Clobbers A and B.
HEX2    MACRO   l1,l2
        TBA
        LSRB
        LSRB
        LSRB
        LSRB
        HEXDIG  l1
        TAB
        ANDB    #$0F
        HEXDIG  l2
        ENDM

; send the string s of n bytes (YK must hold s's bank).  Clobbers X, Y, B.
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

        ORG     BOVBASE
BEACON:
        ORP     #$00E0
        LDAB    #$0F
        TBEK                    ; EK = $F : module registers by EXT
        TBZK
        LDZ     #QSMBASE        ; ZK:Z = QSM
        LDAB    #$80
        STAB    PORTQS,Z        ; TXD idle high, PQS1 low
        LDAB    #$82
        STAB    DDRQS,Z         ; PQS7 (TXD) and PQS1 (DS1232 /ST) outputs
        LDD     #$7F00
        STD     SYNCR           ; 16.78 MHz, as the cow
        LDD     #SCBRVAL
        STD     SCCR0,Z
        LDD     #$000C
        STD     SCCR1,Z         ; TE + RE, 8N1
        LDAB    #((msg>>16)&$F)
        TBYK
        PUTS    msg,MSGLEN,pm1,pm2

        ; the 8 header bytes of PROBE, as read here
        LDE     #0
HDR:
        LDAB    #(PROBE>>16)
        TBXK
        LDX     #(PROBE&$FFFF)
        LDAB    E,X
        HEX2    hx1,hx2
        ADDE    #1
        CPE     #8
        BNE     HDR

        LDAB    #((msg2>>16)&$F)
        TBYK
        PUTS    msg2,MSG2LEN,pn1,pn2

        ; the body sum, the stub's way (Z = sum, Y = words left, E = offset)
        LDAB    #(PROBE>>16)
        TBXK
        LDX     #(PROBE&$FFFF)
        LDD     2,X
        LSRD
        XGDY
        CLRD
        XGDZ
        LDE     #8
SUM:
        XGDZ
        ADDD    E,X
        XGDZ
        STROBE
        ADDE    #2
        AIY     #-1
        CPY     #0
        BNE     SUM
        XGDZ                    ; D = sum
        LDZ     #QSMBASE        ; Z = QSM again
        TDE                     ; park it
        TAB
        HEX2    hs1,hs2         ; high byte
        TED
        HEX2    hs3,hs4         ; low byte
        LDAB    #CR
        SENDB
        LDAB    #LF
        SENDB
        BRCLR   SCSR_HI,Z,#TDRE,* ; let the last byte go before the cow resets the SCI

        ; on to the cow: EXT20, an absolute 20-bit address.  (Not  JMP 0,X  with
        ; XK = the bank: the 20-bit indexed mode ignores XK -- User's Manual
        ; 5.5.3 -- which is what sent the 1.4.0 stub, and this beacon's first
        ; build, into bank 0 on silicon.)
        JMP     TARGET

msg:    DC.B    CR,LF,"BEACON H="
MSGLEN  EQU     *-msg
msg2:   DC.B    " S="
MSG2LEN EQU     *-msg2

        END
