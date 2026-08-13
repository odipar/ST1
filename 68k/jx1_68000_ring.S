; -----------------------------------------------------------------------------
; jx1_68000_ring.S - JX1: resumable ZX1 decompressor with a RING BUFFER (68000)
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Code written by
; Claude (Anthropic's Claude Code) under Robbert's direction. The
; decompressor can be used freely within your own programs, even
; commercially, as long as your documentation indicates that you used
; ZX1/jx1 (see LICENSE).
;
; jx1_68000.S writes to a linear destination and reads matches out of it, so
; the output IS the window and memory use grows with the output. This is the
; port of the Java Decompressor's ring buffer: output streams through a
; caller-supplied buffer of N bytes and memory use is bounded by N, not by
; the output. A buffer of N bytes supports back-references up to exactly N
; (compress with -mN).
;
; There is no flip callback and no third return code: jx1_resume returns 0
; (done) and 1 (more), exactly like jx1_68000.S. The caller has to drain
; after every call anyway, so NOT reporting the buffer-full event is what
; makes the ring bookkeeping collapse:
;
; 1. THE BUDGET CARRIES THE RING. The entry clamps this call's budget to the
;    room left in the buffer, so the destination CANNOT reach the end of the
;    buffer inside a call - only exactly as the budget runs out. Every
;    per-segment destination clamp, the post-copy wrap test, and the special
;    case for a flip landing on an op's last byte all vanish. The buffer is
;    wrapped once, at the next entry, where the room is computed anyway.
;
; 2. THE RING BOUNDS ARE NOT STATE. The caller holds them - it needs them to
;    drain - so it passes them in a3/a4 (read-only) rather than the
;    decompressor storing them. The context is back to the 15 bytes of
;    jx1_68000.S: a ring costs no context at all.
;
; What is left of the ring is one clamp per call and one clamp per match
; segment - work per CALL and per MATCH, never per byte, so the overhead over
; jx1_68000.S is set by the chunk size that amortizes it and is essentially
; independent of the buffer size: +13-19% at chunk 16, +6-12% at 64, +4-11%
; at 127, moving by less than half a point across 1024-, 4096- and
; 65536-byte rings. A copy segment still stops where the match source reaches the end
; of the buffer, so the rolled-out ladder needs no bounds test, and the
; source is recomputed from the destination per segment (source =
; dst - offset, + N when that falls below the buffer).
;
; The caller drains after every call, and detects the wrap itself - the write
; pointer never wraps during a call, so it only has to notice that the
; buffer is now full:
;
;       prev = ring
;   .loop:
;       bsr     jx1_resume              ; a1 = write pointer
;       ; consume [prev .. a1)
;       movea.l a1,prev
;       cmpa.l  a4,a1                   ; buffer full? the next call restarts
;       bne.s   .more                   ; at the beginning of the buffer
;       movea.l a3,prev
;   .more:
;       tst.w   d0
;       bne.s   .loop
;
; Because the budget is clamped to the room, a call near the end of the
; buffer produces FEWER than chunkSize bytes; a caller must use the write
; pointer, not an assumed chunk size.
;
; Measured, and deliberately NOT done:
;
; - Reporting the flip with a third return code (2 = buffer wrapped) forces
;   the decompressor to STOP at the buffer end, which brings back a
;   destination clamp on every copy segment, a wrap test after every copy,
;   a special case for a flip landing on an op's last byte, and 8 bytes of
;   context for the ring bounds. That version measured 3.2-6.1% slower and
;   14 bytes larger.
;
; - Specialising for power-of-two buffer and chunk sizes (X then divides N,
;   so the destination clamp can be dropped) measured +4.1-4.5% over that
;   version - not worth a divisibility rule the caller must honour, and the
;   clamp-the-budget trick above beats it anyway. Wrapping the source by
;   masking instead of comparing measured SLOWER on a 68000: and.l (8) plus
;   lea 0(An,Dn.l) (12) costs more than the compare and rarely-taken branch
;   it replaces (a not-taken Bcc is 8).
;
; - Allowing the destination to overrun into a buffer of N + chunkSize bytes
;   removes the entry clamp (~12 cycles a call) but breaks the SOURCE rule:
;   bytes in the overrun are logically positions N, N+1..., so a source
;   reading past the end is correct inside the overrun window and wrong
;   outside it, and the clamp has to know which. Concretely, an offset-1 run
;   crossing the end reaches source == end with room 0 and stalls. Making
;   the slack a true mirror of the first chunkSize bytes fixes reads but
;   costs more code to keep in sync than it saves.
;
; Assumptions, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;   3. no back-reference offset exceeds the ring buffer size N
;
; The context must be word-aligned and is 15 bytes (16 with padding) - the
; same block, with the same layout, as jx1_68000.S.
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context and the ring bounds a3/a4 untouched. (d4 carries the op
; state.) d6/d7 and a6 are never touched.
; -----------------------------------------------------------------------------

; Context block (Java: Decompressor's fields). The first three longwords are
; laid out in movem order d3,a0,a1.
ctx_packed      equ     0               ; .l  d3: lastOffset (high word), remaining (low word)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: write position (Java: bufferIndex)
ctx_chunk       equ     12              ; .b  chunkSize (X), 1..127
ctx_bits        equ     13              ; .b  bit buffer
ctx_state       equ     14              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     15
ctx_alloc       equ     16              ; ctx_size rounded up to keep sp even

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4).
; There is no one-shot entry: a bounded buffer has to be drained by the
; caller, so every stream is decompressed through the resume loop.
                bra.w   jx1_init
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = ring buffer, d0.b = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
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

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context, a3 = ring buffer start, a4 = ring buffer end
;             (start + N); both read-only and unchanged on return.
; Emits at most ctx_chunk output bytes, and at most as many as fit before the
; end of the ring buffer. Returns d0 = 0 when the stream is fully processed,
; 1 when there is more; a1 = the write pointer, which is the caller's cue:
; everything between its previous value and a1 is new output, and when a1
; reaches a4 the buffer is full and the next call restarts at a3.
; Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        moveq   #0,d5
        move.b  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.l  a4,d1
        sub.l   a1,d1                   ; room before the end of the buffer
        bne.s   have_room
        movea.l a3,a1                   ; the buffer was filled by the previous
        move.l  a4,d1                   ; call and the caller has drained it:
        sub.l   a3,d1                   ; wrap, and the room is the whole ring
have_room:
        cmp.l   d5,d1                   ; budget = min(chunkSize, room), so the
        bcc.s   budget_set              ; destination cannot reach the end of
        move.w  d1,d5                   ; the buffer inside this call - only
budget_set:                             ; exactly as the budget runs out
        move.b  (a5),d4                 ; op state (Java: switch in next())
        beq.s   begin_literals          ; START: the stream opens with literals
        cmp.b   #3,d4
        bne.s   resume_op               ; LITERALS or MATCH, mid-op
        lea     -ctx_state(a5),a5       ; DONE: keep returning "fully processed"
        moveq   #0,d0
        rts

; get_gamma: interlaced Elias gamma value in d1.w (assumption: fits a word).
; Holds the decompressor's only bit-queue refills: gammas are odd-length,
; transitions are single bits, and the stream opens with a gamma, so
; continuation bits sit at even bit indices and the queue (refilled every
; 8th bit) can only empty on one - data and transition bits are read bare,
; with no refill check. The first continuation bit is peeled (a length-1
; value falls straight through) and the loop is rotated so the continue
; branch is the back-jump: no unconditional bra per pair.
; Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2                ; refill; bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see the note above)
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
        rts

begin_literals:                         ; Java: beginLiterals()
        moveq   #1,d4                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched

; -----------------------------------------------------------------------------
; resume_op: the segment loop, shared by literals and matches (d4 = state).
; Only a match source running into the end of the buffer can split a copy;
; the destination never can, so literals always copy in one pass.
; -----------------------------------------------------------------------------
resume_op:
        tst.w   d3
        beq.s   transition              ; op complete: parse the next one
        tst.w   d5
        beq.w   suspend_more            ; budget spent: hand control back
        move.w  d3,d0                   ; n = min(remaining, budget)
        cmp.w   d5,d0
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        cmp.b   #1,d4
        beq.s   literal_source
        movea.l a1,a2                   ; match: source = dst - lastOffset,
        swap    d3                      ; brought back into the buffer if it
        suba.w  d3,a2                   ; falls below the start (Java:
        swap    d3                      ; readBufferByte()'s index wrap)
        cmpa.l  a3,a2
        bcc.s   source_ready
        suba.l  a3,a2
        adda.l  a4,a2
source_ready:
        move.l  a4,d1
        sub.l   a2,d1                   ; room before the source wraps (>= 1)
        cmp.l   d0,d1
        bcc.s   copy
        move.w  d1,d0                   ; this segment stops at the wrap
        bra.s   copy
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d0,d3                   ; a partial first pass of n&7 entered
        sub.w   d0,d5                   ; mid-ladder, then n>>3 full passes off
        move.w  d0,d1                   ; the dbf at ladder_end
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
        cmp.b   #1,d4
        bne.s   resume_op               ; matches consume no input here;
        movea.l a2,a0                   ; literals do
        bra.s   resume_op

transition:                             ; remaining == 0: parse the next block
        cmp.b   #1,d4                   ; header. State test BEFORE the bit
        beq.s   literals_transition     ; read: cmp must not clobber the carry
        add.b   d2,d2                   ; Java: next(), case MATCH (bare read)
        bcc.w   begin_literals          ; 0: literals; 1: falls into new offset

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
        bsr.w   get_gamma               ; (.w: out of short range; BSR is 18
                                        ; cycles at either width)
        addq.w  #1,d1                   ; remaining = gamma + 1
        move.w  d1,d3
        bra.w   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

literals_transition:
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op               ; (.w: same, zero cycle cost)

suspend_more:                           ; Java: resume() returning true
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #1,a5                   ; skip ctx_chunk
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:                             ; Java: State.DONE - the caller drains
        moveq   #3,d0                   ; whatever is left below a1
        move.b  d0,(a5)
        move.b  d2,-(a5)
        subq.l  #1,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
