; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 Loren Weith
;
;***********************************************************************
; bovine_tramp.s  -  A one-instruction bovine slot body: jump to a cow that
;                    already sits in another slot (MC68HC16Z1)
;
; The slot stub sums a slot's whole body before trusting it.  At reset the
; boot ROM is an 8-bit port with the reset wait states, so summing a full cow
; takes tens of milliseconds on silicon (microseconds in the emulator).  A
; trampoline is a 4-byte body: the stub checks it in microseconds and jumps
; here, and this jumps on to the cow at TARGET (a slot's body, slot+8), which
; then runs exactly as if the stub had chosen it.  CPU state is untouched.
; Clean-room: CPU16 instruction set only.
;***********************************************************************

        CPU     68HC16

        IFNDEF  BOVBASE
        ERROR   "BOVBASE (this slot's body address) must be given"
        ENDIF
        IFNDEF  TARGET
        ERROR   "TARGET (the cow's entry, a slot address + 8) must be given"
        ENDIF

        ORG     BOVBASE
        JMP     TARGET          ; EXT20: PK:PC <- TARGET

        END
