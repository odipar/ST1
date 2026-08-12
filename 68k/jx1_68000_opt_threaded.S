; -----------------------------------------------------------------------------
; v3_threaded_split.S - v2_threaded_fold.S + specialized mid-op re-entries
;                       + read-only chunk hoisted above the stored fields
;
; A resumed op always has remaining >= 1 (both suspend sites guarantee it)
; and budget = chunk >= 1 on entry, so min() >= 1: the mid-op landings can
; skip the suspend gate AND already know their state, killing the tst.w d4
; select. The threaded entry therefore dispatches to per-state re-entry
; blocks r_lit / r_match, each a gate-less take_budget plus its own source
; setup; d4 keeps carrying the displacement (base = r_match, so MATCH = 0
; and the body's tst.w d4 state tests are unchanged from v2). The generic
; resume_op (with the folded gate) now serves only ops started inside a
; call, where the budget really can be 0.
;
; Context relayout: disp word at 12, bit buffer widened to a WORD at 14
; (the queue lives in the low byte; the high byte is dead pad that rides
; along in d2's bits 8-15, which nothing reads), chunk word at 16. All
; three entry loads are then sequential move.w (a5)+ (entry 90 -> 74
; cycles), and since the read-only chunk sits on top, suspend's stores are
; two pure predecrement words plus the movem - no subq (76 -> 68 cycles).
; ctx_src stays at 4, ctx_dst at 8; alloc stays 18.
; -----------------------------------------------------------------------------

ctx_packed      equ     0               ; .l  d3: lastOffset (high), remaining (low)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_disp        equ     12              ; .w  resume displacement (doubles as state)
ctx_bitsw       equ     14              ; .w  bit buffer in the low byte, pad high
ctx_chunk       equ     16              ; .w  chunkSize (X), 1..127, high byte 0
ctx_size        equ     18              ; a5 parks at ctx_chunk between entry
ctx_alloc       equ     18              ; and suspend

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.b = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        and.w   #$7f,d0                 ; chunk as a word with a clean high byte
        move.w  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.w  #(begin_literals-r_match),ctx_disp(a5) ; START
        move.w  #$0080,ctx_bitsw(a5)    ; empty bit buffer (sentinel only)
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; -----------------------------------------------------------------------------
jx1_decompress:
        move.l  a5,-(sp)
        lea     -ctx_alloc(sp),sp
        movea.l sp,a5
        moveq   #127,d0                 ; largest chunk a byte allows
        bsr.s   jx1_init
.drain:
        bsr.s   jx1_resume
        tst.w   d0
        bne.s   .drain
        lea     ctx_alloc(sp),sp
        movea.l (sp)+,a5
        rts

; get_gamma: interlaced Elias gamma value in d1.w. Unchanged from opt7.
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2
        addx.b  d2,d2
gamma_first:
        bcc.s   gamma_done
gamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   gamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
gamma_have:
        bcs.s   gamma_loop
gamma_done:
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes.
; Returns d0 = 0 when fully processed, 1 when there is more.
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        move.w  (a5)+,d4                ; state displacement
        move.w  (a5)+,d2                ; bit buffer (low byte; pad rides high)
        move.w  (a5),d5                 ; budget = chunkSize; a5 parks on it
        jmp     r_match(pc,d4.w)        ; threaded dispatch

r_lit:                                  ; LITERALS mid-op re-entry: remaining
        move.w  d3,d0                   ; and budget are both >= 1, so no
        cmp.w   d5,d0                   ; suspend gate, and the state select
        bls.s   .fit                    ; is pre-folded
        move.w  d5,d0
.fit:
        sub.w   d0,d3
        sub.w   d0,d5
        movea.l a0,a2                   ; literals copy straight from the input
        bra.s   source_ready
r_match:                                ; MATCH mid-op re-entry (disp 0, base)
        move.w  d3,d0
        cmp.w   d5,d0
        bls.s   .fit
        move.w  d5,d0
.fit:
        sub.w   d0,d3
        sub.w   d0,d5
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3
        suba.w  d3,a2
        swap    d3
        bra.s   source_ready

begin_literals:
        moveq   #(r_lit-r_match),d4     ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        movea.l a0,a2                   ; literals source (dead if we suspend)
resume_op:                              ; ops started inside this call only
        move.w  d3,d0                   ; take_budget: min(remaining, budget);
        cmp.w   d5,d0                   ; d3 >= 1 always, so d0 = 0 only via
        bls.s   budget_fits             ; the clip with d5 = 0
        move.w  d5,d0                   ; (sets Z from d5)
        beq.w   suspend                 ; budget exhausted before this op
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d4                      ; 0 = match, else literals
        bne.s   source_ready            ; literals: a2 already = input
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3
        suba.w  d3,a2
        swap    d3
source_ready:                           ; n moves total: partial first pass of
        move.w  d0,d1                   ; n&7 entered mid-ladder, then n>>3
        lsr.w   #3,d1                   ; full passes off the dbf
        and.w   #7,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        jmp     ladder_end(pc,d0.w)
ladder:
        move.b  (a2)+,(a1)+             ; 8 fully rolled-out byte moves
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
ladder_end:
        dbf     d1,ladder
copy_done:
        tst.w   d4
        beq.s   copied                  ; matches consume no input here;
        movea.l a2,a0                   ; literals do
copied:
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        tst.w   d4                      ; state test BEFORE the bit read: tst
        bne.s   literals_transition     ; must not clobber the bit in carry
        add.b   d2,d2                   ; case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:
        moveq   #0,d4                   ; State.MATCH (= disp 0)
        moveq   #0,d3                   ; old offset and remaining are both dead
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects two-byte form
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
        add.b   d2,d2                   ; case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #0,d4                   ; 0: State.MATCH from last offset
        bsr.w   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op

suspend:                                ; a5 parked at ctx_chunk; the stored
        move.w  d2,-(a5)                ; fields sit contiguously below it:
        move.w  d4,-(a5)                ; bits word, disp, then the movem trio
        movem.l d3/a0-a1,-(a5)          ; a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:
        move.w  d2,-(a5)
        move.w  #(done_stub-r_match),-(a5) ; State.DONE
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts

done_stub:                              ; DONE resumes land here
        lea     -ctx_chunk(a5),a5       ; restore a5 = context base
        moveq   #0,d0                   ; keep returning "fully processed"
        rts
