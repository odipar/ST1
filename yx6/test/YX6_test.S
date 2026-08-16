; -----------------------------------------------------------------------------
; YX6_test.S - real-hardware validation for yx6/YX6.S.
;
; Plays an embedded tune on the actual sound chip and reads every register back
; after every frame, folding the chip's contents into a checksum that the host
; computed from the YM data alone. That covers what emulation cannot: the
; player is writing to a real YM2149 through real bus cycles, and a wrong
; register number or a missed write changes the checksum.
;
; Then it plays the tune again, untimed by read-back, and reports the ticks it
; took - the number the README asks you to measure with your own tune.
;
; Output: "SUM=OK" or "SUM=BAD", "T <frames> <ticks>", "CALIB <n> <ticks>", DONE.
; -----------------------------------------------------------------------------

GEMDOS      equ     1
Pterm0      equ     0
Cconws      equ     9
Super       equ     $20
hz200       equ     $4BA

CALIB_OUTER equ     12
PSG         equ     $FFFF8800

        .text

start:
        move.l  #stack_top,-(sp)
        move.w  #Super,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        move.l  d0,save_ssp

        lea     m_banner,a0
        bsr     puts

; ------------------------------------------------- the chip gets the right YM
        lea     m_sum,a0
        bsr     puts
        lea     song,a0
        lea     workspace,a1
        bsr     YX6_init
        tst.l   d0
        bne     .bad

        moveq   #0,d7                           ; the running checksum
        move.l  #YX6_FRAMES,d6                  ; frames left to play
.frame:
        lea     workspace,a0
        bsr     YX6_play
        tst.l   d0
        bne.s   .bad                            ; ended early: the count is wrong
        bsr     fold_chip
        subq.l  #1,d6
        bne.s   .frame

        lea     workspace,a0                    ; one more call must report the
        bsr     YX6_play                        ; end and touch nothing
        cmp.l   #1,d0
        bne.s   .bad
        cmp.l   #YX6_SUM,d7
        bne.s   .bad
        lea     m_ok,a0
        bsr     puts
        bra.s   .timing
.bad:
        lea     m_bad,a0
        bsr     puts

; ------------------------------------------------------- what a frame costs
.timing:
        bsr     crlf
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

        lea     song,a0
        lea     workspace,a1
        bsr     YX6_init
        lea     m_t,a0
        bsr     puts
        move.l  #YX6_FRAMES,d0
        bsr     putdec
        lea     m_sp,a0
        bsr     puts

        move.l  #YX6_FRAMES,d6
        bsr     sync
.play:
        lea     workspace,a0
        bsr     YX6_play
        subq.l  #1,d6
        bne.s   .play
        bsr     elapsed
        bsr     putdec
        bsr     crlf
        bsr     YX6_stop

        lea     m_done,a0
        bsr     puts
        move.l  save_ssp,-(sp)
        move.w  #Super,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        clr.w   -(sp)
        trap    #GEMDOS

; -----------------------------------------------------------------------------
; fold_chip: read all fourteen sound registers back off the chip and fold them
; into d7. Every register is written every frame except R13 on a frame that
; leaves the envelope alone, so the read-back is defined from frame 0 on - the
; tune writes a shape in its first frame.
; -----------------------------------------------------------------------------
fold_chip:
        movem.l d0-d2/a0,-(sp)
        lea     PSG,a0
        moveq   #0,d0                           ; register number
        moveq   #13,d1
.read:
        move.b  d0,(a0)                         ; select
        moveq   #0,d2
        move.b  (a0),d2                         ; and read it back
        rol.l   #1,d7
        eor.l   d2,d7
        addq.b  #1,d0
        dbf     d1,.read
        movem.l (sp)+,d0-d2/a0
        rts

; ------------------------------------------------------------------ the library
; puts, crlf, putdec, sync, elapsed and calib come from the shared harness
; helpers, the same ones the ST1 hardware tests use.
        include "YX6.S"
        include "ST1_wrap.S"
        include "hatari_util.inc"

        .data
m_banner:   dc.b    "YX6 TEST",13,10,0
m_sum:      dc.b    "SUM=",0
m_ok:       dc.b    "OK ",0
m_bad:      dc.b    "BAD ",0
m_calib:    dc.b    "CALIB ",0
m_t:        dc.b    "T ",0
m_sp:       dc.b    " ",0
m_done:     dc.b    "DONE",13,10,0
        even

        include "yx6data.inc"

        .bss
        even
save_ssp:   ds.l    1
; The parentheses matter: rmac evaluates expressions strictly left to right.
workspace:  ds.b    YX6_FIXED+(YX6_STREAMS*RING_SIZE)
        even
            ds.b    4096
stack_top:
