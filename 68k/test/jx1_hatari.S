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
        bsr     run_resume_poison
        move.l  a1,d0                           ; a1 = the end of the output. The
                                                ; context field is not written on
                                                ; the final call: once the state
                                                ; byte says DONE the rest is dead
        sub.l   #dst_buf,d0
        lea     dst_buf,a0
        bra     verify

; run_resume: chunk in d7.b, no poisoning - the timing path, so a measurement
; is the decompressor alone. The state stays in the registers throughout.
run_resume:
        bsr     resume_setup
.loop:
        move.w  d7,d5                           ; the budget is a parameter now
        bsr     jx1_resume
        tst.w   d0
        bne.s   .loop
        rts

; run_resume_poison: the same, but fills the caller-clobbered registers with
; junk before every call. d0/d1/a2 are what the ABI still calls clobbered -
; the parse state lives in a0/a1/d2/d3/d4 between calls now, and d5 is the
; budget - so this is what a legal caller may look like.
run_resume_poison:
        bsr     resume_setup
.loop:
        move.l  #$BEEF0000,d0
        move.l  d0,d1
        movea.l d0,a2
        move.w  d7,d5
        bsr     jx1_resume
        tst.w   d0
        bne.s   .loop
        rts

resume_setup:
        movea.l CASE_SRC(a6),a0
        lea     dst_buf,a1
        bra     jx1_init                        ; tail call: its rts returns

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

; ------------------------------------------------------------ the decompressor
        include "jx1_68000.S"
        include "hatari_util.inc"

        .data
m_banner:   dc.b    "JX1 ST TEST",13,10,0
m_calib:    dc.b    "CALIB ",0
m_done:     dc.b    "DONE",13,10,0
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
iters:      ds.l    1
        even
        even
dst_buf:    ds.b    40000                       ; largest expected output + odd
        even
        ds.b    4096
stack_top:
