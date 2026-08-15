; -----------------------------------------------------------------------------
; jx1_hatari_ring.S - real-hardware validation for 68k/jx1_68000_ring.S
;
; The ring decompressor's whole point is bounded memory, so this decompresses
; corpora far larger than the buffer they stream through (32000 bytes through
; 256) on a real 68000 - under Hatari's cycle-exact Atari ST emulation, or on
; actual silicon.
;
; Nothing is accumulated: each call's output is compared against the expected
; image as it is drained, which is exactly what a real caller does with it,
; and the wrap is detected the way the interface intends - the write pointer
; never wraps inside a call, so a full buffer reaches the harness's saved end.
; The general decoder packs N and the end address's low word above its common
; word-sized state and can wrap on its next entry; ring_mod has no bounds at
; all, so its caller wraps a1.
;
; The general build covers dividing and non-dividing shapes.  Each ring_mod
; build has one assembly-time RING_SIZE and covers fixed dividing budgets.
;
; See README.md in this directory for building, running, and the results.
; -----------------------------------------------------------------------------

GEMDOS      equ     1
Pterm0      equ     0
Cconws      equ     9
Super       equ     $20
hz200       equ     $4BA            ; 200 Hz system tick (supervisor only)

CASE_NAME   equ     0               ; case table entry layout (see gendata.py)
CASE_SRC    equ     4
CASE_SLEN   equ     8
CASE_EXP    equ     12
CASE_ELEN   equ     16
CASE_ITER   equ     20
CASE_SIZE   equ     24

CALIB_OUTER equ     12              ; x 655386 cycles = 7.86M
RING_BIG    equ     1024
RING_ODD    equ     1000            ; neither a power of two nor a multiple
RING_SMALL  equ     256             ; must match gendata.py's RING (-mN)

        .text

start:
        move.l  #stack_top,-(sp)    ; supervisor mode, on our own stack
        move.w  #Super,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        move.l  d0,save_ssp

        lea     m_banner,a0
        bsr     puts

; ---------------------------------------------------------------- correctness
        lea     ring_cases,a6
.case:
        tst.l   CASE_NAME(a6)
        beq     .timing

        movea.l CASE_NAME(a6),a0
        bsr     puts
        lea     m_sp,a0
        bsr     puts

        clr.w   shapeidx
.shape:
        lea     shapes,a0
        move.w  shapeidx,d0
        lsl.w   #3,d0
        adda.w  d0,a0
        move.l  (a0)+,ringsz                    ; ring size (0 ends the table)
        beq.s   .shapesdone
        move.l  (a0),d7                         ; chunk size
        bsr     verify_ring
        addq.w  #1,shapeidx
        bra.s   .shape
.shapesdone:
        bsr     crlf
        lea     CASE_SIZE(a6),a6
        bra     .case

; --------------------------------------------------------------------- timing
.timing:
        lea     m_calib,a0
        bsr     puts
        bsr     sync
        move.w  #CALIB_OUTER,d7
        bsr     calib
        bsr     elapsed
        move.l  d0,-(sp)
        moveq   #CALIB_OUTER,d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts
        move.l  (sp)+,d0
        bsr     putdec
        bsr     crlf

    .if RINGMOD
        .if RING_SIZE = RING_SMALL
        lea     ring_cases,a6                  ; N=256 requires -m256
        .else
        lea     fair_cases,a6                  ; fair N=1024 comparison
        .endif
    .else
        lea     fair_cases,a6                  ; general timing uses N=1024
    .endif
.tcase:
        tst.l   CASE_NAME(a6)
        beq     .done
    .if RINGMOD
        move.l  #RING_SIZE,ringsz
    .else
        move.l  #RING_BIG,ringsz
    .endif
        moveq   #16,d7
    .if RINGMOD
        .if RING_SIZE <> RING_SMALL
        bsr     verify_ring                    ; verify the exact timed stream
        bsr     crlf
        moveq   #16,d7
        .endif
    .else
        bsr     verify_ring                    ; verify the exact timed stream
        bsr     crlf
        moveq   #16,d7
    .endif
        bsr     time_ring
        lea     CASE_SIZE(a6),a6
        bra     .tcase

.done:
        lea     m_done,a0
        bsr     puts

        move.l  save_ssp,-(sp)                  ; back to user mode
        move.w  #Super,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        clr.w   -(sp)
        trap    #GEMDOS                         ; Pterm0

; -----------------------------------------------------------------------------
; verify_ring: a6 = case, ringsz = ring size, d7.w = chunk size.
; Streams the case through the ring, comparing every drained byte against the
; expected image, and prints "<size>/<chunk>=OK" or "=BAD".
; -----------------------------------------------------------------------------
verify_ring:
        lea     m_r,a0
        bsr     puts
        move.l  ringsz,d0
        bsr     putdec
        lea     m_slash,a0
        bsr     puts
        move.l  d7,d0
        bsr     putdec
        lea     m_eq,a0
        bsr     puts

        bsr     ring_init
        lea     state,a5                        ; a5 is free: no decompressor
                                                ; touches it any more
        clr.w   nshort                          ; short calls seen (before the last)
        clr.b   sizebad
        move.l  ringbase,prev                   ; first undrained byte
        move.l  CASE_EXP(a6),expptr
        move.l  CASE_ELEN(a6),expleft
.loop:
        move.l  #$BEEF0000,d3
        move.l  d3,d4
        move.l  d3,d5
        movea.l d3,a2                           ; poison every scratch register
        move.l  #$D6D61234,d6                   ; d6 is promised untouched
        move.w  d7,d3                           ; d3.w is this call's budget
        bsr     jx1_resume                      ; a1 = write pointer, d1 = result
        cmp.l   #$D6D61234,d6
        bne     .bad
    .if !RINGMOD
        move.l  d1,d4                           ; the general ring's two high
        swap    d4                              ; words are persistent metadata:
        move.l  ringsz,d5                       ; N above remaining
        cmp.w   d5,d4
        bne     .bad
        move.l  d2,d4
        swap    d4                              ; end.low above lastOffset
        move.l  ringend,d5
        cmp.w   d5,d4
        bne     .bad
    .endif
        movem.l d0-d2/a0,(a5)                   ; the parse state is in registers
                                                ; now, and the draining below
                                                ; clobbers a0 for its compare
        move.w  d1,retcode
        move.l  a1,curdst

        move.l  a1,d0
        sub.l   prev,d0                         ; bytes produced by this call
        bsr     check_size
        beq.s   .nodata
        cmp.l   expleft,d0
        bhi     .bad                            ; more output than expected
        sub.l   d0,expleft
        movea.l prev,a0
        movea.l expptr,a1
        move.w  d0,d1                           ; <= chunk, so a word is plenty
        subq.w  #1,d1
.cmp:
        cmpm.b  (a0)+,(a1)+
        bne.s   .bad
        dbf     d1,.cmp
        move.l  a1,expptr
.nodata:
        move.l  curdst,prev
        movea.l curdst,a1                       ; the caller holds the write
        cmpa.l  ringend,a1                      ; pointer now: hand it back
        bne.s   .more                           ; buffer full?
        move.l  ringbase,prev
    .if RINGMOD
        movea.l ringbase,a1                     ; ring_mod does not wrap for us
    .endif
.more:
        movem.l (a5),d0-d2/a0                   ; hand the state back for the
        tst.w   retcode                         ; next call (in memory, not on
        bne     .loop                           ; the stack: .bad leaves early)

        tst.l   expleft                         ; every expected byte accounted
        bne.s   .bad                            ; for?
        tst.b   sizebad
        bne.s   .bad
        tst.w   nshort                           ; report which regime was seen:
        bne.s   .var                             ; every call a full chunk, or
        lea     m_okf,a0                         ; short ones at the wrap
        bra     puts
.var:
        lea     m_okv,a0
        bra     puts
.bad:
        lea     m_bad,a0
        bra     puts

; -----------------------------------------------------------------------------
; check_size: d0 = bytes produced by the call just made. Checks the documented
; per-call contract on hardware: a call leaving d1 nonzero produces exactly the
; chunk size, unless it ran into the end of the buffer - which can only happen
; when the chunk does not divide the buffer. Sets sizebad if that is violated
; and counts the short calls. Preserves d0 (and the flags it sets on it).
; -----------------------------------------------------------------------------
check_size:
        movem.l d0-d2/a0,-(sp)
        tst.w   retcode
        beq.s   .done                           ; the final call may be short
        cmp.l   d7,d0
        bhi.s   .bad                            ; never more than one chunk
        beq.s   .done                           ; a full chunk is always fine
        tst.l   d0
        beq.s   .bad                            ; ...and never nothing
        addq.w  #1,nshort
        movea.l curdst,a0                       ; a short call must sit exactly
        cmpa.l  ringend,a0                      ; at the end of the buffer
        bne.s   .bad
        move.l  ringsz,d1                       ; ...and must not be possible at
        divu.w  d7,d1                           ; all when the chunk divides the
        swap    d1                              ; buffer
        tst.w   d1
        bne.s   .done
.bad:
        st      sizebad
.done:
        movem.l (sp)+,d0-d2/a0
        tst.l   d0                              ; restore the caller's flags
        rts

; ring_init: a6 = case, ringsz = ring size, d7.w = chunk.  The general ABI
; receives one-past-end transiently in d3.l at init, then packs N/end.low into
; d1.high/d2.high. ring_mod receives no bounds, but its storage is aligned to
; its assembly-time power-of-two RING_SIZE.
ring_init:
        movea.l CASE_SRC(a6),a0
    .if RINGMOD
        lea     ring_storage+RING_SIZE-1,a1
        move.l  a1,d0
        and.l   #-RING_SIZE,d0
        movea.l d0,a1
    .else
        lea     ring_storage+1,a1               ; retain odd-base coverage
    .endif
        move.l  a1,ringbase
        movea.l a1,a2
        adda.l  ringsz,a2
        move.l  a2,ringend
    .if RINGMOD
        bsr     jx1_init
    .else
        move.l  a2,d3                           ; end is consumed only at init;
        bsr     jx1_init                        ; resumes need no bound register
    .endif
        rts

; -----------------------------------------------------------------------------
; time_ring: decode the case CASE_ITER times, no draining (the caller's own
; work is not the decompressor's cost), and print
;   "T <name> <ring> <chunk> <iters> <ticks>"
; -----------------------------------------------------------------------------
time_ring:
        lea     m_t,a0
        bsr     puts
        movea.l CASE_NAME(a6),a0
        bsr     puts
        lea     m_sp,a0
        bsr     puts
        move.l  ringsz,d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts
        move.l  d7,d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts
        move.l  CASE_ITER(a6),d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts

        move.l  CASE_ITER(a6),iters
        bsr     sync
.loop:
        bsr     ring_init
.drain:
        move.w  d7,d3                           ; the budget is a parameter now
        bsr     jx1_resume
    .if RINGMOD
        cmpa.l  ringend,a1                      ; a real caller folds this into
        bne.s   .nowrap                         ; the drain branch it already
        movea.l ringbase,a1                     ; has; here it is explicit
.nowrap:
    .endif
        tst.w   d1
        bne.s   .drain
        subq.l  #1,iters
        bne.s   .loop
        bsr     elapsed
        bsr     putdec
        bra     crlf

; ------------------------------------------------------------ the decompressor
    .if RINGMOD
        include "jx1_68000_ring_mod.S"
    .else
        include "jx1_68000_ring.S"
    .endif
        include "hatari_util.inc"

        .data
    .if RINGMOD
m_banner:   dc.b    "JX1 ST RING_MOD TEST",13,10,0
shapes:     dc.l    RING_SIZE,16                    ; every fixed X divides the
            dc.l    RING_SIZE,64                    ; assembly-time power of two
            dc.l    0
    .else
m_banner:   dc.b    "JX1 ST RING TEST",13,10,0
shapes:     dc.l    RING_SMALL,16                   ; dividing and non-dividing
            dc.l    RING_SMALL,127                  ; ratios both allowed here
            dc.l    RING_ODD,16
            dc.l    RING_BIG,16
            dc.l    RING_BIG,127
            dc.l    0
    .endif
m_calib:    dc.b    "CALIB ",0
m_done:     dc.b    "DONE",13,10,0
m_sp:       dc.b    " ",0
m_slash:    dc.b    "/",0
m_okf:      dc.b    "OKf ",0                        ; every call a full chunk
m_okv:      dc.b    "OKv ",0                        ; short calls at the wrap
m_bad:      dc.b    "BAD ",0
m_r:        dc.b    "R",0
m_eq:       dc.b    "=",0
m_t:        dc.b    "T ",0
        even

        include "data.inc"

        .bss
        even
save_ssp:   ds.l    1
iters:      ds.l    1
state:      ds.l    4                           ; d0-d2/a0 across a drain
ringsz:     ds.l    1                           ; ring size retained by the harness
ringbase:   ds.l    1                           ; runtime-selected aligned base
ringend:    ds.l    1                           ; harness drain boundary
prev:       ds.l    1
curdst:     ds.l    1
expptr:     ds.l    1
expleft:    ds.l    1
retcode:    ds.w    1
nshort:     ds.w    1
shapeidx:   ds.w    1
sizebad:    ds.b    1
        even
        even
ring_storage:
            ds.b    RING_BIG*2                  ; room to align an N-byte ring;
        even                                    ; still far below streamed output
        ds.b    4096
stack_top:
