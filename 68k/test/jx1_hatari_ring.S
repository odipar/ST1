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
; never wraps inside a call, so a full buffer shows up as a1 == a4.
;
; Every corpus runs through 256- and 1024-byte rings at chunk 16 and 127, and
; is then timed at ring 1024 / chunk 16 against the same calibration loop the
; linear harness uses.
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
        move.l  (a0)+,d6                        ; ring size (0 ends the table)
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

        lea     ring_cases,a6
.tcase:
        tst.l   CASE_NAME(a6)
        beq     .done
        move.l  #RING_BIG,d6
        moveq   #16,d7
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
; verify_ring: a6 = case, d6.l = ring size, d7.w = chunk size.
; Streams the case through the ring, comparing every drained byte against the
; expected image, and prints "<size>/<chunk>=OK" or "=BAD".
; -----------------------------------------------------------------------------
verify_ring:
        lea     m_r,a0
        bsr     puts
        move.l  d6,d0
        bsr     putdec
        lea     m_slash,a0
        bsr     puts
        move.l  d7,d0
        bsr     putdec
        lea     m_eq,a0
        bsr     puts

        bsr     ring_init
        clr.w   nshort                          ; short calls seen (before the last)
        clr.b   sizebad
        move.l  #ring_buf,prev                  ; first undrained byte
        move.l  CASE_EXP(a6),expptr
        move.l  CASE_ELEN(a6),expleft
.loop:
        move.l  #$BEEF0000,d0                   ; the ABI calls d0-d5 clobbered,
        move.l  d0,d1                           ; so a caller may pass anything
        move.l  d0,d2                           ; in them; prove the decoder
        move.l  d0,d3                           ; never reads their upper words
        move.l  d0,d4
        move.l  d0,d5
        bsr     jx1_resume                      ; a1 = write pointer, d0 = 0/1
        move.w  d0,retcode
        move.l  a1,curdst

        move.l  a1,d0
        sub.l   prev,d0                         ; bytes produced by this call
        bsr     check_size
        beq.s   .nodata
        cmp.l   expleft,d0
        bhi.s   .bad                            ; more output than expected
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
        movea.l curdst,a0
        cmpa.l  a4,a0                           ; buffer full? then the next
        bne.s   .more                           ; call restarts at a3
        move.l  a3,prev
.more:
        tst.w   retcode
        bne.s   .loop

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
; per-call contract on hardware: a call that returns 1 produces exactly the
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
        cmpa.l  a4,a0                           ; at the end of the buffer
        bne.s   .bad
        move.l  d6,d1                           ; ...and must not be possible at
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

; ring_init: a6 = case, d6.l = ring size, d7.w = chunk. Leaves a3/a4 as the
; ring bounds (the decompressor never modifies them) and a5 = context.
ring_init:
        movea.l CASE_SRC(a6),a0
        lea     ring_buf,a1
        move.l  d7,d0
        lea     ctx,a5
        bsr     jx1_init
        lea     ring_buf,a3
        movea.l a3,a4
        adda.l  d6,a4
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
        move.l  d6,d0
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
        bsr     jx1_resume
        tst.w   d0
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
shapes:     dc.l    RING_SMALL,16                   ; every shape divides:
            dc.l    RING_SMALL,64                   ; this build requires it
            dc.l    1000,125
            dc.l    1016,127
            dc.l    RING_BIG,16
            dc.l    RING_BIG,64
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
prev:       ds.l    1
curdst:     ds.l    1
expptr:     ds.l    1
expleft:    ds.l    1
retcode:    ds.w    1
nshort:     ds.w    1
shapeidx:   ds.w    1
sizebad:    ds.b    1
        even
ctx:        ds.b    16                          ; jx1 context
        even
ring_buf:   ds.b    RING_BIG                    ; the whole point: far smaller
        even                                    ; than the data streamed through
        ds.b    4096
stack_top:
