; -----------------------------------------------------------------------------
; jx1_68000_ring_mod_opt.S - JX1: resumable ZX1 decompressor with a RING
;                            BUFFER whose size is a multiple of the chunk
;                            size, tuned for cycles (68000)
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Code written by
; Claude (Anthropic's Claude Code) under Robbert's direction. The
; decompressor can be used freely within your own programs, even
; commercially, as long as your documentation indicates that you used
; ZX1/jx1 (see LICENSE).
;
; The port of the Java Decompressor's ring buffer: output streams through a
; caller-supplied buffer of N bytes, so memory use is bounded by N and not by
; the size of the output. A buffer of N bytes supports back-references up to
; exactly N, so compress with -mN.
;
; This version requires the chunk size to divide the ring buffer size, and
; spends the requirement on the entry: no room arithmetic, no budget clamp,
; and fixed-size output from every call but the last. Use jx1_68000_ring.S
; when the caller cannot promise that.
;
; Four more cycles-first choices, none of which change the interface:
;
; - THE SEGMENT LOOP'S GUARDS SIT BELOW THE COPY, not above it. A call that
;   resumes mid-op needs neither: a suspend only ever happens with
;   remaining >= 1, and the budget is a whole chunk again on entry. So the
;   entry falls straight into the copy and only the loop pays for the tests.
; - THE OP STATE IS SIGNED: $80 START, 0 LITERALS, 2 MATCH, $FF DONE. The
;   entry dispatches on the flags the state load already set (one bmi, with
;   the two rare states off the fast path), and the two in-body state tests
;   become tst rather than cmp.
; - THE CHUNK IS A WORD FIELD. The budget is only ever used word-wide, so
;   the entry loads it with one move.w and no zero-extension - and the
;   context is still 16 bytes.
; - THE SUSPEND PATH FALLS THROUGH. Reaching the budget test means the op
;   is unfinished, which almost always means the chunk is spent, so that is
;   the case that costs nothing to reach.
;
; Three deliberate choices shape the rest.
;
; 1. NO FLIP CALLBACK AND NO THIRD RETURN CODE. jx1_resume returns 0 (done)
;    and 1 (more). The caller has to inspect the write pointer after every
;    call anyway, so it can see a full buffer for itself - and being free of
;    any duty to STOP at the buffer end is what lets the rest collapse.
;
; 2. THE CHUNK DIVIDES THE BUFFER, so the destination never needs bounding.
;    dst - start is a multiple of chunkSize at every entry - it starts at 0,
;    a call that returns 1 wrote exactly one chunk, and a full buffer starts
;    again at 0 - which makes the room a whole number of chunks, never fewer
;    than one. The destination therefore cannot reach the end of the buffer
;    inside a call, only exactly as the budget runs out, so no copy needs a
;    destination bounds test and the entry needs no room arithmetic: it just
;    restarts a full buffer at its first byte. What remains of the ring is
;    that one compare per call, and one clamp per match segment: work per
;    CALL and per MATCH, never per byte.
;
; 3. THE RING BOUNDS ARE NOT STATE. The caller already holds them - it needs
;    them to drain - so it passes them read-only in a3/a4 instead of the
;    decompressor storing and reloading them. The context is 15 bytes: the
;    ring costs none.
;
; A match source running into the end of the buffer still splits a copy into
; segments, so the rolled-out ladder itself never needs a bounds test. The
; source is recomputed from the destination for each segment (source =
; dst - offset, + N when that falls below the buffer) rather than carried,
; which also makes a resumed match cost nothing extra.
;
; The caller drains after every call and detects the wrap itself - the write
; pointer never wraps during a call, so a full buffer simply shows up as the
; write pointer reaching the end:
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
; Every call therefore emits exactly chunkSize bytes and returns 1, except the
; final one, which returns 0 with the last (output mod chunkSize) bytes - or a
; full chunk when the output divides evenly. A caller wanting fixed-size
; blocks gets them for free; one wanting the exact count can still read the
; write pointer.
;
; Assumptions, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;   3. THE CHUNK SIZE DIVIDES THE RING BUFFER SIZE. Everything above rests on
;      it; a chunk that does not divide the buffer WILL run the destination
;      past the end of it
;   4. no back-reference offset exceeds the ring buffer size N
;
; The context must be word-aligned and is 15 bytes (16 with padding).
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
ctx_chunk       equ     12              ; .w  chunkSize (X), 1..32767 (a word: the
                                        ;     budget is only ever used word-wide,
                                        ;     so the entry loads it as one)
ctx_bits        equ     14              ; .b  bit buffer
ctx_state       equ     15              ; .b  State: $80 START, 0 LITERALS,
ctx_size        equ     16              ;     2 MATCH, $FF DONE - signed so the
ctx_alloc       equ     16              ;     entry dispatches on the load's flags

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
        move.w  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        move.b  #$80,ctx_state(a5)      ; State.START
        rts

entry_special:                          ; the negative states, both rare
        addq.b  #1,d4                   ; DONE ($FF) becomes zero
        beq.s   entry_done
        bra.w   begin_literals          ; START: the stream opens with literals
entry_done:
        lea     -ctx_state(a5),a5       ; keep returning "fully processed"
        moveq   #0,d0
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
        move.w  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        cmpa.l  a4,a1                   ; did the previous call fill the buffer
        bne.s   dst_ready               ; (which the caller has drained by now)?
        movea.l a3,a1                   ; then start again at its first byte
dst_ready:                              ; the budget needs no clamping: the
                                        ; chunk divides the buffer, so the room
                                        ; is always a whole number of chunks
        move.b  (a5),d4                 ; op state (Java: switch in next()) -
        bmi.s   entry_special           ; START and DONE are the negative ones;
                                        ; a mid-op resume falls straight into
                                        ; the segment body, because a suspend
                                        ; only ever happens with remaining >= 1
                                        ; and the budget is a whole chunk again
segment:                                ; d3 remaining >= 1, d5 budget >= 1
        move.w  d3,d0                   ; n = min(remaining, budget)
        cmp.w   d5,d0
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        tst.b   d4                      ; LITERALS is 0, so the state test is a
        beq.s   literal_source          ; tst rather than a cmp


; -----------------------------------------------------------------------------
; resume_op: the segment loop, shared by literals and matches (d4 = state).
; Only a match source running into the end of the buffer can split a copy;
; the destination never can, so literals always copy in one pass.
; -----------------------------------------------------------------------------
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
        tst.b   d4
        bne.s   resume_op               ; matches consume no input here;
        movea.l a2,a0                   ; literals do

resume_op:                              ; the loop guards live here, below the
        tst.w   d3                      ; copy, so a call entering mid-op skips
        beq.s   transition              ; them: op complete, parse the next one
        tst.w   d5
        beq.s   suspend_more            ; budget spent: hand control back
        bra.w   segment                 ; budget left: the source wrapped, so
                                        ; take another segment of the same op
suspend_more:                           ; Java: resume() returning true
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #2,a5                   ; skip the chunk word
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = base
        moveq   #1,d0                   ; more output pending: call again
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
        moveq   #0,d4                   ; State.LITERALS
        bsr.w   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op

transition:                             ; remaining == 0: parse the next block
        tst.b   d4                      ; header. State test BEFORE the bit
        beq.s   literals_transition     ; read: it must not clobber the carry
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

end_marker:                             ; Java: State.DONE - the caller drains
        moveq   #-1,d0                  ; whatever is left below a1
        move.b  d0,(a5)                 ; State.DONE
        move.b  d2,-(a5)
        subq.l  #2,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
