; -----------------------------------------------------------------------------
; jx1_wc3.S - wildcard variant 3: jx1_wc2.S + per-state copy engines
;
; Everything from jx1_wc2.S (state re-encoding 0/2/$80/$FF, reordered context
; tail with predec suspend, remaining>=1 take_budget, gamma woven into the
; flow), plus the copy path splits per op state AFTER the shared pass-size
; computation:
;
; * literals get their own ladder reading (a0)+ directly - the movea.l a0,a2
;   staging and the post-copy movea.l a2,a0 sync both die, and so does the
;   post-copy discrimination: each ladder falls into its own tail.
; * matches keep the a2 ladder; the offset subtraction moves inside the
;   match fork. The single remaining state test is one tst.b d4 per pass.
; * the pass-size mask #7 lives in d7, preloaded once per call
;   (and.w d7,d0 is 4 cycles vs and.w #7,d0 at 8, every pass).
;
; Costs ~30 bytes for the second ladder; kills 26 (literals) / 20 (match)
; cycles per copy pass on top of wc2.
;
; State encodings in the context changed; layout offsets 4/8 (src/dst) kept.
; Calling convention: clobbers d0-d5/d7/a0-a2 (d7 is new), a5 preserved.
; -----------------------------------------------------------------------------

ctx_packed      equ     0               ; .l  d3: lastOffset (high), remaining (low)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_state       equ     12              ; .b  State: $80 START, 0 LITERALS, 2 MATCH, $FF DONE
ctx_bits        equ     13              ; .b  bit buffer
ctx_chunk       equ     14              ; .b  chunkSize (X), 1..127
ctx_size        equ     15
ctx_alloc       equ     16              ; rounded up to keep sp even

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
        move.b  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        move.b  #$80,ctx_state(a5)      ; State.START
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
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

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes.
; Returns d0 = 0 when the stream is fully processed, 1 when there is more.
; -----------------------------------------------------------------------------
jx1_resume:
        moveq   #0,d5
        moveq   #7,d7                   ; pass-size mask, live for the whole call
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        move.b  (a5)+,d4                ; op state FIRST: its flags feed the dispatch
        bmi.s   entry_slow              ; negative = START or DONE (rare)
        move.b  (a5)+,d2                ; bit buffer
        move.b  (a5),d5                 ; budget = chunkSize; a5 parked on ctx_chunk
        bra.s   resume_op               ; LITERALS or MATCH, mid-op

entry_slow:
        add.b   d4,d4                   ; $80 START -> 0 (Z), $FF DONE -> $FE
        bne.s   entry_done
        move.b  (a5)+,d2
        move.b  (a5),d5
        bra.s   begin_literals          ; START: the stream opens with literals
entry_done:
        lea     -13(a5),a5              ; a5 was parked one past ctx_state
        moveq   #0,d0                   ; DONE: keep returning "fully processed"
        rts

begin_literals:
        moveq   #0,d4                   ; State.LITERALS
        moveq   #0,d0                   ; remaining = gamma + 0
                                        ; falls into get_gamma

; get_gamma: interlaced Elias gamma, then remaining = value + d0, then
; falls into resume_op. Entered with d0 = 0 or 1 (the new-offset +1).
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2                ; refill; ZX1 bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see jx1_68000_opt3.S)
gamma_first:
        bcc.s   gamma_done              ; 0: value is 1, straight through
gamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   gamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
gamma_have:
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        add.w   d0,d1                   ; + caller's seed (1 for new-offset match)
        move.w  d1,d3                   ; remaining; lastOffset (high) untouched
                                        ; falls into resume_op

resume_op:                              ; shared for literals and match; d4 = state
        move.w  d3,d0                   ; take_budget: min(remaining, budget).
        cmp.w   d5,d0                   ; remaining >= 1 here always, so only the
        bls.s   budget_fits             ; clamped path can produce zero:
        move.w  d5,d0                   ; (move sets Z)
        beq.w   suspend                 ; budget exhausted before this op
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        move.w  d0,d1                   ; n moves total: partial first pass of
        lsr.w   #3,d1                   ; n&7 entered mid-ladder, then n>>3 full
        and.w   d7,d0                   ; passes off the dbf
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        tst.b   d4                      ; the ONLY per-pass state test
        bne.s   match_source
        jmp     lit_end(pc,d0.w)        ; literals: copy straight from the input
lit_ladder:
        move.b  (a0)+,(a1)+             ; 8 fully rolled-out byte moves; entry
        move.b  (a0)+,(a1)+             ; at lit_end-2k copies exactly k
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
lit_end:
        dbf     d1,lit_ladder           ; full 8-move passes for big copies
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        add.b   d2,d2                   ; literals transition bit (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset
        moveq   #0,d0                   ; remaining = gamma + 0
        bra.s   get_gamma

match_source:
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3
        suba.w  d3,a2
        swap    d3
        jmp     match_end(pc,d0.w)
match_ladder:
        move.b  (a2)+,(a1)+             ; the match twin of lit_ladder
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
match_end:
        dbf     d1,match_ladder
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        add.b   d2,d2                   ; match transition bit (bare read)
        bcc.w   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:
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
        moveq   #1,d0                   ; remaining = gamma + 1
        bra.w   get_gamma               ; (.w: taken Bcc/BRA cost the same)

suspend:                                ; a5 is parked on ctx_chunk: two pure
        move.b  d2,-(a5)                ; pre-decrements land bits then state,
        move.b  d4,-(a5)                ; no hole to skip
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:
        moveq   #-1,d4                  ; State.DONE ($FF)
        move.b  d2,-(a5)
        move.b  d4,-(a5)
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
