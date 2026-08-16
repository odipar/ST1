; -----------------------------------------------------------------------------
; ST1_wrap_test.S - real-hardware validation for 68k/ST1_wrap.S
;
; Tests the counted-wrap contract at N=1024 and C=16 on the same -m1024
; streams used for the fair linear/general-ring comparison. The caller knows O,
; makes T=ceil(O/C) calls, and resets a1 after F=N/C continuing calls. Every
; returned byte is compared as it is drained; nothing larger than N is kept.
; -----------------------------------------------------------------------------

GEMDOS      equ     1
Pterm0      equ     0
Cconws      equ     9
Super       equ     $20
hz200       equ     $4BA

CASE_NAME   equ     0
CASE_SRC    equ     4
CASE_SLEN   equ     8
CASE_EXP    equ     12
CASE_ELEN   equ     16
CASE_ITER   equ     20
CASE_SIZE   equ     24

CALIB_OUTER equ     12
N           equ     1024
C           equ     16
F           equ     N/C

        .text

start:
        move.l  #stack_top,-(sp)
        move.w  #Super,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        move.l  d0,save_ssp

        lea     m_banner,a0
        bsr     puts

; ---------------------------------------------------------------- correctness
        lea     fair_cases,a6
.case:
        tst.l   CASE_NAME(a6)
        beq.s   .timing
        movea.l CASE_NAME(a6),a0
        bsr     puts
        lea     m_sp,a0
        bsr     puts
        bsr     verify_wrap
        bsr     crlf
        lea     CASE_SIZE(a6),a6
        bra.s   .case

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

        lea     fair_cases,a6
.tcase:
        tst.l   CASE_NAME(a6)
        beq.s   .done
        bsr     verify_wrap                    ; verify the exact timed stream
        bsr     crlf
        bsr     time_wrap
        lea     CASE_SIZE(a6),a6
        bra.s   .tcase

.done:
        lea     m_done,a0
        bsr     puts
        move.l  save_ssp,-(sp)
        move.w  #Super,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        clr.w   -(sp)
        trap    #GEMDOS

; -----------------------------------------------------------------------------
; setup_wrap: a6 = case. Initializes ST1 and the caller's F/T counters.
; -----------------------------------------------------------------------------
setup_wrap:
        movea.l CASE_SRC(a6),a0
        lea     ring_storage+1,a1              ; odd and deliberately unaligned
        move.l  a1,ringbase
        movea.l a1,a3                          ; a3 is the preserved wrap target
        lea     N(a1),a2
        move.l  a2,ringend
        move.w  #N,d3                          ; init takes runtime N
        bsr     ST1_init
        moveq   #F,d6                          ; calls until destination wrap
        move.l  CASE_ELEN(a6),d7
        add.l   #C-1,d7
        lsr.l   #4,d7                          ; T = ceil(O/C), C is 16
        rts

; -----------------------------------------------------------------------------
; verify_wrap: compare the complete O-byte result while streaming through N.
; -----------------------------------------------------------------------------
verify_wrap:
        lea     m_shape,a0
        bsr     puts
        bsr     setup_wrap
        lea     state,a5
        move.l  ringbase,prev
        move.l  CASE_EXP(a6),expptr
        move.l  CASE_ELEN(a6),expleft
.loop:
        move.l  #$BEEF0000,d3
        move.l  d3,d4
        move.l  d3,d5
        movea.l d3,a2                           ; poison all scratch registers
        move.w  #C,d3
        bsr     ST1_resume

        move.l  d1,d4                           ; d1.high = -ring_start.low
        swap    d4
        move.l  ringbase,d5
        neg.w   d5
        cmp.w   d5,d4
        bne     .bad
        move.l  d2,d4                           ; d2.high = N
        swap    d4
        cmp.w   #N,d4
        bne     .bad

        movem.l d0-d2/a0,(a5)
        move.l  a1,curdst
        move.l  a1,d0
        sub.l   prev,d0                         ; bytes returned by this call
        cmp.l   #C,d0
        bhi     .bad
        move.l  expleft,d4                      ; known O controls span length
        cmpi.l  #C,d4
        bls.s   .sizeok
        moveq   #C,d4
.sizeok:
        cmp.l   d4,d0
        bne     .bad
        tst.l   d0
        beq.s   .nodata
        cmp.l   expleft,d0
        bhi.s   .bad
        sub.l   d0,expleft
        movea.l prev,a0
        movea.l expptr,a1
        move.w  d0,d1
        subq.w  #1,d1
.compare:
        cmpm.b  (a0)+,(a1)+
        bne.s   .bad
        dbf     d1,.compare
        move.l  a1,expptr
.nodata:
        move.l  curdst,prev
        movea.l curdst,a1
        movem.l (a5),d0-d2/a0

        subq.l  #1,d7                           ; known T controls completion
        beq.s   .last
        subq.w  #1,d6
        bne     .loop
        cmpa.l  ringend,a1                      ; exactly F full calls
        bne.s   .bad
        movea.l a3,a1                           ; caller performs the wrap
        move.l  a3,prev
        moveq   #F,d6
        bra     .loop
.last:
        tst.l   expleft
        bne.s   .bad
        lea     m_ok,a0
        bra     puts
.bad:
        lea     m_bad,a0
        bra     puts

; -----------------------------------------------------------------------------
; run_wrap: timed caller. totalcalls and a3 are prepared outside the measured
; loop. Its F/T counters are caller work; draining is application-specific and
; excluded, as in the other two timing harnesses.
; -----------------------------------------------------------------------------
run_wrap:
        movea.l CASE_SRC(a6),a0
        movea.l a3,a1
        move.w  #N,d3
        moveq   #F,d6
        move.l  totalcalls,d7
        bsr     ST1_init
.drain:
        moveq   #C,d3
        bsr     ST1_resume
        subq.l  #1,d7
        beq.s   .decoded
        subq.w  #1,d6
        bne.s   .drain
        movea.l a3,a1
        moveq   #F,d6
        bra.s   .drain
.decoded:
        rts

; -----------------------------------------------------------------------------
; time_wrap: print "T <name> <N> <C> <iters> <ticks>".
; -----------------------------------------------------------------------------
time_wrap:
        lea     m_t,a0
        bsr     puts
        movea.l CASE_NAME(a6),a0
        bsr     puts
        lea     m_sp,a0
        bsr     puts
        move.l  #N,d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts
        moveq   #C,d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts
        move.l  CASE_ITER(a6),d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts

        move.l  CASE_ELEN(a6),d0
        add.l   #C-1,d0
        lsr.l   #4,d0
        move.l  d0,totalcalls
        lea     ring_storage+1,a3              ; known N/base, outside timing
        move.l  CASE_ITER(a6),iters
        bsr     sync
.loop:
        bsr     run_wrap
        subq.l  #1,iters
        bne.s   .loop
        bsr     elapsed
        bsr     putdec
        bra     crlf

; ------------------------------------------------------------ the decompressor
        include "ST1_wrap.S"
        include "hatari_util.inc"

        .data
m_banner:   dc.b    "ST1 WRAP TEST",13,10,0
m_calib:    dc.b    "CALIB ",0
m_done:     dc.b    "DONE",13,10,0
m_sp:       dc.b    " ",0
m_shape:    dc.b    "N1024/C16=",0
m_ok:       dc.b    "OK ",0
m_bad:      dc.b    "BAD ",0
m_t:        dc.b    "T ",0
        even

        include "data.inc"

        .bss
        even
save_ssp:   ds.l    1
iters:      ds.l    1
totalcalls: ds.l    1
state:      ds.l    4
ringbase:   ds.l    1
ringend:    ds.l    1
prev:       ds.l    1
curdst:     ds.l    1
expptr:     ds.l    1
expleft:    ds.l    1
        even
ring_storage:
            ds.b    N+1
        even
            ds.b    4096
stack_top:
