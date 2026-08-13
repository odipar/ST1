; -----------------------------------------------------------------------------
; jx1_g_t0r.S - jx1_g_t0.S + out-of-line mid-gamma refill (beq-rotated)
;
; jx1_68000_opt7.S with one addition: when get_gamma's first (peeled)
; continuation bit finds the queue empty - i.e. the gamma starts exactly at
; a byte boundary, ~26% of gammas on parse-heavy data - the whole fresh byte
; is decoded in a single lookup of a 512-byte table T0 indexed by the raw
; input byte. T0[2b] is the complete gamma value (1..15, gammas of up to 7
; bits always fit the byte); T0[2b+1] is the queue byte left after it.
; Gammas longer than the byte (the 16 bytes with b&$AA==$AA) store 0 in the
; value slot and the 5-bit partial value 16+raw in the queue slot; the big
; path re-enters the bitwise pair loop at the next byte, which by the opt3
; invariant starts with the gamma's next continuation bit.
; The pair loop's continuation read is also rotated: the refill moves out
; of line behind a beq, so the common non-refill read pays a not-taken beq
; (8) instead of a taken bne (10); the refill path pays +2. Refills hit at
; most 1 in 4 continuation reads, so the trade is ~3:1 favorable.
; get_gamma moves to the end of the code so the lookups reach T0 with
; short pc-relative indexed addressing (no base register, no per-call lea).
; Queue-resident gamma starts and mid-gamma refills stay bitwise: measured
; distributions (word-soup: k=2..3 dominant, post-peel queue occupancy
; uniform over {1,3,5,7}) make queue-indexed full-decode LUTs a net loss.
;
; Same assumptions as jx1_68000_opt7.S, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;

; The context must be word-aligned and is 15 bytes (16 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context untouched; jx1_decompress additionally uses (but restores)
; a5. (As in opt3, d4 carries the op state.)
; -----------------------------------------------------------------------------

ctx_packed      equ     0               ; .l  d3: lastOffset (high word), remaining (low word)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .b  chunkSize (X), 1..127
ctx_bits        equ     13              ; .b  bit buffer
ctx_state       equ     14              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     15
ctx_alloc       equ     16              ; ctx_size rounded up to keep sp even

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        move.b  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        clr.b   ctx_state(a5)           ; State.START
        rts

jx1_decompress:
        move.l  a5,-(sp)
        lea     -ctx_alloc(sp),sp
        movea.l sp,a5
        moveq   #127,d0                 ; largest chunk a byte allows
        bsr.s   jx1_init
.drain:
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d0
        bne.s   .drain
        lea     ctx_alloc(sp),sp
        movea.l (sp)+,a5
        rts

jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        moveq   #0,d5
        move.b  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.b  (a5),d4                 ; op state (Java: switch in next())
        beq.s   begin_literals          ; START: the stream opens with literals
        cmp.b   #3,d4
        bne.s   resume_op               ; LITERALS or MATCH, mid-op
        lea     -ctx_state(a5),a5       ; DONE: keep returning "fully processed"
        moveq   #0,d0
        rts

begin_literals:                         ; Java: beginLiterals()
        moveq   #1,d4                   ; State.LITERALS
        bsr.w   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched

resume_op:                              ; shared for literals and match; d4 = state
        move.w  d3,d0                   ; take_budget: min(remaining, budget),
        cmp.w   d5,d0                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d0
        beq.w   suspend                 ; budget exhausted before this op
        movea.l a0,a2                   ; literals copy straight from the input
        cmp.b   #1,d4
        beq.s   source_ready
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3
        suba.w  d3,a2
        swap    d3
source_ready:                           ; Java: writeByte(...) - n moves total
        move.w  d0,d1
        lsr.w   #3,d1
        and.w   #7,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        jmp     ladder_end(pc,d0.w)     ; pc-relative dispatch, no base register
ladder:
        move.b  (a2)+,(a1)+             ; 8 fully rolled-out byte moves; entry
        move.b  (a2)+,(a1)+             ; at ladder_end-2k copies exactly k
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
ladder_end:
        dbf     d1,ladder               ; full 8-move passes for big copies
copy_done:
        cmp.b   #1,d4
        bne.s   copied                  ; matches consume no input here;
        movea.l a2,a0                   ; literals do
copied:
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        cmp.b   #1,d4                   ; state test BEFORE the bit read: cmp
        beq.s   literals_transition     ; must not clobber the bit in carry
        add.b   d2,d2                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        moveq   #2,d4                   ; State.MATCH
        moveq   #0,d3                   ; old offset and remaining are both dead here
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        bra.s   got_offset
two_byte:
        add.b   d3,d3                   ; low & 254
        moveq   #0,d0
        move.b  (a0)+,d0
        lsr.b   #1,d0                   ; d0 = high >> 1, carry = high & 1
        bcc.s   no_carry
        addq.w  #1,d3
no_carry:
        lsl.w   #8,d0
        add.w   d0,d3                   ; (high>>1)*256 + (low&254) + (high&1)
        neg.w   d3
        add.w   #32512,d3               ; offset = 32512 - that
        ble.s   end_marker              ; offset <= 0 is the end marker
got_offset:
        swap    d3                      ; park the new offset in the high word
        bsr.w   get_gamma
        addq.w  #1,d1                   ; remaining = gamma + 1
        move.w  d1,d3
        bra.w   resume_op

literals_transition:
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset()
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op

suspend:                                ; Java: resume() returning true
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #1,a5                   ; skip ctx_chunk
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:                             ; Java: State.DONE
        moveq   #3,d0
        move.b  d0,(a5)
        move.b  d2,-(a5)
        subq.l  #1,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts

; get_gamma: interlaced Elias gamma value in d1.w (assumption: fits a word).
; As opt7, except a queue-empty FIRST continuation bit (the gamma starts on
; a byte boundary) decodes the entire fresh byte through T0 in one lookup.
; Mid-gamma refills keep opt7's inline addx refill. Placed last so the T0
; lookups are short pc-relative. Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit
        beq.s   gamma_rf0               ; queue empty: byte-aligned gamma, use T0
        bcc.s   gamma_done              ; 0: value is 1, straight through
gamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        add.b   d2,d2                   ; next continuation bit (refill site)
        beq.s   gamma_mrf               ; queue drained: refill out of line
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        rts
gamma_mrf:                              ; X = 1: the emptying shift pushed out
        move.b  (a0)+,d2                ; the sentinel (Bcc leaves X alone)
        addx.b  d2,d2
        bcs.s   gamma_loop
        rts

gamma_rf0:                              ; whole gamma read from one fresh byte
        moveq   #0,d0
        move.b  (a0)+,d0
        add.w   d0,d0                   ; index = 2*byte (T0 entries are pairs)
        move.b  T0(pc,d0.w),d1          ; complete value 1..15, or 0 = longer
        beq.s   gamma_big
        move.b  T0+1(pc,d0.w),d2        ; queue byte left after the gamma
        rts
gamma_big:                              ; b&$AA==$AA: 4 pairs consumed, more follow
        move.b  T0+1(pc,d0.w),d1        ; partial value 16+raw4 (d1 high byte is 0)
        move.b  (a0)+,d2                ; next byte opens on the 5th continuation
        add.b   d2,d2                   ; bit (opt3 invariant: refills land on
        bcs.s   gamma_big2              ; continuation bits); carry = that bit
        addq.b  #1,d2                   ; 0: gamma complete, restore sentinel
        rts
gamma_big2:
        addq.b  #1,d2                   ; 1: sentinel, then pairs continue bitwise
        bra.s   gamma_loop

; T0: for byte b consumed at a byte-aligned gamma start (bit 7 = first
; continuation bit): T0[2b] = gamma value if complete inside b, else 0;
; T0[2b+1] = remaining queue (complete) or partial value 16+raw (longer).
T0:
        dc.b    $01,$01,$01,$03,$01,$05,$01,$07,$01,$09,$01,$0b,$01,$0d,$01,$0f
        dc.b    $01,$11,$01,$13,$01,$15,$01,$17,$01,$19,$01,$1b,$01,$1d,$01,$1f
        dc.b    $01,$21,$01,$23,$01,$25,$01,$27,$01,$29,$01,$2b,$01,$2d,$01,$2f
        dc.b    $01,$31,$01,$33,$01,$35,$01,$37,$01,$39,$01,$3b,$01,$3d,$01,$3f
        dc.b    $01,$41,$01,$43,$01,$45,$01,$47,$01,$49,$01,$4b,$01,$4d,$01,$4f
        dc.b    $01,$51,$01,$53,$01,$55,$01,$57,$01,$59,$01,$5b,$01,$5d,$01,$5f
        dc.b    $01,$61,$01,$63,$01,$65,$01,$67,$01,$69,$01,$6b,$01,$6d,$01,$6f
        dc.b    $01,$71,$01,$73,$01,$75,$01,$77,$01,$79,$01,$7b,$01,$7d,$01,$7f
        dc.b    $01,$81,$01,$83,$01,$85,$01,$87,$01,$89,$01,$8b,$01,$8d,$01,$8f
        dc.b    $01,$91,$01,$93,$01,$95,$01,$97,$01,$99,$01,$9b,$01,$9d,$01,$9f
        dc.b    $01,$a1,$01,$a3,$01,$a5,$01,$a7,$01,$a9,$01,$ab,$01,$ad,$01,$af
        dc.b    $01,$b1,$01,$b3,$01,$b5,$01,$b7,$01,$b9,$01,$bb,$01,$bd,$01,$bf
        dc.b    $01,$c1,$01,$c3,$01,$c5,$01,$c7,$01,$c9,$01,$cb,$01,$cd,$01,$cf
        dc.b    $01,$d1,$01,$d3,$01,$d5,$01,$d7,$01,$d9,$01,$db,$01,$dd,$01,$df
        dc.b    $01,$e1,$01,$e3,$01,$e5,$01,$e7,$01,$e9,$01,$eb,$01,$ed,$01,$ef
        dc.b    $01,$f1,$01,$f3,$01,$f5,$01,$f7,$01,$f9,$01,$fb,$01,$fd,$01,$ff
        dc.b    $02,$04,$02,$0c,$02,$14,$02,$1c,$02,$24,$02,$2c,$02,$34,$02,$3c
        dc.b    $02,$44,$02,$4c,$02,$54,$02,$5c,$02,$64,$02,$6c,$02,$74,$02,$7c
        dc.b    $02,$84,$02,$8c,$02,$94,$02,$9c,$02,$a4,$02,$ac,$02,$b4,$02,$bc
        dc.b    $02,$c4,$02,$cc,$02,$d4,$02,$dc,$02,$e4,$02,$ec,$02,$f4,$02,$fc
        dc.b    $04,$10,$04,$30,$04,$50,$04,$70,$04,$90,$04,$b0,$04,$d0,$04,$f0
        dc.b    $08,$40,$08,$c0,$00,$10,$00,$11,$09,$40,$09,$c0,$00,$12,$00,$13
        dc.b    $05,$10,$05,$30,$05,$50,$05,$70,$05,$90,$05,$b0,$05,$d0,$05,$f0
        dc.b    $0a,$40,$0a,$c0,$00,$14,$00,$15,$0b,$40,$0b,$c0,$00,$16,$00,$17
        dc.b    $03,$04,$03,$0c,$03,$14,$03,$1c,$03,$24,$03,$2c,$03,$34,$03,$3c
        dc.b    $03,$44,$03,$4c,$03,$54,$03,$5c,$03,$64,$03,$6c,$03,$74,$03,$7c
        dc.b    $03,$84,$03,$8c,$03,$94,$03,$9c,$03,$a4,$03,$ac,$03,$b4,$03,$bc
        dc.b    $03,$c4,$03,$cc,$03,$d4,$03,$dc,$03,$e4,$03,$ec,$03,$f4,$03,$fc
        dc.b    $06,$10,$06,$30,$06,$50,$06,$70,$06,$90,$06,$b0,$06,$d0,$06,$f0
        dc.b    $0c,$40,$0c,$c0,$00,$18,$00,$19,$0d,$40,$0d,$c0,$00,$1a,$00,$1b
        dc.b    $07,$10,$07,$30,$07,$50,$07,$70,$07,$90,$07,$b0,$07,$d0,$07,$f0
        dc.b    $0e,$40,$0e,$c0,$00,$1c,$00,$1d,$0f,$40,$0f,$c0,$00,$1e,$00,$1f
