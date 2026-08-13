; -----------------------------------------------------------------------------
; hatari_util.inc - console and timing helpers shared by the ST harnesses.
;
; Provides: puts (a0 = NUL-terminated string), crlf, putdec (d0 = unsigned
; long), sync/elapsed (200 Hz tick bracketing) and calib (a loop of exactly
; known cycle count, so the host can convert ticks to cycles without
; assuming a clock rate). Include AFTER the program's own code.
; -----------------------------------------------------------------------------

puts:
        move.l  a0,-(sp)
        move.w  #Cconws,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        rts

crlf:
        lea     u_crlf,a0
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

; sync: wait for a fresh tick and remember it. elapsed: ticks since then.
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

; calib: d7.w outer passes of an inner dbf loop, exactly 655386 cycles each:
;   move.w #-1,d0 (8) + 65535 taken dbf (10) + 1 expiring dbf (14)
;   + subq.w (4) + bne.s taken (10)
; The last pass ends with a not-taken bne (8), so the total is
;   d7 * 655386 - 2 cycles.
calib:
.outer:
        move.w  #-1,d0
.inner:
        dbf     d0,.inner
        subq.w  #1,d7
        bne.s   .outer
        rts

        .data
u_crlf:     dc.b    13,10,0
        even

        .bss
        even
t_start:    ds.l    1
numbuf:     ds.b    12
        even
