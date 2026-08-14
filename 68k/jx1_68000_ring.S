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
; The port of the Java Decompressor's ring buffer: output streams through a
; caller-supplied buffer of N bytes, so memory use is bounded by N and not by
; the size of the output. A buffer of N bytes supports back-references up to
; exactly N, so compress with -mN.
;
; Three deliberate choices shape everything below.
;
; 1. NO FLIP CALLBACK AND NO THIRD RETURN CODE. jx1_resume returns 0 (done)
;    and 1 (more). The caller has to inspect the write pointer after every
;    call anyway, so it can see a full buffer for itself - and being free of
;    any duty to STOP at the buffer end is what lets the rest collapse.
;
; 2. THE BUDGET CARRIES THE RING. The entry clamps this call's budget to the
;    room left in the buffer. The destination therefore cannot reach the end
;    of the buffer inside a call - only exactly as the budget runs out - so
;    no copy needs a destination bounds test, and the buffer is wrapped once,
;    at the next entry, where the room is computed anyway. What remains of
;    the ring is one clamp per call and one clamp per match segment: work per
;    CALL and per MATCH, never per byte.
;
; 3. THE POINTERS ARE NOT STATE. The caller already holds the ring bounds -
;    it needs them to drain - so it passes them read-only in a3/a4, and it
;    holds the write pointer in a1 for the same reason. The context is left
;    with the parse state alone, 12 bytes: four FEWER than the linear
;    decompressor needs, because that one has to store its destination.
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
;       movea.l ring,a1                 ; the caller holds the write pointer
;       movea.l a1,prev
;   .loop:
;       bsr     jx1_resume
;       ; consume [prev .. a1)
;       movea.l a1,prev
;       cmpa.l  a4,a1                   ; buffer full?
;       bne.s   .more
;       movea.l a3,prev                 ; the next call restarts at a3
;   .more:
;       tst.w   d0
;       bne.s   .loop
;
; Because the budget is clamped to the room, a call that runs into the end of
; the buffer produces FEWER than chunkSize bytes, so in general a caller must
; use the write pointer rather than an assumed chunk size.
;
; Sizing the buffer as a multiple of the chunk removes that case entirely.
; dst - start is then a multiple of chunkSize at every entry - it starts at 0,
; a call returning 1 wrote exactly the budget, and a full buffer restarts at 0
; - so the room is a multiple of chunkSize as well, never less than it, and
; the clamp never bites. Every call emits exactly chunkSize bytes and returns
; 1, except the final one, which returns 0 with the last (output mod
; chunkSize) bytes, or a full chunk when the output divides evenly. Callers
; that want fixed-size blocks should pick their sizes that way.
;
;
; Once a stream is finished the context holds only its state byte: the final
; call stops writing the other fields back, because nothing reads them again.
; A finished stream keeps returning 0, and the end of the output is in a1.
; TRUSTED INPUT ONLY. Nothing here is validated: not the stream, not the end
; of the input, not the destination, not the parameters. A malformed or
; hostile stream can read and write arbitrary memory, an offset beyond the
; history produced so far reads whatever is there, and a chunk size of zero
; never advances an operation, so a caller's drain loop spins forever. That is
; the deliberate price of a decompressor this size. For data you did not
; produce yourself, validate the stream and its decompressed length before
; calling in, or decompress it somewhere it cannot do harm.
;
; Assumptions, undefined when violated:
;
;   1. no single literal run or match is longer than 65535 bytes - the
;      length lives in a word. Compress with jx1 -l65535 to guarantee it;
;      an unconstrained stream can exceed it and would decode short here
;   2. the chunk size is 1..127
;   3. the ring buffer size N is 1..65535. The format's offsets stop at
;      32512, so a larger ring could never be referenced anyway
;   4. no back-reference offset exceeds the ring buffer size N
;
; The context must be word-aligned and is 12 bytes.
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0/a2 and leave
; a5 = context and the ring bounds a3/a4 untouched; a1 is the caller's write
; pointer, taken in and handed back. (d4 carries the op
; state.) d6/d7 and a6 are never touched.
; -----------------------------------------------------------------------------

; Context block (Java: Decompressor's fields). The write pointer is NOT here:
; like the ring bounds, the caller holds it. The three longwords are in movem
; order d3,a0,a2.
ctx_packed      equ     0               ; .l  d3: lastOffset (high word), remaining (low word)
ctx_src         equ     4               ; .l  a0: input position
ctx_chunk       equ     8               ; .w  chunkSize (X), 1..127 (a word: the
                                        ;     budget is only ever used word-wide,
                                        ;     so the entry loads it as one)
ctx_bits        equ     10              ; .b  bit buffer
ctx_state       equ     11              ; .b  State: $80 START, 0 LITERALS,
ctx_size        equ     12              ;     2 MATCH, $FF DONE - signed, so the
                                        ;     entry dispatches on the load's flags

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4).
; There is no one-shot entry: a bounded buffer has to be drained by the
; caller, so every stream is decompressed through the resume loop.
                bra.w   jx1_init
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = ring buffer, d0.w = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        moveq   #1,d3
        swap    d3                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        swap    d0                      ; the last longword is the chunk word,
        move.w  #$8080,d0               ; an empty bit buffer and State.START,
        movea.l d0,a2                   ; so the whole context is three registers
        movem.l d3/a0/a2,(a5)           ; in movem order and one store
        rts

entry_special:                          ; the negative states, both rare
        add.b   d4,d4                   ; START ($80) doubles to zero; DONE
        beq.w   begin_literals          ; ($FF) does not, so it falls through
entry_done:
        lea     -ctx_state(a5),a5       ; keep returning "fully processed"
        moveq   #0,d0
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context, a1 = write pointer, a3 = ring buffer start,
;             a4 = ring buffer end (start + N). a3/a4 are read-only and come
;             back unchanged; a1 is IN and OUT - the caller keeps it across
;             calls, exactly as it keeps the bounds.
; Emits at most ctx_chunk output bytes, and at most as many as fit before the
; end of the ring buffer. Returns d0 = 0 when the stream is fully processed,
; 1 when there is more; a1 = the write pointer, which is the caller's cue:
; everything between its previous value and a1 is new output, and when a1
; reaches a4 the buffer is full.  Hand a1 straight back either way:
; this entry wraps a full buffer to a3 itself.
; Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0             ; packed offset/remaining, src; a1 is
                                        ; the caller's, like a3/a4
        move.w  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.l  a4,d1
        sub.l   a1,d1                   ; room before the end of the buffer
        bne.s   have_room
        movea.l a3,a1                   ; the buffer was filled by the previous
        move.l  a4,d1                   ; call and the caller has drained it:
        sub.l   a3,d1                   ; wrap, and the room is the whole ring
have_room:
        cmp.w   d5,d1                   ; budget = min(chunkSize, room), so the
        bcc.s   budget_set              ; destination cannot reach the end of
        move.w  d1,d5                   ; the buffer inside this call - only
budget_set:                             ; exactly as the budget runs out. Word:
                                        ; the room is at most N <= 65535, so
                                        ; this cannot read the caller's junk in
                                        ; the upper words of d1 or d5
        move.b  (a5),d4                 ; op state (Java: switch in next()) -
        bmi.s   entry_special           ; START and DONE are the negative ones;
                                        ; a mid-op resume falls straight into
                                        ; the segment body, because a suspend
                                        ; only ever happens with remaining >= 1
                                        ; and the budget was just refilled
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
        cmp.w   d0,d1                   ; word, as above: the room is at most N
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
        bne.s   segment                 ; budget left: the source wrapped, so
                                        ; take another segment of the same op.
                                        ; Spent is the common case, so it is the
                                        ; one that costs nothing to reach

suspend_more:                           ; Java: resume() returning true
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #2,a5                   ; skip the chunk word
        movem.l d3/a0,-(a5)          ; stores in layout order, a5 = context base
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
        add.b   d2,d2                   ; first continuation bit
        beq.s   gamma_refill            ; the queue empties on one bit in eight,
        bcc.s   gamma_done              ; so the refill is out of line and this
gamma_loop:                             ; branch is the one normally not taken
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + bit
        add.b   d2,d2                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        rts
gamma_refill:                           ; both sites want the same thing of a
        move.b  (a0)+,d2                ; refilled queue - carry set means
        addx.b  d2,d2                   ; another pair follows - so they share
        bcs.s   gamma_loop              ; one block, and duplicating this tail
        rts                             ; costs nothing over branching back

begin_literals:                         ; Java: beginLiterals()
        moveq   #0,d4                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.s   resume_op

transition:                             ; remaining == 0: parse the next block
        tst.b   d4                      ; header. State test BEFORE the bit
        beq.s   literals_transition     ; read: it must not clobber the carry
        add.b   d2,d2                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        move.b  (a0)+,d3                ; d3.w is already zero: every edge here
                                        ; has just completed an op, and the
                                        ; stale high word is overwritten by the
                                        ; swap/move.w pair at got_offset
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        bra.s   got_offset
two_byte:
        moveq   #0,d0
        move.b  (a0)+,d0
        lsr.b   #1,d0                   ; d0 = high >> 1, X = high & 1
        addx.w  d3,d3                   ; (low & 254) + (high & 1) in one go
        lsl.w   #8,d0
        add.w   d0,d3                   ; (high>>1)*256 + (low&254) + (high&1)
        neg.w   d3
        add.w   #32512,d3               ; offset = 32512 - that
        ble.s   end_marker              ; offset <= 0 is the end marker
got_offset:
        swap    d3                      ; park the new offset in the high word
        bsr.s   get_gamma               ; (.w: out of short range; BSR is 18
                                        ; cycles at either width)
        addq.w  #1,d1                   ; remaining = gamma + 1
        move.w  d1,d3
        bra.s   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

literals_transition:
        moveq   #2,d4                   ; State.MATCH: both successors of a
                                        ; literal run are matches, and the
                                        ; assignment has to precede the bare
                                        ; read below - a moveq between the add
                                        ; and the bcs would destroy the carry.
                                        ; (A match reaching new_offset already
                                        ; holds 2, so that path needs none.)
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        bsr.s   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.s   resume_op               ; (.w: same, zero cycle cost)

end_marker:                             ; Java: State.DONE - the caller drains
        st      (a5)                    ; State.DONE, which is authoritative:
        lea     -ctx_state(a5),a5       ; every other field is dead now, so walk
        moveq   #0,d0                   ; a5 back rather than store them
        rts
