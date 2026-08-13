; -----------------------------------------------------------------------------
; jx1_hatari.S - real-hardware validation harness for 68k/jx1_68000.S
;
; A TOS program that decompresses embedded jx1 streams on a real 68000 and
; verifies the output byte-for-byte, then measures decode time with the
; system's 200 Hz tick. Timing is reported in ticks together with a
; calibration loop of exactly known cycle count, so the host can convert
; ticks to cycles without assuming a clock rate or interrupt overhead.
;
; Each case is decompressed one-shot, resumed at chunk 16/127 (and 1 for the
; small ones), and finally one-shot into an ODD destination address - which a
; real 68000 address-errors on if any copy widened to a word, a fault the
; Unicorn-based rig cannot produce.
;
; See README.md in this directory for building, running, and the measured
; results. The build needs rmac's +o3 (see the note there).
; -----------------------------------------------------------------------------

GEMDOS      equ     1
Pterm0      equ     0
Cconws      equ     9
Super       equ     $20
hz200       equ     $4BA            ; 200 Hz system tick (supervisor only)

CASE_NAME   equ     0               ; case table entry layout
CASE_SRC    equ     4
CASE_SLEN   equ     8
CASE_EXP    equ     12
CASE_ELEN   equ     16
CASE_ITER   equ     20
CASE_SIZE   equ     24

CALIB_OUTER equ     12              ; x 655386 cycles = 7.86M, ~197 ticks
BIG         equ     5000            ; above this size, skip the chunk-1 walk

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
        lea     cases,a6
.case:
        tst.l   CASE_NAME(a6)
        beq     .timing

        movea.l CASE_NAME(a6),a0
        bsr     puts
        lea     m_sp,a0
        bsr     puts

        bsr     t_oneshot                       ; one-shot, even destination
        moveq   #16,d7
        bsr     t_resume                        ; resumable, chunk 16
        moveq   #127,d7
        bsr     t_resume                        ; resumable, chunk 127
        move.l  CASE_ELEN(a6),d0
        cmp.l   #BIG,d0
        bhi.s   .noone
        moveq   #1,d7
        bsr     t_resume                        ; resumable, chunk 1
.noone:
        bsr     t_odd                           ; one-shot, ODD destination
        bsr     crlf
        lea     CASE_SIZE(a6),a6
        bra     .case

; --------------------------------------------------------------------- timing
.timing:
        lea     m_calib,a0
        bsr     puts
        bsr     sync                            ; align to a tick edge
        move.w  #CALIB_OUTER,d7
        bsr     calib
        bsr     elapsed
        move.l  d0,d1
        moveq   #CALIB_OUTER,d0
        bsr     putdec                          ; outer count
        lea     m_sp,a0
        bsr     puts
        move.l  d1,d0
        bsr     putdec                          ; ticks
        bsr     crlf

        lea     cases,a6
.tcase:
        tst.l   CASE_NAME(a6)
        beq     .done
        moveq   #16,d7
        bsr     time_case
        moveq   #127,d7
        bsr     time_case
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
; t_oneshot: jx1_decompress into an even destination; verify length + bytes.
; -----------------------------------------------------------------------------
t_oneshot:
        lea     m_c,a0
        bsr     puts
        movea.l CASE_SRC(a6),a0
        lea     dst_buf,a1
        bsr     jx1_decompress
        move.l  a1,d0
        sub.l   #dst_buf,d0                     ; produced length
        lea     dst_buf,a0
        bra     verify

; -----------------------------------------------------------------------------
; t_odd: the same one-shot into an ODD destination address. A real 68000
; address-errors on a misaligned word access, so this proves the copy path
; never widens its byte moves (the emulator cannot catch that).
; -----------------------------------------------------------------------------
t_odd:
        lea     m_odd,a0
        bsr     puts
        movea.l CASE_SRC(a6),a0
        lea     dst_buf+1,a1
        bsr     jx1_decompress
        move.l  a1,d0
        sub.l   #dst_buf+1,d0
        lea     dst_buf+1,a0
        bra     verify

; -----------------------------------------------------------------------------
; t_resume: init + resume loop at chunk d7.b; verify length + bytes.
; -----------------------------------------------------------------------------
t_resume:
        lea     m_r,a0
        bsr     puts
        move.l  d7,d0
        bsr     putdec
        lea     m_eq,a0
        bsr     puts
        bsr     run_resume
        move.l  ctx+8,d0                        ; ctx_dst = current output end
        sub.l   #dst_buf,d0
        lea     dst_buf,a0
        bra     verify

; run_resume: chunk in d7.b. Leaves the context at `ctx` fully written back.
run_resume:
        lea     ctx,a5
        movea.l CASE_SRC(a6),a0
        lea     dst_buf,a1
        move.l  d7,d0
        bsr     jx1_init
.loop:
        bsr     jx1_resume
        tst.w   d0
        bne.s   .loop
        rts

; -----------------------------------------------------------------------------
; verify: a0 = produced buffer, d0 = produced length; compares against the
; case's expected image. Prints "OK" or "BAD".
; -----------------------------------------------------------------------------
verify:
        cmp.l   CASE_ELEN(a6),d0
        bne.s   .bad
        movea.l CASE_EXP(a6),a1
        move.w  d0,d1
        subq.w  #1,d1
.cmp:
        cmpm.b  (a0)+,(a1)+
        bne.s   .bad
        dbf     d1,.cmp
        lea     m_ok,a0
        bra     puts
.bad:
        lea     m_bad,a0
        bra     puts

; -----------------------------------------------------------------------------
; time_case: run the case's resume loop CASE_ITER times at chunk d7, print
;   "T <name> <chunk> <iters> <ticks>"
; -----------------------------------------------------------------------------
time_case:
        lea     m_t,a0
        bsr     puts
        movea.l CASE_NAME(a6),a0
        bsr     puts
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
        bsr     run_resume
        subq.l  #1,iters
        bne.s   .loop
        bsr     elapsed
        bsr     putdec
        bra     crlf

; -----------------------------------------------------------------------------
; calib: d7.w outer passes of an inner dbf loop, exactly 655386 cycles each:
;   move.w #-1,d0 (8) + 65535 taken dbf (10) + 1 expiring dbf (14)
;   + subq.w (4) + bne.s taken (10)
; The last pass ends with a not-taken bne (8), so the total is
;   d7 * 655386 - 2 cycles.
; -----------------------------------------------------------------------------
calib:
.outer:
        move.w  #-1,d0
.inner:
        dbf     d0,.inner
        subq.w  #1,d7
        bne.s   .outer
        rts

; sync: wait for a fresh tick, remember it. elapsed: ticks since then.
sync:
        move.l  hz200,d0
.wait:
        move.l  hz200,d1
        cmp.l   d0,d1
        beq.s   .wait
        move.l  d1,t_start
        rts
elapsed:
        move.l  hz200,d0
        sub.l   t_start,d0
        rts

; ------------------------------------------------------------------- printing
puts:
        move.l  a0,-(sp)
        move.w  #Cconws,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        rts

crlf:
        lea     m_crlf,a0
        bra     puts

; putdec: unsigned long in d0, printed without leading zeros.
putdec:
        movem.l d1-d4/a0,-(sp)
        lea     numbuf+11,a0
        clr.b   -(a0)                           ; NUL terminator
.digit:
        bsr     div10
        add.b   #'0',d1
        move.b  d1,-(a0)
        tst.l   d0
        bne.s   .digit
        bsr     puts
        movem.l (sp)+,d1-d4/a0
        rts

; div10: d0 = value; returns d0 = value/10, d1.w = value%10. Two divu.w
; passes, so the 32-bit quotient never overflows a single divide.
div10:
        move.l  d0,d3
        clr.l   d0
        swap    d3
        move.w  d3,d0                           ; high word
        divu.w  #10,d0                          ; d0 = rem:quot
        move.w  d0,d2                           ; high quotient
        swap    d3                              ; low word back
        move.w  d3,d0                           ; d0 = highrem:low
        divu.w  #10,d0
        move.w  d0,d4                           ; low quotient
        clr.w   d0
        swap    d0                              ; d0.w = remainder
        move.w  d0,d1
        and.l   #$FFFF,d1
        move.w  d2,d0
        swap    d0
        move.w  d4,d0                           ; quotient = high:low
        rts

; ------------------------------------------------------------ the decompressor
        include "jx1_68000.S"

        .data
m_banner:   dc.b    "JX1 ST TEST",13,10,0
m_calib:    dc.b    "CALIB ",0
m_done:     dc.b    "DONE",13,10,0
m_crlf:     dc.b    13,10,0
m_sp:       dc.b    " ",0
m_ok:       dc.b    "OK ",0
m_bad:      dc.b    "BAD ",0
m_c:        dc.b    "C=",0
m_r:        dc.b    "R",0
m_eq:       dc.b    "=",0
m_odd:      dc.b    "ODD=",0
m_t:        dc.b    "T ",0
        even

        include "data.inc"

        .bss
        even
save_ssp:   ds.l    1
t_start:    ds.l    1
iters:      ds.l    1
numbuf:     ds.b    12
        even
ctx:        ds.b    16                          ; jx1 context (15 bytes + pad)
        even
dst_buf:    ds.b    40000                       ; largest expected output + odd
        even
        ds.b    4096
stack_top:
